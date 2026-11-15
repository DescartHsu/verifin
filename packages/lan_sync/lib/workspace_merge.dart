import 'lan_sync.dart';

/// Three-way merge against the last snapshot acknowledged by both devices.
/// A choice is bound to both competing values so a stale resolution cannot
/// silently discard a later edit.
({Json records, List<Json> conflicts}) mergeWorkspace(
  Json? base,
  Json phone,
  Json desktop,
  Json choices,
) {
  final result = <String, dynamic>{}, conflicts = <Json>[];
  final keys = {...?base?.keys, ...phone.keys, ...desktop.keys}.toList()
    ..sort();
  for (final key in keys) {
    final a = phone[key], b = desktop[key], old = base?[key];
    final ah = digest(a), bh = digest(b), oh = digest(old);
    dynamic selected;
    if (ah == bh || bh == oh) {
      selected = a;
    } else if (ah == oh) {
      selected = b;
    } else if (base == null &&
        (key.startsWith('layout/') ||
            (key == 'ledgerBooks/default' &&
                a is Map &&
                b is Map &&
                a['baseCurrencyCode'] == b['baseCurrencyCode'] &&
                a['name'] == b['name']))) {
      selected = a;
    } else if (key.startsWith('order/') &&
        a is List &&
        b is List &&
        (old == null || old is List)) {
      final common = (old as List? ?? [])
          .where((id) => a.contains(id) && b.contains(id))
          .toSet();
      final original = common.toList();
      final phoneOrder = a.where(common.contains).toList(),
          desktopOrder = b.where(common.contains).toList();
      if (digest(phoneOrder) == digest(desktopOrder) ||
          digest(desktopOrder) == digest(original)) {
        selected = [
          ...{...a, ...b},
        ];
      } else if (digest(phoneOrder) == digest(original)) {
        selected = [
          ...{...b, ...a},
        ];
      }
    }
    if (selected == null && ah != bh && bh != oh && ah != oh) {
      final signature = digest([key, a, b]);
      final choice = choices[signature];
      if (choice == 'phone') {
        selected = a;
      } else if (choice == 'desktop') {
        selected = b;
      } else {
        conflicts.add({
          'key': key,
          'signature': signature,
          'phone': a,
          'desktop': b,
        });
      }
    }
    if (selected != null) result[key] = selected;
  }
  // Drop stale ordering references after a deletion.
  for (final key in result.keys.where((k) => k.startsWith('order/')).toList()) {
    final table = key.substring(6);
    result[key] = (result[key] as List)
        .where((id) => result.containsKey('$table/$id'))
        .toList();
  }
  return (records: result, conflicts: conflicts);
}

Json workspacePatch(Json before, Json after) => {
  'remove': [
    for (final key in before.keys)
      if (!after.containsKey(key)) key,
  ],
  'put': {
    for (final e in after.entries)
      if (!before.containsKey(e.key) ||
          digest(before[e.key]) != digest(e.value))
        e.key: e.value,
  },
};

Json applyWorkspacePatch(Json before, Json delta) {
  final next = {...before};
  for (final key in delta['remove'] as List) {
    next.remove(key);
  }
  next.addAll(delta['put'] as Json);
  final keys = next.keys.toList()..sort();
  return {for (final key in keys) key: next[key]};
}
