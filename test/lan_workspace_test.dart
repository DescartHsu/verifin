import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_sync/lan_sync.dart';
import 'package:verifin/app/attachments/attachment_store.dart';
import 'package:verifin/app/desktop_lan.dart';
import 'package:verifin/app/lan_session.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/startup/desktop_phone_cache.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin_desktop/lan_host.dart';
import 'package:verifin_desktop/ledger_store.dart' show openLedgerFile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test(
    'Windows cache retains prior ledger and receipts and survives restart',
    () async {
      final dir = await Directory.systemTemp.createTemp('verifin-cache-test');
      addTearDown(() => dir.delete(recursive: true));
      final original = await databaseFactoryFfi.openDatabase(
        '${dir.path}/verifin.db',
      );
      await original.execute('CREATE TABLE entries(value TEXT)');
      await original.insert('entries', {'value': 'unsent'});
      await Directory('${dir.path}/attachments').create();
      await File('${dir.path}/attachments/receipt-1').writeAsBytes([7, 8]);
      final prefs = LocalKeyValueStore();
      final cache = await openPhoneCache(
        support: dir,
        prefs: prefs,
        hasBaseline: true,
        factory: databaseFactoryFfi,
      );
      final db = await databaseFactoryFfi.openDatabase(
        '${cache.path}/verifin.db',
      );
      try {
        expect((await db.query('entries')).single['value'], 'unsent');
        await db.delete('entries');
        expect((await original.query('entries')).single['value'], 'unsent');
        expect(
          await File('${cache.path}/attachments/receipt-1').readAsBytes(),
          [7, 8],
        );
        final same = await openPhoneCache(
          support: dir,
          prefs: prefs,
          hasBaseline: false,
          factory: databaseFactoryFfi,
        );
        expect(same.path, cache.path);
        final fresh = await openPhoneCache(
          support: dir,
          prefs: LocalKeyValueStore(),
          hasBaseline: false,
          factory: databaseFactoryFfi,
        );
        expect(await File('${fresh.path}/verifin.db').exists(), isFalse);
      } finally {
        await db.close();
        await original.close();
      }
    },
  );
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
      host.transferReceipt = engine.transferReceipt;
      host.canStartMirror = () => engine.canStartMirror;
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
      desktop.setMonthlyBudget(DateTime(2026, 11), 9999);
      host.newInvitation();
      await session.pair(
        Invitation.parse(host.invite('127.0.0.1')!.qr),
        allBooks: false,
      );
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
      // An existing pair can widen scope without discarding an offline PC edit.
      desktop.setMonthlyBudget(month, 2300);
      await phone.addAttachment('test-usd', Uint8List.fromList([3, 1, 4]));
      final receipt = phone.attachmentsForEntry('test-usd').single.id;
      await session.enableWorkspace();
      var unlocked = true;
      Future<void> eventually(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        expect(
          condition(),
          isTrue,
          reason:
              'state ${session.status} scope ${host.store.get('scope')} conflicts ${session.conflicts.map((r) => r['key'])}',
        );
      }

      session.startAutoSync(() => unlocked);
      await eventually(() => host.store.get('scope') == 'all');
      expect(phone.monthlyBudget(month), 2300);
      expect(desktop.ledgerBooks.length, phone.ledgerBooks.length);
      expect(await desktop.attachmentStore.readBytes(receipt), [3, 1, 4]);
      await desktop.addAttachment('test-usd', Uint8List.fromList([1, 5, 9]));
      await eventually(() => phone.attachmentsForEntry('test-usd').length == 2);
      final other = phone
          .attachmentsForEntry('test-usd')
          .firstWhere((a) => a.id != receipt);
      expect(await phone.attachmentStore.readBytes(other.id), [1, 5, 9]);
      final book2 = phone.ledgerBooks
          .singleWhere((b) => b.name == 'Private test book')
          .id;
      desktop.switchLedgerBook(book2);
      await eventually(() => phone.activeBook.id == book2);
      expect(phone.monthlyBudget(month), 7701);
      unlocked = false;
      desktop.setMonthlyBudget(month, 4400);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(phone.monthlyBudget(month), 7701);
      unlocked = true;
      session.wake();
      await eventually(() => phone.monthlyBudget(month) == 4400);
      phone.setMonthlyBudget(month, 4500);
      await eventually(() => desktop.monthlyBudget(month) == 4500);
      await eventually(
        () => !engine.applying && session.status == LanStatus.ready,
      );
      session.stopAutoSync();
      await session.forget();
      host.forget();
      desktop.addLedgerBook('PC only');
      engine.allowed = () => false;
      host.newInvitation();
      await session.pair(host.invite('127.0.0.1')!);
      session.startAutoSync(() => true);
      await eventually(() => session.status == LanStatus.retrying);
      expect(host.store.get('workspaceHash'), isNull);
      engine.allowed = () => true;
      await eventually(() => host.store.get('scope') == 'all');
      expect(
        desktop.ledgerBooks.map((b) => b.id),
        phone.ledgerBooks.map((b) => b.id),
      );
      expect(phone.ledgerBooks.any((b) => b.name == 'PC only'), isFalse);
      await eventually(
        () => !engine.applying && session.status == LanStatus.ready,
      );
    },
  );
}
