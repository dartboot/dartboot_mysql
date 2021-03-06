import 'dart:async';

import 'package:dartboot_core/bootstrap/application_context.dart';
import 'package:dartboot_core/log/logger.dart';
import 'package:dartboot_db/dartboot_db.dart';
import 'package:dartboot_util/dartboot_util.dart';
import 'package:mysql1/mysql1.dart';
import 'package:mysql1/src/single_connection.dart';

/// 测试连接的sql
const testConnectionSql = 'select 1';

/// 事务的调度器
typedef TransactionCaller = Function(TransactionContext);

/// 默认测试链接周期，毫秒
const int defaultTestQueryPeriodMills = 30 * 1000;

/// 测试的timeout
const Duration testTimeout = Duration(milliseconds: 500);

/// 默认查询timeout
const Duration defaultQueryTimeout = Duration(seconds: 300);

/// 默认查询timeout
const Duration defaultConnectionTimeout = Duration(seconds: 30);

/// Mysql客户端的线程池
///
/// @支持：定义线程池的最大最小数量
/// @支持：定义测试sql语句
///
/// 快速创建连接池示例：
/// ```
/// MysqlConnectionPool.create({host:'',port:''}).then((p) => pool = p);
/// ```
///
/// @author luodongseu
class MysqlConnectionPool {
  Log logger = Log('MysqlConnectionPool');

  /// IP地址
  final String host;

  /// 端口号
  final int port;

  /// 用户名
  final String username;

  /// 密码
  final String password;

  /// 数据库
  final String db;

  /// 最大的连接数量
  final int maxSize;

  /// 最小的连接输了
  final int minSize;

  /// 查询的timeout
  final Duration queryTimeout;

  /// 看门狗的定时器
  Timer _testTimer;

  /// 看门狗的定时间隔
  Duration _testQueryPeriodDuration;

  /// 连接池
  final List<MysqlConnection2> _pool = [];

  /// 获取连接的锁
  bool _acquireConnectionLocked = false;

  /// 获取连接的等待间隔
  final Duration _acquireConnectionWaitInterval = Duration(milliseconds: 100);

  /// 使用默认的配置创建pool
  static MysqlConnectionPool create(mysqlConfig)  {
    assert(null != mysqlConfig, 'Mysql config must not be null');
    return MysqlConnectionPool(
        host: mysqlConfig['host'],
        port: int.parse('${mysqlConfig['port'] ?? 3306}'),
        db: mysqlConfig['db'],
        username: mysqlConfig['username'],
        password: mysqlConfig['password'],
        minSize: int.parse('${mysqlConfig['minPoolSize'] ?? 5}'),
        maxSize: int.parse('${mysqlConfig['maxPoolSize'] ?? 30}'),
        testQueryPeriodMills:
            int.parse('${mysqlConfig['testQueryPeriodMills'] ?? 30000}'));
  }

  /// 创建新的线程池
  ///
  /// example usage:
  /// ``` dart
  /// var pool = MysqlConnectionPool(
  ///   host: '192.168.1.199',
  ///   port: '3306',
  ///   username: 'admin',
  ///   password: '******',
  ///   db: 'test'
  /// );
  /// var c = await pool.getConnection();
  /// c.query('select * from test limit 1');
  /// ```
  MysqlConnectionPool({
    this.host = '127.0.0.1',
    this.port = 3306,
    this.username,
    this.password,
    this.db = 'default',
    this.minSize = 5,
    this.maxSize = 30,
    this.queryTimeout,
    int testQueryPeriodMills = defaultTestQueryPeriodMills,
  }) {
    assert(minSize > 0, 'Min pool size must greater than zero');
    assert(maxSize > minSize, 'Max pool size must greater than min pool size');
    assert(testQueryPeriodMills > 1000,
        'Test query period must greater than 1 second');
    _testQueryPeriodDuration = Duration(milliseconds: testQueryPeriodMills);
    init();
  }

  /// 初始化
  void init() async {
    // 填充连接池
    _fillPool();

    // 添加看门狗
    _initTestTimer();
  }

  /// 创建新的连接，并且将连接添加到连接池中
  Future<MysqlConnection2> _createConnectionAndAdd2Pool() async {
    var c = await createConnection();
    _pool.add(c);
    return c;
  }

  /// 初始化看门狗
  ///
  /// 定时检查连接池中空闲的连接是否可用
  /// 如果已断开，则标记连接被移除，并清理连接池
  void _initTestTimer() {
    if (null != _testTimer) {
      _testTimer.cancel();
    }
    _testTimer = Timer.periodic(_testQueryPeriodDuration, (t) {
      Future.sync(() async {
        // 是否有移除的连接
        List cs = _pool
            .where((c) => c.state == ConnectionState.STATE_NOT_IN_USE)
            .toList();
        for (var i = 0; i < cs.length; i++) {
          var isAlive = await isConnectionAlive(cs[i]);
          if (!isAlive) {
            // 已经断开了
            cs[i].state = ConnectionState.STATE_REMOVED;
          }
        }

        if (cs.any((c) => c.state == ConnectionState.STATE_REMOVED)) {
          await _cleanPool();
        }
      });
    });
  }

  /// 清理连接池
  ///
  /// 清理后执行填充操作
  void _cleanPool() async {
    var removeIndex = <int>[];
    for (var i = 0; i < _pool.length; i++) {
      if (_pool[i].state == ConnectionState.STATE_REMOVED) {
        removeIndex.add(i);
      }
    }
    removeIndex.forEach((i) => _pool.length > i ? _pool.removeAt(i) : null);

    // 填充连接池
    _fillPool();
  }

  /// 填充连接池到[minSize]大小
  void _fillPool() async {
    while (_pool.length < minSize) {
      await _createConnectionAndAdd2Pool();
    }
  }

  /// 获取Mysql的连接对象
  ///
  /// @param timeout: Duration that timeout to break acquire job
  ///                 超时时间
  Future<MysqlConnection2> getConnection(
      {Duration timeout = defaultConnectionTimeout}) async {
    var completer = Completer<MysqlConnection2>();
    var subscription = (() async {
      while (!completer.isCompleted) {
        if (_acquireConnectionLocked) {
          // wait 100ms to try get lock again
          await Future.delayed(_acquireConnectionWaitInterval);
          continue;
        }

        // lock
        _acquireConnectionLocked = true;

        MysqlConnection2 c;
        while ((c = await acquireConnection()) == null) {
          // wait 100ms to try acquirement again
          await Future.delayed(_acquireConnectionWaitInterval);
        }
        c.state = ConnectionState.STATE_IN_USE;

        // unlock
        _acquireConnectionLocked = false;

        return c;
      }
      throw TimeoutException('Get sql connection timeout');
    })()
        .asStream()
        .listen((v) {
      if (!completer.isCompleted) {
        completer.complete(v);
        return;
      }
    });

    // record time start
    var s = now;
    var c = await completer.future
        .timeout(timeout ?? defaultConnectionTimeout, onTimeout: () {
      subscription.cancel();
      if (!completer.isCompleted) {
        completer.completeError('Get sql connection timeout');
        throw TimeoutException('Get sql connection timeout');
      }
      return completer.future;
    });

    // log time used
    logger.debug('Get connection in ${now - s} mills.');

    return c;
  }

  /// 从连接池中取出空闲的连接
  MysqlConnection2 getFreeConnectionInPool() {
    return _pool.firstWhere((c) => c.state == ConnectionState.STATE_NOT_IN_USE,
        orElse: () => null);
  }

  /// 获取连接
  ///
  /// 1. 从[_pool]取空闲连接，如果取到，返回
  /// 2. 如果[_pool]中无空闲连接，且连接池大小不小于[maxSize]，则返回null
  /// 3. 否则[createConnectionAndAdd2Pool]创建新的连接
  Future<MysqlConnection2> acquireConnection() async {
    var c = getFreeConnectionInPool();
    if ((await isConnectionAlive(c)) && null != c || _pool.length >= maxSize) {
      return c;
    }

    // scale
    var nc = await _createConnectionAndAdd2Pool();
    Future.delayed(Duration.zero, _cleanPool);
    return nc;
  }

  /// 判断连接是否存活
  /// 使用[testSql]进行连接测试
  Future<bool> isConnectionAlive(MysqlConnection2 conn) async {
    if (null == conn) {
      return false;
    }
    try {
      await conn.query(testConnectionSql).timeout(testTimeout, onTimeout: () {
        throw TimeoutException(
            'Execute test sql:[$testConnectionSql] timeout.');
      });
      return true;
    } catch (e) {
      conn.state = ConnectionState.STATE_REMOVED;
      return false;
    }
  }

  /// 创建新的连接
  Future<MysqlConnection2> createConnection() async {
    var settings = ConnectionSettings(
        host: host,
        port: port,
        user: username,
        password: password,
        db: db,
        timeout: queryTimeout ?? defaultQueryTimeout);
    return MysqlConnection2.connect(settings);
  }
}

/// 连接状态
enum ConnectionState {
  /// 正在占用中
  STATE_IN_USE,

  /// 空闲
  STATE_NOT_IN_USE,

  /// 已被移除
  STATE_REMOVED
}

/// 封装了部分特性的连接对象
///
/// busy -> 用于判断是否在执行sql
class MysqlConnection2 {
  Log logger = Log('MysqlConnection2');

  /// 连接的状态
  ConnectionState _state = ConnectionState.STATE_NOT_IN_USE;

  /// 连接的对象
  final MySqlConnection connection;

  set state(s) => _state = s;

  ConnectionState get state => _state;

  /// 执行中的ID集合
  final List<String> _executingIds = [];

  MysqlConnection2(this.connection);

  @override
  String toString() {
    return 'state: $_state, executing size: ${_executingIds.length}';
  }

  /// 连接方法
  static Future<MysqlConnection2> connect(ConnectionSettings c) async {
    var connection = await MySqlConnection.connect(c);
    return MysqlConnection2(connection);
  }

  /// 查询单个数据
  Future<Results> query(String sql, [List<Object> values]) async {
    var printSql =
        '${ApplicationContext.instance['database.mysql.print-sql']}' == 'true';
    if (printSql && sql != testConnectionSql) {
      logger.info('Mysql start run sql -> ${sql} ...');
    } else {
      logger.debug('Mysql start run sql -> ${sql} ...');
    }
    var s = now;
    var id = uid8;
    _executingIds.add(id);
    try {
      return await connection?.query(sql, values);
    } catch (e) {
      logger.error('## Sql execution: [${sql}] error: $e');
      throw DbError('Execute sql: [$sql] failed. $e');
    } finally {
      release(id);
      var e = now;
      if (printSql && sql != testConnectionSql) {
        logger.info(
            'Mysql -> $sql [values: $values] finished in ${e - s} mills.');
      } else {
        logger.debug(
            'Mysql -> $sql [values: $values] finished in ${e - s} mills.');
      }
    }
  }

  /// 提交事务
  ///
  /// @param caller 事务提交调用者
  Future transaction(TransactionCaller caller) async {
    var id = uid8;
    _executingIds.add(id);
    try {
      logger.debug('## Sql transaction[$id] execution start ...');
      Future r = await connection?.transaction(caller);
      logger.debug('## Sql transaction[$id] execution end.');
      return r;
    } catch (e) {
      logger.error('## Sql execution: [${id}] error: $e');
      throw DbError('Execute sql: [$id] failed. $e');
    } finally {
      release(id);
    }
  }

  /// 释放指定的ID
  void release(id) {
    _executingIds.remove(id);
    if (_executingIds.isEmpty) {
      _state = ConnectionState.STATE_NOT_IN_USE;
    }
  }

  /// 执行计数的SQL
  Future<int> count(String sql, [List<Object> values]) async {
    String _sql = ModelUtils.formatSql(sql);
    if (_sql.toUpperCase().contains(RegExp('ORDER BY .+ (ASC|DESC)\$'))) {
      _sql =
          _sql.substring(0, _sql.lastIndexOf(RegExp('[oO][rR][dD][eE][rR]')));
    }
    if (!_sql.startsWith(RegExp(
        '\\s*[sS][eE][lL][eE][cC][tT]\\s+[cC][oO][uU][nN][tT]\(.+\)\\s+[fF][rR][oO][mM]'))) {
      return countSubQuery(_sql, values);
    }
    var results = await query(_sql, values);
    return int.parse('${results.isEmpty ? 0 : (results.first[0] ?? 0)}');
  }

  /// 执行计数的SQL（子查询）
  Future<int> countSubQuery(String sql, [List<Object> values]) async {
    var totalSql =
        'select count(*) from (${ModelUtils.formatSql(sql)}) _t_$uid4';
    var results = await query(totalSql, values);
    return results.isEmpty ? 0 : (results.first[0] ?? 0);
  }

  /// 执行查询单个的SQL语句，返回json对象
  Future<dynamic> findOne<R>(String sql, [List<Object> values]) async {
    var results = await query(ModelUtils.formatSql(sql), values);
    if (results.isEmpty) {
      return {};
    }
    if (R != dynamic) {
      return resultsMapper<R>(results)?.first;
    }
    var cols = results.fields.map((f) => f.name).toList();
    return rowMapper(cols, results.first);
  }

  /// 执行查询全部的SQL语句，返回List对象
  Future<List<dynamic>> findAll<R>(String sql, [List<Object> values]) async {
    var results = await query(ModelUtils.formatSql(sql), values);
    if (results.isEmpty) {
      return [];
    }
    if (R != dynamic) {
      return resultsMapper<R>(results);
    }
    var cols = results.fields.map((f) => f.name).toList();
    return rowsMapper(cols, results.toList());
  }

  /// 执行SQL语句，返回List json对象
  Future<List<R>> execute<R>(String sql, [List<Object> values]) async {
    var results = await query(ModelUtils.formatSql(sql), values);
    if (R != dynamic) {
      return resultsMapper<R>(results);
    }
    var cols = results.fields.map((f) => f.name).toList();
    return rowsMapper(cols, results.toList());
  }

  /// 执行分页查询语句，返回PageImpl对象
  Future<PageImpl<R>> executePage<R>(String sql, PageRequest page,
      [List<Object> values]) async {
    assert(isNotEmpty(sql), 'Sql must not be empty.');
    assert(null != page, 'Page must not be null.');

    String _sql = ModelUtils.formatSql(sql);
    var pageSql = '$_sql limit ${page.offset},${page.limit}';
    // 同步处理
    var res =
        await Future.wait([execute<R>(pageSql, values), count(_sql, values)]);
    List<dynamic> rows = res[0] ?? [];
    int total = res[1];

    return PageImpl(rows, page.page, page.limit, total);
  }

  /// Rows -> List<json>
  List<dynamic> rowsMapper(List<String> cols, List<Row> rows) {
    if (isEmpty(rows)) return [];
    return rows.map((r) => rowMapper(cols, r)).toList();
  }

  /// Row -> json
  dynamic rowMapper(List<String> cols, Row row) {
    if (null == row) return null;
    dynamic result = {};
    for (var i = 0; i < cols.length; i++) {
      result[cols[i]] = row[i];
    }
    return result;
  }

  /// Results -> List<Model>
  List<R> resultsMapper<R>(Results results) {
    var _results = results.map((r) => r.fields)?.toList() ?? [];
    return ModelUtils.resultsMapper<R>(_results);
  }
}
