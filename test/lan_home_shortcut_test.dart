import 'package:flutter/material.dart';
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
}
