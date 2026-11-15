import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:verifin/main.dart';
import 'package:verifin/pages/shell.dart';
import 'package:verifin_desktop/lan_host.dart';
import 'package:verifin_desktop/ledger_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/app/lan_session.dart';
import 'package:verifin/pages/lan_sync_page.dart';
import 'support/test_harness.dart';

void main() {
  useTestDatabases();
  testWidgets('first tap on the home shortcut opens the scanner', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home_lan_sync')));
    await tester.pumpAndSettle();
    expect(find.byType(MobileScanner), findsOneWidget);
  });
  testWidgets('paired home shortcut opens sync without the camera', (
    tester,
  ) async {
    final store = LocalKeyValueStore();
    final c = await pumpApp(tester, store);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    store.write(
      LanSession.storageKey,
      '{"book":"different","name":"PC","key":"test"}',
    );
    expect(c.lanSession.status, LanStatus.idle);
    await tester.tap(find.byKey(const Key('home_lan_sync')));
    await tester.pumpAndSettle();
    expect(find.byType(LanSyncPage), findsOneWidget);
    expect(find.byType(MobileScanner), findsNothing);
    expect(c.lanSession.status, LanStatus.wrongBook);
  });
  testWidgets('resuming on a pushed page wakes the phone session', (
    tester,
  ) async {
    final store = LocalKeyValueStore();
    final c = await pumpApp(tester, store);
    await tester.pumpAndSettle();
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('detail'))),
    );
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    store.write(
      LanSession.storageKey,
      '{"book":"other","name":"PC","key":"example"}',
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('detail'), findsOneWidget);
    expect(c.lanSession.status, LanStatus.wrongBook);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Windows opens pairing before the shell and skips standalone book setup',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final prefs = LocalKeyValueStore()
          ..write('verifin.privacy_consent.v1', 'true');
        final controller = await makeController(prefs, false);
        final desk = controller.lanSession.desktop;
        final host = LanHost(openLedgerFile(':memory:'));
        desk.host = host;
        await tester.pumpWidget(VeriFinApp(controller: controller));
        await tester.pumpAndSettle();
        expect(find.byType(LanSyncPage), findsOneWidget);
        expect(find.byType(VeriFinShell), findsNothing);
        expect(find.byKey(const Key('onboarding_skip')), findsNothing);
        host.store.set('workspaceHash', 'acknowledged');
        await tester.pumpWidget(const SizedBox());
        // Recreate the app like a cold start with an acknowledged phone mirror.
        final next = await makeController(prefs, false);
        next.lanSession.desktop.host = LanHost(
          openLedgerFile(':memory:')..set('workspaceHash', 'acknowledged'),
        );
        await tester.pumpWidget(VeriFinApp(controller: next));
        await tester.pumpAndSettle();
        expect(find.byType(VeriFinShell), findsOneWidget);
        expect(find.byKey(const Key('onboarding_skip')), findsNothing);
        await tester.pumpWidget(const SizedBox());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
