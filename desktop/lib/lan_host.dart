import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:lan_sync/lan_sync.dart';
import 'ledger_store.dart';

class LanHost extends ChangeNotifier {
  LanHost(this.store);
  final LedgerStore store;
  Future<Json> Function(String path, Json message)? exchangeWorkspace;
  Future<void> Function(HttpRequest request, bool Function() authorized)?
  transferReceipt;
  bool Function()? canStartMirror;
  String _revision = secret();
  Completer<void> _changed = Completer<void>();
  void signalChange() {
    _revision = secret();
    _changed.complete();
    _changed = Completer<void>();
  }

  void forget() {
    syncState = null;
    store.forget();
    signalChange();
    notifyListeners();
  }

  HttpServer? _server;
  RawDatagramSocket? _discovery;
  String fingerprint = '';
  List<String> addresses = [];
  String? _code;
  DateTime _expires = DateTime(1970);
  DateTime? lastSeen;
  String? syncState;
  bool get paired => store.get('peer') != null;

  static Map<String, String> _identity() {
    final keys = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final private = keys.privateKey as RSAPrivateKey;
    final csr = X509Utils.generateRsaCsrPem(
      {'CN': 'VeriFin LAN'},
      private,
      keys.publicKey as RSAPublicKey,
    );
    return {
      'cert': X509Utils.generateSelfSignedCertificate(private, csr, 3650),
      'key': CryptoUtils.encodeRSAPrivateKeyToPem(private),
    };
  }

  Future<void> start({int port = lanPort, InternetAddress? bindAddress}) async {
    var identity = store.get('identity');
    if (identity == null) {
      identity = jsonEncode(await compute((_) => _identity(), null));
      store.set('identity', identity);
    }
    final pem = jsonDecode(identity) as Json;
    final cert = pem['cert'] as String;
    fingerprint = pin(
      base64Decode(
        cert
            .split('\n')
            .where((l) => !l.startsWith('---'))
            .join()
            .replaceAll(RegExp(r'\s'), ''),
      ),
    );
    final ctx = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(cert))
      ..usePrivateKeyBytes(utf8.encode(pem['key'] as String));
    _server = await HttpServer.bindSecure(
      bindAddress ?? InternetAddress.anyIPv4,
      port,
      ctx,
    );
    _server!.idleTimeout = const Duration(seconds: 15);
    _server!.listen(_handle);
    try {
      _discovery = await RawDatagramSocket.bind(
        bindAddress ?? InternetAddress.anyIPv4,
        _server!.port,
      );
      _discovery!.listen((event) {
        if (event != RawSocketEvent.read) return;
        final packet = _discovery?.receive();
        if (packet != null &&
            localAddress(packet.address.address) &&
            ascii.decode(packet.data, allowInvalid: true) ==
                discoveryQuery(fingerprint)) {
          _discovery?.send(
            ascii.encode('verifin/1!$fingerprint'),
            packet.address,
            packet.port,
          );
        }
      });
    } on SocketException {
      /* The pinned QR address remains usable. */
    }
    await refreshAddresses();
  }

  int get port => _server!.port;
  Future<void> refreshAddresses() async {
    addresses = [
      for (final n in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      ))
        for (final a in n.addresses)
          if (localAddress(a.address)) a.address,
    ];
    notifyListeners();
  }

  void newInvitation() {
    if (paired) return;
    _code = secret();
    _expires = DateTime.now().add(const Duration(minutes: 3));
    notifyListeners();
  }

  Invitation? invite(String host) =>
      !paired && _code != null && DateTime.now().isBefore(_expires)
      ? Invitation(host, fingerprint, _code!, Platform.localHostname)
      : null;
  void cancelInvite() {
    _code = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final remote = request.connectionInfo?.remoteAddress.address;
      if (request.method != 'POST' || remote == null || !localAddress(remote)) {
        response.statusCode = 403;
        return;
      }
      final auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
      if (!auth.startsWith('Bearer ')) {
        response.statusCode = 403;
        return;
      }
      final token = auth.substring(7);
      bool authorized() => paired && digest(token) == store.get('peer');
      Json result;
      if (request.uri.path == '/v1/pair') {
        bool valid() =>
            !paired && token == _code && DateTime.now().isBefore(_expires);
        if (!valid()) {
          response.statusCode = 403;
          return;
        }
        final msg = await readMessage(request);
        if (!valid()) {
          response.statusCode = 403;
          return;
        }
        final key = msg['key'] as String, book = msg['book'] as String;
        if (!RegExp(r'^[A-Za-z0-9_-]{43}=$').hasMatch(key) ||
            book.isEmpty ||
            book.length > 256) {
          throw const FormatException('pair');
        }
        store.atomic(() {
          store.set('peer', digest(key));
          store.set('book', book);
        });
        cancelInvite();
        result = {'ok': true};
      } else {
        if (!authorized()) {
          response.statusCode = 403;
          return;
        }
        if (request.uri.path == '/v1/receipt/upload' ||
            request.uri.path == '/v1/receipt/download') {
          final transfer = transferReceipt;
          if (transfer == null) {
            response.statusCode = 404;
            return;
          }
          await transfer(request, authorized);
          return;
        }
        final msg = await readMessage(request);
        if (!authorized() || msg['book'] != store.get('book')) {
          response.statusCode = 403;
          return;
        }
        switch (request.uri.path) {
          case '/v1/sync-error':
            syncState = 'failed';
            result = {'ok': true};
          case '/v1/pending':
            result = {
              'digest': store.get('digest'),
              if (exchangeWorkspace != null) ...{
                'cursor': _revision,
                'allBooks': canStartMirror?.call() ?? true,
              },
              if (exchangeWorkspace != null && store.edits.isEmpty)
                'workspace': true,
              'edits': store.edits
                  .where((op) => op['blocked'] == false)
                  .take(32)
                  .toList(),
            };
          case '/v1/watch':
            if (msg['cursor'] == _revision) {
              await _changed.future.timeout(
                const Duration(seconds: 10),
                onTimeout: () {},
              );
            }
            if (!authorized()) {
              response.statusCode = 403;
              return;
            }
            result = {'cursor': _revision};
          case '/v1/workspace':
          case '/v1/workspace-ack':
            final exchange = exchangeWorkspace;
            if (exchange == null) {
              response.statusCode = 404;
              return;
            }
            try {
              result = await exchange(request.uri.path, msg);
              syncState = result['conflicts'] != null
                  ? 'conflict'
                  : result['busy'] == true || result['retry'] == true
                  ? 'retry'
                  : result['ok'] == true || result['same'] == true
                  ? null
                  : 'working';
            } catch (_) {
              syncState = 'failed';
              notifyListeners();
              rethrow;
            }
          case '/v1/commit':
            store.receive(msg);
            result = {'ok': true};
          default:
            response.statusCode = 404;
            return;
        }
      }
      lastSeen = DateTime.now();
      notifyListeners();
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(result));
    } catch (_) {
      try {
        response.statusCode = 400;
      } on StateError {
        /* Response streaming already began. */
      }
    } finally {
      await response.close().catchError((Object _) {});
    }
  }

  Future<void> stop() async {
    signalChange();
    _discovery?.close();
    await _server?.close(force: true);
  }
}
