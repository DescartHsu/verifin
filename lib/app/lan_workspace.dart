part of 'veri_fin_controller.dart';

// Every network record belongs to the explicitly paired book. Private fields are
// restored from the receiving device, never copied into the wire document.
const _lanTables = [
  'ledgerBooks',
  'accounts',
  'accountGroups',
  'categories',
  'tags',
  'entries',
  'exchangeRates',
  'recurringRules',
];
const _lanMaps = [
  'monthlyBudgets',
  'categoryBudgets',
  'dailyBudgets',
  'budgetCycleStartDays',
  'defaultAccountIds',
  'assetAccountOrders',
  'assetSectionOrders',
];
const _lanLayout = [
  'themePreference',
  'themeColor',
  'assetAccountViewMode',
  'homePanels',
  'reportPanels',
  'reportDailyPanels',
  'reportYearlyPanels',
  'fabActionMode',
  'currencyFractionStyle',
  'moneyUnitStyle',
  'hideUnitInSingleCurrency',
  'showRunningBalance',
  'homeTrendConfig',
  'assetCoverUrl',
];
bool _bookKey(String key, String book) =>
    key == book || key.startsWith('$book:');
bool _bookRow(String table, lan.Json row, String book) =>
    row[table == 'ledgerBooks' ? 'id' : 'bookId'] == book;

extension LanWorkspace on VeriFinController {
  lan.Json workspaceFor(String book, {bool allBooks = false}) {
    final data = _backupData();
    final records = <String, dynamic>{};
    for (final table in _lanTables) {
      final rows = (data[table] as List).cast<lan.Json>().where(
        (r) => allBooks || _bookRow(table, r, book),
      );
      for (final row in rows) {
        final value = {...row};
        if (table == 'accounts') value.remove('cardNumber');
        records['$table/${row['id']}'] = value;
      }
      if ((allBooks && table == 'ledgerBooks') ||
          table == 'categories' ||
          table == 'accounts' ||
          table == 'tags' ||
          table == 'accountGroups') {
        records['order/$table'] = rows.map((r) => r['id']).toList();
      }
    }
    for (final table in _lanMaps) {
      for (final entry in (data[table] as lan.Json).entries) {
        if (allBooks || _bookKey(entry.key, book)) {
          records['$table/${entry.key}'] = entry.value;
        }
      }
    }
    for (final field in _lanLayout) {
      records['layout/$field'] = data[field];
    }
    records['layout/collapsedAssetSections'] =
        (data['collapsedAssetSections'] as List)
            .whereType<String>()
            .where((k) => allBooks || _bookKey(k, book))
            .toList()
          ..sort();
    if (allBooks) {
      records['layout/activeBookId'] = activeBook.id;
      records['layout/profile'] = data['profile'];
      records['layout/autoSuggestEnabled'] = data['autoSuggestEnabled'];
      for (final row in (data['attachments'] as List).cast<lan.Json>()) {
        records['attachments/${row['id']}'] = row;
      }
    }
    records['layout/locale'] = localePreference.name;
    records['layout/navigationStyle'] = navigationStylePreference.name;
    records['layout/numberPadLayout'] = numberPadLayout.name;
    records['layout/assetAmountsHidden'] = assetAmountsHidden;
    final keys = records.keys.toList()..sort();
    return {for (final k in keys) k: records[k]};
  }

  Future<void> applyWorkspace(
    String book,
    lan.Json records, {
    required String expected,
    required bool Function() allowed,
    bool selectBook = false,
    bool allBooks = false,
    Future<Uint8List> Function(String id)? readAttachment,
  }) => _serializeEntrySave(() async {
    if (!await waitForPendingWritesSucceeded() ||
        !allowed() ||
        lan.digest(workspaceFor(book, allBooks: allBooks)) != expected) {
      throw StateError('Workspace changed');
    }
    final document = jsonDecode(exportDataJson()) as lan.Json,
        data = document['data'] as lan.Json;
    final grouped = <String, lan.Json>{};
    for (final entry in records.entries) {
      final sep = entry.key.indexOf('/');
      if (sep < 1) throw const FormatException('workspace key');
      (grouped[entry.key.substring(0, sep)] ??= {})[entry.key.substring(
            sep + 1,
          )] =
          entry.value;
    }
    final books = grouped['ledgerBooks']?.keys.toSet() ?? {};
    bool inScope(String key) =>
        allBooks ? books.any((id) => _bookKey(key, id)) : _bookKey(key, book);
    if (allBooks ? books.isEmpty : !books.contains(book)) {
      throw const FormatException('missing book');
    }
    for (final table in _lanTables) {
      final rows = (data[table] as List).cast<lan.Json>();
      final others = rows
          .where((r) => !allBooks && !_bookRow(table, r, book))
          .toList();
      final otherIds = others.map((r) => r['id']).toSet();
      final local = {for (final r in rows) r['id']: r};
      final incoming = grouped[table] ?? {};
      final order = (grouped['order']?[table] as List? ?? [])
          .whereType<String>();
      for (final id in {...order, ...incoming.keys}) {
        if (!incoming.containsKey(id)) continue;
        final row = Map<String, dynamic>.from(incoming[id] as lan.Json);
        if (row['id'] != id ||
            !(allBooks
                ? books.contains(row[table == 'ledgerBooks' ? 'id' : 'bookId'])
                : _bookRow(table, row, book)) ||
            otherIds.contains(id)) {
          throw const FormatException('book scope');
        }
        if (table == 'accounts') {
          row['cardNumber'] = local[id]?['cardNumber'] ?? '';
        }
        others.add(row);
      }
      data[table] = others;
    }
    for (final table in _lanMaps) {
      final incoming = grouped[table] ?? {};
      if (incoming.keys.any((id) => !inScope(id))) {
        throw const FormatException('map scope');
      }
      data[table] = {
        for (final e in (data[table] as lan.Json).entries)
          if (!allBooks && !_bookKey(e.key, book)) e.key: e.value,
        ...incoming,
      };
    }
    final layout = grouped['layout'] ?? {};
    for (final f in _lanLayout) {
      if (layout.containsKey(f)) data[f] = layout[f];
    }
    data['collapsedAssetSections'] = [
      ...(data['collapsedAssetSections'] as List).whereType<String>().where(
        (k) => !allBooks && !_bookKey(k, book),
      ),
      ...(layout['collapsedAssetSections'] as List? ?? [])
          .whereType<String>()
          .where(inScope),
    ];
    if (allBooks) {
      final selected = layout['activeBookId'];
      if (!books.contains(selected)) throw const FormatException('active book');
      data['activeBookId'] = selected;
      data['profile'] = layout['profile'];
      data['autoSuggestEnabled'] = layout['autoSuggestEnabled'];
      data['attachments'] = (grouped['attachments'] ?? {}).values.toList();
    } else if (selectBook) {
      data['activeBookId'] = book;
    }
    final entries = (data['entries'] as List)
        .cast<lan.Json>()
        .map((r) => r['id'])
        .toSet();
    data['attachments'] = (data['attachments'] as List)
        .cast<lan.Json>()
        .where((a) => entries.contains(a['entryId']))
        .toList();
    applyingLanChanges.value = true;
    try {
      await importDataJson(
        jsonEncode(document),
        readStagedAttachment: readAttachment,
        reuseLocalAttachments: {for (final a in _attachments) a.id},
      );
      setLocalePreference(
        LocalePreference.fromStorage(layout['locale'] as String?),
      );
      setNavigationStylePreference(
        NavigationStylePreference.fromStorage(
          layout['navigationStyle'] as String?,
        ),
      );
      _numberPadLayout = NumberPadLayout.fromStorage(
        layout['numberPadLayout'] as String?,
      );
      await _store.writeAndFlush(_numberPadLayoutKey, _numberPadLayout.name);
      await setAssetAmountsHidden(layout['assetAmountsHidden'] == true);
      await flushPendingWrites();
      notifyListeners();
    } finally {
      applyingLanChanges.value = false;
    }
  });
}
