import 'package:dartboot_annotation/dartboot_annotation.dart';
import 'package:dartboot_core/bootstrap/application_context.dart';
import 'package:dartboot_util/dartboot_util.dart';

import 'mysql_connection_pool.dart';

/// Mysql的客户端帮助类(使用连接池管理)
///
/// example:
/// ```
/// MysqlConnection2 c = await MysqlClientHelper.getClient('dev');
/// c.query(xxxxx);
/// ```
///
/// @author luodongseu
@Bean(conditionOnProperty: 'database.mysql')
class MysqlClientHelper {
  /// 单例
  static MysqlClientHelper _instance;
  static bool initializing = true;

  /// 连接池的集合
  final _pools = <String, MysqlConnectionPool>{};

  /// 内部key
  static final List<String> innerKeys = ['print-sql'];

  MysqlClientHelper() {
    // 初始化连接池
    _instance = this;
    dynamic mysqlConf = ApplicationContext.instance['database.mysql'];
    if (mysqlConf is Map && mysqlConf.keys.isNotEmpty) {
      mysqlConf.keys.where((k) => !innerKeys.contains(k)).forEach((k) {
        _pools[k] = MysqlConnectionPool.create(mysqlConf[k]);
      });
    }
    initializing = false;
  }

  /// 获取Mysql连接客户端
  ///
  /// Usage:
  /// ```
  /// MysqlClientHelper.getClient().then();
  /// MysqlClientHelper.getClient('dev').then();
  /// ```
  static Future<MysqlConnection2> getClient([String id]) {
    while (null == _instance || initializing) {}
    assert(_instance._pools.isNotEmpty, 'No any mysql configured.');

    if (isEmpty(id)) {
      return _instance._pools.values.elementAt(0).getConnection();
    }

    assert(_instance._pools.containsKey(id),
        'Not found mysql:[$id] configuration.');
    return _instance._pools[id].getConnection();
  }
}
