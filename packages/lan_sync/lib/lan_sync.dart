import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

typedef Json = Map<String, dynamic>;
const lanPort = 47847;
const maxMessageBytes = 32 * 1024 * 1024;
final _random = Random.secure();
String secret() =>
    base64Url.encode(List.generate(32, (_) => _random.nextInt(256)));
String digest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
String pin(List<int> der) => sha256.convert(der).toString();

bool localAddress(String host) {
  final ip = InternetAddress.tryParse(host);
  if (ip == null || ip.type != InternetAddressType.IPv4) return false;
  final b = ip.rawAddress;
  return ip.isLoopback ||
      b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168) ||
      (b[0] == 169 && b[1] == 254);
}

class Invitation {
  Invitation(this.host, this.fingerprint, this.code, this.name);
  final String host, fingerprint, code, name;
  String get qr => Uri(
    scheme: 'verifin',
    host: 'pair',
    path: '/1',
    queryParameters: {
      'ip': host,
      'pin': fingerprint,
      'code': code,
      'name': name,
    },
  ).toString();
  factory Invitation.parse(String value) {
    if (value.length > 1600) throw const FormatException('pair');
    final uri = Uri.parse(value);
    final p = uri.queryParameters;
    if (uri.scheme != 'verifin' ||
        uri.host != 'pair' ||
        uri.path != '/1' ||
        !localAddress(p['ip'] ?? '') ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(p['pin'] ?? '') ||
        !RegExp(r'^[A-Za-z0-9_-]{43}=$').hasMatch(p['code'] ?? '') ||
        (p['name'] ?? '').isEmpty ||
        p['name']!.length > 128) {
      throw const FormatException('pair');
    }
    return Invitation(p['ip']!, p['pin']!, p['code']!, p['name']!);
  }
}

Future<Json> readMessage(Stream<List<int>> stream) async {
  final data = BytesBuilder(copy: false);
  await for (final chunk in stream.timeout(const Duration(seconds: 15))) {
    if (data.length + chunk.length > maxMessageBytes) {
      throw const FormatException('size');
    }
    data.add(chunk);
  }
  return jsonDecode(utf8.decode(data.takeBytes())) as Json;
}

class LanClient {
  LanClient(this.host, this.fingerprint, {this.port = lanPort});
  final String host, fingerprint;
  final int port;
  Future<T> _send<T>(
    String path,
    String token,
    Future<void> Function(HttpClientRequest) write,
    Future<T> Function(HttpClientResponse) read,
  ) async {
    if (!localAddress(host)) throw const FormatException('address');
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = const Duration(seconds: 4)
      ..badCertificateCallback = (cert, _, _) => pin(cert.der) == fingerprint;
    try {
      final request = await client.postUrl(
        Uri(scheme: 'https', host: host, port: port, path: '/v1/$path'),
      );
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      await write(request);
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      return await read(response);
    } finally {
      client.close(force: true);
    }
  }

  Future<Json> post(String path, String token, Json body) =>
      _send(path, token, (request) async {
        request.headers.contentType = ContentType.json;
        final bytes = utf8.encode(jsonEncode(body));
        if (bytes.length > maxMessageBytes) throw const FormatException('size');
        request.add(bytes);
      }, readMessage);

  Future<void> upload(
    String key,
    String proposal,
    String id,
    Stream<List<int>> data,
  ) => _send('receipt/upload', key, (request) async {
    request.headers.set('x-proposal', proposal);
    request.headers.set('x-receipt', id);
    await request.addStream(data);
  }, (response) => response.drain<void>());

  Future<void> download(
    String key,
    String proposal,
    String id,
    Future<void> Function(Stream<List<int>>) save,
  ) => _send('receipt/download', key, (request) async {
    request.headers.set('x-proposal', proposal);
    request.headers.set('x-receipt', id);
  }, (response) => save(response.timeout(const Duration(seconds: 15))));
}

String discoveryQuery(String fingerprint) => 'verifin/1?$fingerprint';
Future<String?> discover(String fingerprint) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final found = Completer<String?>();
  try {
    socket.broadcastEnabled = true;
    socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final msg = socket.receive();
        if (msg != null &&
            msg.port == lanPort &&
            localAddress(msg.address.address) &&
            ascii.decode(msg.data, allowInvalid: true) ==
                'verifin/1!$fingerprint' &&
            !found.isCompleted) {
          found.complete(msg.address.address);
        }
      },
      onError: (Object _) {
        if (!found.isCompleted) found.complete(null);
      },
    );
    socket.send(
      ascii.encode(discoveryQuery(fingerprint)),
      InternetAddress('255.255.255.255'),
      lanPort,
    );
    return await found.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => null,
    );
  } finally {
    socket.close();
  }
}
