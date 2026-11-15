import 'dart:convert';
import 'dart:io';
import 'package:lan_sync/lan_sync.dart';
import 'package:lan_sync/ledger_delta.dart';
import 'package:sqlite3/sqlite3.dart';

LedgerStore openLedgerFile(String path) => LedgerStore(sqlite3.open(path));

Future<LedgerStore> openDesktopLedger() async {
  final dir = Directory(
    '${Platform.environment['LOCALAPPDATA']!}/VeriFin/Desktop',
  );
  await dir.create(recursive: true);
  return openLedgerFile('${dir.path}/ledger.sqlite');
}

/// Last acknowledged phone state and unsent desktop edits survive independently.
class LedgerStore {
  LedgerStore(this.db) {
    db.execute(
      'CREATE TABLE IF NOT EXISTS settings(k TEXT PRIMARY KEY,v TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS outbox(id TEXT PRIMARY KEY, op TEXT NOT NULL, base TEXT, body TEXT NOT NULL, blocked INTEGER NOT NULL DEFAULT 0)',
    );
    final saved = get('ledger');
    _snapshot = saved == null ? null : jsonDecode(saved) as Json;
    _edits = _readEdits();
  }
  final Database db;
  String? get(String key) =>
      db.select('SELECT v FROM settings WHERE k=?', [key]).firstOrNull?['v']
          as String?;
  void set(String key, String value) =>
      db.execute('INSERT OR REPLACE INTO settings VALUES(?,?)', [key, value]);
  void atomic(void Function() action) {
    db.execute('BEGIN IMMEDIATE');
    try {
      action();
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Json? _snapshot;
  Json? get snapshot => _snapshot;
  late List<Json> _edits;
  List<Json> get edits => _edits;

  List<Json> _readEdits() => db
      .select('SELECT * FROM outbox ORDER BY rowid')
      .map(
        (row) => <String, dynamic>{
          'id': row['id'],
          'op': row['op'],
          'base': row['base'],
          'entry': jsonDecode(row['body'] as String),
          'blocked': row['blocked'] == 1,
        },
      )
      .toList();
  void stage(Json entry, String? base) {
    db.execute(
      'INSERT INTO outbox(id,op,base,body) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET op=excluded.op,body=excluded.body',
      [entry['id'], secret(), base, jsonEncode(entry)],
    );
    _edits = _readEdits();
  }

  void resolve(
    String id,
    String? revision, {
    required bool useDesktop,
    Json? phone,
  }) {
    if (!useDesktop) {
      db.execute('DELETE FROM outbox WHERE id=?', [id]);
    } else {
      final desired = edits.firstWhere((e) => e['id'] == id)['entry'] as Json;
      final updated = phone == null
          ? desired
          : {...phone, 'amount': desired['amount'], 'note': desired['note']};
      final targetId = revision == null && !id.startsWith('lan-')
          ? 'lan-${secret()}'
          : id;
      atomic(() {
        db.execute('DELETE FROM outbox WHERE id=?', [id]);
        db.execute('INSERT INTO outbox(id,op,base,body) VALUES(?,?,?,?)', [
          targetId,
          secret(),
          revision,
          jsonEncode({...updated, 'id': targetId}),
        ]);
      });
    }
    _edits = _readEdits();
  }

  void receive(Json message) {
    var next = message['snapshot'] as Json?;
    if (message.containsKey('delta')) {
      if (message['before'] != get('digest')) {
        throw const FormatException('stale');
      }
      next = applyLedgerDelta(snapshot!, message['delta'] as Json);
      if (digest(next) != message['after']) {
        throw const FormatException('digest');
      }
    }
    if (next != null && next['bookId'] != get('book')) {
      throw const FormatException('other book');
    }
    final accepted = message['accepted'] as List,
        blocked = message['blocked'] as List;
    if (next == null && accepted.isEmpty && blocked.isEmpty) return;
    atomic(() {
      if (next != null) {
        set('ledger', jsonEncode(next));
        set('digest', digest(next));
      }
      for (final op in accepted) {
        db.execute('DELETE FROM outbox WHERE op=?', [op]);
      }
      for (final op in blocked) {
        db.execute('UPDATE outbox SET blocked=1 WHERE op=?', [op]);
      }
    });
    if (next != null) _snapshot = next;
    if (accepted.isNotEmpty || blocked.isNotEmpty) _edits = _readEdits();
  }

  void forget() {
    atomic(() {
      db.execute("DELETE FROM settings WHERE k <> 'identity'");
      db.execute('DELETE FROM outbox');
    });
    _snapshot = null;
    _edits = [];
  }
}
