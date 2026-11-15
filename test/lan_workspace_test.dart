import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_sync/lan_sync.dart';
import 'package:verifin/app/attachments/attachment_store.dart';
import 'package:verifin/app/desktop_lan.dart';
import 'package:verifin/app/lan_session.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin_desktop/lan_host.dart';
import 'package:verifin_desktop/ledger_store.dart' show openLedgerFile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test(
    'paired SQLite books synchronize layouts and budgets with conflict resolution over TLS',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'verifin-workspace-test',
      );
      final databases = <AppDatabase>[], controllers = <VeriFinController>[];
      Future<VeriFinController> device(
        String name,
        LocalKeyValueStore prefs,
      ) async {
        final db = await AppDatabase.open(
          factory: databaseFactoryFfi,
          path: '${dir.path}/$name.db',
        );
        databases.add(db);
        final c = await VeriFinController.create(
          prefs,
          repository: SqliteLedgerRepository(db),
          attachmentStore: InMemoryAttachmentStore(),
        );
        controllers.add(c);
        return c;
      }

      final prefs = LocalKeyValueStore();
      final phone = await device('phone', prefs),
          desktop = await device('desktop', LocalKeyValueStore());
      final host = LanHost(openLedgerFile('${dir.path}/host.db'));
      await host.start(port: 0, bindAddress: InternetAddress.loopbackIPv4);
      final engine = DesktopLan(desktop)
        ..host = host
        ..allowed = () => true;
      host.exchangeWorkspace = engine.exchange;
      final session = LanSession(phone, prefs, port: host.port);
      addTearDown(() async {
        session.dispose();
        engine.host = null;
        engine.dispose();
        await host.stop();
        host.store.db.close();
        host.dispose();
        for (final c in controllers) {
          c.dispose();
        }
        for (final db in databases) {
          await db.close();
        }
        await dir.delete(recursive: true);
      });
      final sharedBook = phone.activeBook.id;
      phone.addLedgerBook('Private test book');
      phone.setMonthlyBudget(DateTime(2026, 11), 7701);
      phone.switchLedgerBook(sharedBook);
      await desktop.rememberFreshDesktopBook();
      host.newInvitation();
      await session.pair(Invitation.parse(host.invite('127.0.0.1')!.qr));
      final month = DateTime(2026, 11);
      phone.setMonthlyBudget(month, 1700);
      phone.reorderPanels(PanelPageKind.home, 0, 2);
      await phone.setAssetAmountsHidden(true);
      Future<void> sync() async {
        await session.sync(() => true);
        expect(
          session.status,
          LanStatus.ready,
          reason: '${session.conflicts.map((r) => r['key'])}',
        );
      }

      await sync();
      expect(desktop.monthlyBudget(month), 1700);
      expect(desktop.assetAmountsHidden, isTrue);
      expect(
        desktop.enabledPanelIds(PanelPageKind.home),
        phone.enabledPanelIds(PanelPageKind.home),
      );
      await sync();
      expect(
        desktop.ledgerBooks.any((b) => b.name == 'Private test book'),
        isFalse,
      );
      final category = desktop.categories.firstWhere(
        (c) => c.type == EntryType.expense && !c.isBalanceAdjust,
      );
      final foreign = LedgerEntry(
        id: 'test-usd',
        bookId: sharedBook,
        type: EntryType.expense,
        categoryId: category.id,
        accountId: '',
        note: 'USD',
        occurredAt: month,
        amount: 10,
        currencyCode: 'USD',
        baseAmount: 72,
        conversionSource: ConversionSource.manual,
      );
      expect(
        await desktop.saveEntryAggregateDraft(entry: foreign, isNew: true),
        isTrue,
      );
      desktop.setMonthlyBudget(month, 1800);
      phone.setThemePreference(ThemePreference.dark);
      await sync();
      expect(phone.monthlyBudget(month), 1800);
      expect(
        phone.entries.singleWhere((e) => e.id == 'test-usd').baseAmount,
        72,
      );
      expect(
        phone.ledgerBooks.any((b) => b.name == 'Private test book'),
        isTrue,
      );
      expect(desktop.themePreference, ThemePreference.dark);
      phone.setMonthlyBudget(month, 2100);
      desktop.setMonthlyBudget(month, 2200);
      await session.sync(() => true);
      expect(session.status, LanStatus.conflict);
      expect(phone.monthlyBudget(month), 2100);
      expect(desktop.monthlyBudget(month), 2200);
      final conflict = session.conflicts.single;
      session.choices[conflict['signature'] as String] = 'desktop';
      await sync();
      expect(phone.monthlyBudget(month), 2200);
      final persisted = await SqliteLedgerRepository(
        databases.first,
      ).loadMonthlyBudgets();
      expect(persisted.values, contains(2200));
    },
  );
}
