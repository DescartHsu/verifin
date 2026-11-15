import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';
import '../../data/app_database.dart';
import '../../local_storage/local_storage.dart';
import '../attachments/attachment_store.dart';

/// Retain the original Windows ledger and receipts when upgrading to a phone
/// mirror. Existing confirmed pairs also need their unsent edits in the cache.
Future<Directory> openPhoneCache({
  required Directory support,
  required LocalKeyValueStore prefs,
  required bool hasBaseline,
  required DatabaseFactory factory,
}) async {
  const preference = 'verifin.phone_mirror_directory.v1';
  final saved = prefs.read(preference);
  if (saved != null) return Directory(p.join(support.path, saved));
  await support.create(recursive: true);
  final cache = await support.createTemp('phone-mirror-');
  try {
    final original = p.join(support.path, AppDatabase.defaultDatabaseName);
    if (hasBaseline && await File(original).exists()) {
      final db = await factory.openDatabase(
        original,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      try {
        await db.execute('VACUUM INTO ?', [
          p.join(cache.path, AppDatabase.defaultDatabaseName),
        ]);
      } finally {
        await db.close();
      }
      final source = Directory(p.join(support.path, 'attachments'));
      if (await source.exists()) {
        final target = await Directory(
          p.join(cache.path, 'attachments'),
        ).create();
        await for (final file in source.list(followLinks: false)) {
          final name = p.basename(file.path);
          if (file is File &&
              isValidAttachmentId(name) &&
              !name.endsWith('.part')) {
            await file.copy(p.join(target.path, name));
          }
        }
      }
    }
    await prefs.writeAndFlush(preference, p.basename(cache.path));
    return cache;
  } catch (_) {
    await cache.delete(recursive: true);
    rethrow;
  }
}
