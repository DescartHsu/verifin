import 'package:flutter_test/flutter_test.dart';
import 'package:lan_sync/lan_sync.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'support/test_harness.dart';

void main() {
  useTestDatabases();
  test(
    'desktop edits merge by ID, retry once, protect newer phone data and stay in the paired ledger',
    () async {
      final c = await makeController();
      final cat = c.categories.firstWhere(
        (v) => v.type == EntryType.expense && !v.isBalanceAdjust,
      );
      final row = <String, dynamic>{
        'id': 'lan-1',
        'date': '2026-11-15T10:00:00.000',
        'currency': c.activeBook.baseCurrencyCode,
        'note': 'parking',
        'category': cat.id,
        'type': 'expense',
        'account': '',
        'amount': 12.0,
      };
      Json edit(Json value, String? base) => {
        'id': value['id'],
        'entry': value,
        'base': base,
      };
      final book = c.activeBook.id;
      expect(await c.applyLanEdit('other', edit(row, null)), false);
      expect(await c.applyLanEdit(book, edit(row, null)), true);
      expect(await c.applyLanEdit(book, edit(row, null)), true);
      final first = (c.lanSnapshot()['entries'] as List).cast<Json>().single;
      final change = {...row, 'amount': 15.0};
      final second = {...row, 'id': 'lan-2', 'note': 'lunch'};
      expect(await c.applyLanEdit(book, edit(second, null)), true);
      final rev = first['rev'] as String;
      expect(await c.applyLanEdit(book, edit(change, rev)), true);
      expect(await c.applyLanEdit(book, edit(change, rev)), true);
      expect(
        await c.applyLanEdit(book, edit({...row, 'amount': 19.0}, rev)),
        false,
      );
      expect(c.entries.length, 2);
      expect(c.entries.firstWhere((e) => e.id == 'lan-1').amount, 15);
      expect(await c.deleteEntry('lan-1'), true);
      expect(
        await c.applyLanEdit(book, edit(row, null), replayOnly: true),
        false,
      );
      expect(await c.applyLanEdit(book, edit(change, rev)), false);
    },
  );

  test('one-time QR accepts a private LAN endpoint only', () {
    final i = Invitation('192.168.1.42', 'a' * 64, secret(), 'Desktop');
    expect(Invitation.parse(i.qr).fingerprint, i.fingerprint);
    expect(
      () => Invitation.parse(i.qr.replaceAll('192.168.1.42', 'example.com')),
      throwsFormatException,
    );
    expect(
      () => Invitation.parse(i.qr.replaceAll('192.168.1.42', '8.8.8.8')),
      throwsFormatException,
    );
  });
}
