import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show databaseFactoryFfi;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common/sqlite_api.dart';

/// Android/iOS 使用 sqflite 原生实现。
Future<DatabaseFactory> resolveDatabaseFactory() async =>
    Platform.isWindows ? databaseFactoryFfi : sqflite.databaseFactory;

/// 数据库落地到平台默认的 databases 目录。
Future<String> resolveDatabasePath(String name) async {
  if (Platform.isWindows) {
    return path.join((await getApplicationSupportDirectory()).path, name);
  }
  final dir = await sqflite.getDatabasesPath();
  return dir.endsWith('/') ? '$dir$name' : '$dir/$name';
}
