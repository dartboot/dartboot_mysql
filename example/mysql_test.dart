import 'package:dartboot_annotation/dartboot_annotation.dart';
import 'package:dartboot_mysql/dartboot_mysql.dart';

/// A simple test use case for DB tools.

/// MySQL client example
@Bean()
class MysqlTest {
  MysqlTest() {
    MysqlClientHelper.getClient('db1').then((client) {
      client.count('select * from t_user').then((value) {
        print('Mysql test user count:${value}');
      });
    });
  }
}