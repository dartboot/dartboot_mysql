The mysql library for DartBoot.

## Usage

A simple usage example:

```dart
import 'package:dartboot_mysql/dartboot_mysql.dart';

main() {
  MysqlClientHelper.getClient('db1').then((client) {
    client.count('select * from t_user').then((value) {
      print('Mysql test user count:${value}');
    });
  });
}
```
