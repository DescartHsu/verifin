import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'package:verifin_desktop/main.dart';
import 'package:verifin_desktop/lan_host.dart';
import 'package:verifin_desktop/ledger_store.dart';

void main() {
  testWidgets('record a local expense while the paired phone is offline', (
    tester,
  ) async {
    final sql = sqlite3.openInMemory();
    final store = LedgerStore(sql);
    store.set('book', 'daily');
    store.set('peer', 'fixture');
    store.receive({
      'snapshot': {
        'name': 'Daily',
        'bookId': 'daily',
        'currency': 'CNY',
        'minorUnit': 2,
        'accounts': [
          {
            'id': 'wallet',
            'name': 'Wallet',
            'balance': 100,
            'currency': 'CNY',
            'hidden': false,
          },
        ],
        'categories': [
          {'id': 'food', 'name': 'Meals', 'type': 'expense', 'system': false},
        ],
        'entries': [],
      },
      'accepted': [],
      'blocked': [],
    });
    final host = LanHost(store);
    final platform = tester.binding.platformDispatcher;
    platform.localeTestValue = const Locale('en');
    addTearDown(platform.clearLocaleTestValue);
    await tester.pumpWidget(MaterialApp(home: DesktopHome(initialHost: host)));
    await tester.tap(find.text('Add transaction'));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '25.50');
    await tester.enterText(fields.at(1), 'Lunch');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(store.edits.length, 1);
    expect(find.textContaining('Lunch'), findsOneWidget);
    expect(find.textContaining('25.50'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    host.dispose();
    sql.close();
  });
}
