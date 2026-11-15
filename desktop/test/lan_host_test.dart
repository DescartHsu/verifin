import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_sync/lan_sync.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:verifin_desktop/ledger_store.dart';
import 'package:verifin_desktop/lan_host.dart';

void main() {
  test(
    'real pinned TLS pairing, offline outbox, conflicts and acknowledgements survive reconnects',
    () async {
      final dir = await Directory.systemTemp.createTemp('verifin-lan-test');
      final db = sqlite3.open('${dir.path}/ledger.db');
      final store = LedgerStore(db), host = LanHost(store);
      addTearDown(() async {
        await host.stop();
        db.close();
        await dir.delete(recursive: true);
      });
      await host.start(port: 0, bindAddress: InternetAddress.loopbackIPv4);
      host.newInvitation();
      final qr = Invitation.parse(host.invite('127.0.0.1')!.qr);
      final client = LanClient(qr.host, qr.fingerprint, port: host.port),
          key = secret();
      await expectLater(
        LanClient(
          qr.host,
          '0' * 64,
          port: host.port,
        ).post('pair', qr.code, {'key': key, 'book': 'book'}),
        throwsA(isA<HandshakeException>()),
      );
      await client.post('pair', qr.code, {'key': key, 'book': 'book'});
      await expectLater(
        client.post('pair', qr.code, {'key': secret(), 'book': 'book'}),
        throwsA(isA<HttpException>()),
      );
      await expectLater(
        client.post('pending', secret(), {'book': 'book'}),
        throwsA(isA<HttpException>()),
      );
      await expectLater(
        client.post('pending', key, {'book': 'other'}),
        throwsA(isA<HttpException>()),
      );
      final data = {
        'bookId': 'book',
        'entries': [
          {'id': 'meal', 'amount': 10},
        ],
      };
      await client.post('commit', key, {
        'book': 'book',
        'snapshot': data,
        'accepted': [],
        'blocked': [],
      });
      store.stage({'id': 'meal', 'amount': 12}, 'rev1');
      final response = await client.post('pending', key, {'book': 'book'});
      final op = (response['edits'] as List).cast<Json>().single['op'];
      expect(response['digest'], digest(data));
      await client.post('commit', key, {
        'book': 'book',
        'accepted': [],
        'blocked': [op],
      });
      expect(store.edits.single['blocked'], true);
      store.resolve('meal', 'rev2', useDesktop: true);
      final next = store.edits.single['op'];
      await client.post('commit', key, {
        'book': 'book',
        'accepted': [op],
        'blocked': [],
      });
      expect(store.edits.single['op'], next);
      await client.post('commit', key, {
        'book': 'book',
        'accepted': [next],
        'blocked': [],
      });
      expect(store.edits, isEmpty);
      final reopened = sqlite3.open('${dir.path}/ledger.db');
      try {
        expect(LedgerStore(reopened).snapshot, data);
      } finally {
        reopened.close();
      }
    },
  );
}
