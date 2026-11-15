import 'lan_sync.dart';

const _tables = ['accounts', 'categories', 'entries'];

/// Only changed rows and deletions cross the network after the common snapshot
/// has been acknowledged. Send ordering separately when the phone reordered IDs.
Json ledgerDelta(Json before, Json after) {
  final changes = <String, dynamic>{
    'header': {
      for (final e in after.entries)
        if (!_tables.contains(e.key)) e.key: e.value,
    },
  };
  for (final table in _tables) {
    final old = {
      for (final r in (before[table] as List).cast<Json>())
        r['id'] as String: r,
    };
    final rows = (after[table] as List).cast<Json>();
    final ids = rows.map((r) => r['id'] as String).toList();
    final remaining = ids.toSet();
    changes[table] = {
      'put': [
        for (final r in rows)
          if (digest(old[r['id']]) != digest(r)) r,
      ],
      'remove': [
        for (final id in old.keys)
          if (!remaining.contains(id)) id,
      ],
      if (digest(ids) != digest(old.keys.toList())) 'order': ids,
    };
  }
  return changes;
}

Json applyLedgerDelta(Json before, Json changes) {
  final result = Map<String, dynamic>.from(changes['header'] as Json);
  for (final table in _tables) {
    final rows = {
      for (final r in (before[table] as List).cast<Json>())
        r['id'] as String: r,
    };
    final change = changes[table] as Json;
    for (final id in change['remove'] as List) {
      rows.remove(id);
    }
    for (final r in (change['put'] as List).cast<Json>()) {
      rows[r['id'] as String] = r;
    }
    final order = (change['order'] as List?)?.cast<String>() ?? rows.keys;
    result[table] = [for (final id in order) rows[id]!];
  }
  return result;
}
