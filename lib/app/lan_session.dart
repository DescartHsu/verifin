import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lan_sync/ledger_delta.dart';
import 'package:lan_sync/workspace_merge.dart';
import 'package:flutter/foundation.dart';
import 'package:lan_sync/lan_sync.dart';
import '../local_storage/local_storage.dart';
import 'veri_fin_controller.dart';
import 'desktop_lan.dart';
import 'attachments/attachment_store.dart';

enum LanStatus {
  idle,
  working,
  offline,
  ready,
  conflict,
  wrongBook,
  retrying,
  failed,
}

class LanSession extends ChangeNotifier {
  LanSession(this.controller, this.store, {this.port = lanPort}) {
    controller.addListener(_invalidate);
  }
  final int port;
  DesktopLan? _desktop;
  DesktopLan get desktop => _desktop ??= DesktopLan(controller);
  List<Json> conflicts = [];
  final Json choices = {};
  Json? _acknowledgedWorkspace;
  String? _acknowledgedHash;
  Json? _workspace;
  String? _workspaceHash;
  final VeriFinController controller;
  final LocalKeyValueStore store;
  static const storageKey = 'verifin.lan_peer.v1';
  LanStatus status = LanStatus.idle;
  DateTime? lastSync;
  bool _closed = false, _forgetting = false;
  Completer<void>? _inFlight;
  bool get _busy => _inFlight != null;
  Json? _snapshot, _lastSent;
  String? _lastSentHash;
  String? _digest;
  Json? get peer {
    final raw = store.read(storageKey);
    return raw == null ? null : jsonDecode(raw) as Json;
  }

  bool Function()? _autoAllowed;
  Timer? _timer;
  bool _watching = false;
  String? _cursor;
  bool _full = false;
  void startAutoSync(bool Function() allowed) {
    _autoAllowed = allowed;
    wake();
  }

  void stopAutoSync() {
    _autoAllowed = null;
    _timer?.cancel();
  }

  void wake([Duration delay = Duration.zero]) {
    _timer?.cancel();
    if (_closed || _autoAllowed == null || peer == null || !_autoAllowed!()) {
      return;
    }
    _timer = Timer(delay, () => sync(_canAuto));
  }

  bool _canAuto() => !_closed && (_autoAllowed?.call() ?? false);

  Future<void> _watch() async {
    final p = peer, cursor = _cursor;
    if (_watching || !_canAuto() || p == null || cursor == null) return;
    _watching = true;
    try {
      final client = LanClient(
        p['ip'] as String,
        p['pin'] as String,
        port: port,
      );
      var previous = cursor;
      while (_canAuto() && peer?['key'] == p['key']) {
        final response = await client.post('watch', p['key'] as String, {
          'book': p['book'],
          'cursor': previous,
        });
        final next = response['cursor'] as String;
        if (next != previous) wake();
        previous = next;
      }
    } on Object {
      wake(const Duration(seconds: 2));
    } finally {
      _watching = false;
      if (_canAuto() && peer?['key'] != p['key']) wake();
    }
  }

  void _invalidate() {
    wake(const Duration(milliseconds: 300));
    _workspace = null;
    _workspaceHash = null;
    _snapshot = null;
    _digest = null;
  }

  void _set(LanStatus next) {
    status = next;
    if (!_closed) notifyListeners();
  }

  Future<void> pair(Invitation invite, {bool allBooks = true}) async {
    if (peer != null || _forgetting || _busy) throw StateError('paired');
    final p = <String, dynamic>{
      'ip': invite.host,
      'pin': invite.fingerprint,
      'name': invite.name,
      'key': secret(),
      'book': controller.activeBook.id,
      'invite': invite.code,
      'workspace': true,
      'allBooks': allBooks,
    };
    await store.writeAndFlush(storageKey, jsonEncode(p));
    notifyListeners();
    wake();
  }

  Future<void> enableWorkspace() async {
    await _inFlight?.future;
    final p = peer;
    if (p == null || _forgetting) return;
    p['workspace'] = true;
    p['allBooks'] = true;
    await store.writeAndFlush(storageKey, jsonEncode(p));
    notifyListeners();
  }

  Future<void> forget() async {
    _forgetting = true;
    try {
      await _inFlight?.future;
      await store.deleteAndFlush(storageKey);
    } finally {
      _forgetting = false;
    }
    _cursor = null;
    _invalidate();
    _lastSent = null;
    _lastSentHash = null;
    _acknowledgedWorkspace = null;
    _acknowledgedHash = null;
    conflicts = [];
    choices.clear();
    lastSync = null;
    _set(LanStatus.idle);
  }

  Future<void> syncNow(bool Function() allowed) =>
      sync(_autoAllowed ?? allowed);

  Future<void> sync(bool Function() allowed) async {
    final p = peer;
    if (p == null || _closed || _forgetting || !allowed()) return;
    if (_busy) {
      wake(const Duration(milliseconds: 350));
      return;
    }
    final scoped = p['allBooks'] != true;
    final book = p['book'] as String, key = p['key'] as String;
    bool active() =>
        !_closed &&
        !_forgetting &&
        allowed() &&
        peer?['key'] == key &&
        (!scoped || controller.activeBook.id == book);
    if (scoped && controller.activeBook.id != book) {
      _set(LanStatus.wrongBook);
      return;
    }
    _inFlight = Completer<void>();
    if (status != LanStatus.ready || _autoAllowed == null) {
      _set(LanStatus.working);
    }
    LanClient? connected;
    try {
      var client = LanClient(p['ip'] as String, p['pin'] as String, port: port);
      Future<Json> pending() async {
        if (p.containsKey('invite')) {
          try {
            await client.post('pair', p['invite'] as String, {
              'key': key,
              'book': book,
            });
          } on HttpException {
            // The first pairing acknowledgement may have been lost.
          }
        }
        return client.post('pending', key, {'book': book});
      }

      Json request;
      try {
        request = await pending();
      } on Object catch (error) {
        if (error is! SocketException &&
            error is! TlsException &&
            error is! TimeoutException) {
          rethrow;
        }
        if (!active()) return;
        final host = await discover(client.fingerprint);
        if (host == null) rethrow;
        client = LanClient(host, client.fingerprint, port: port);
        request = await pending();
        p['ip'] = host;
      }
      if (!active()) return;
      if (p.containsKey('invite') || p['ip'] != peer?['ip']) {
        p.remove('invite');
        await store.writeAndFlush(storageKey, jsonEncode(p));
      }
      _cursor = request['cursor'] as String?;
      if (_cursor != null) connected = client;
      final allBooks =
          !scoped &&
          request['allBooks'] == true &&
          request['workspace'] == true;
      if (!allBooks &&
          controller.activeBook.id != book &&
          (request['workspace'] != true || request['cursor'] == null)) {
        _set(LanStatus.wrongBook);
        return;
      }
      if (_full != allBooks) {
        _workspace = null;
        _workspaceHash = null;
        _acknowledgedWorkspace = null;
        _acknowledgedHash = null;
        _full = allBooks;
      }
      if (request['workspace'] == true && p['workspace'] == true) {
        if (!await controller.waitForPendingWritesSucceeded()) {
          throw StateError('storage');
        }
        if (!active()) return;
        final current = _workspace ??= controller.workspaceFor(
              book,
              allBooks: allBooks,
            ),
            hash = _workspaceHash ??= digest(current);
        final body = <String, dynamic>{
          'book': book,
          'hash': hash,
          if (allBooks) 'allBooks': true,
        };
        var result = await client.post('workspace', key, body);
        if (result['send'] == true && active()) {
          result = await client.post('workspace', key, {
            ...body,
            if (_acknowledgedWorkspace != null &&
                _acknowledgedHash == result['base']) ...{
              'base': _acknowledgedHash,
              'delta': workspacePatch(_acknowledgedWorkspace!, current),
            } else
              'records': current,
            'choices': choices,
          });
        }
        if (!active()) return;
        if (result['busy'] == true) {
          _set(LanStatus.retrying);
          return;
        }
        if (result['conflicts'] != null) {
          conflicts = (result['conflicts'] as List).cast<Json>();
          _set(LanStatus.conflict);
          return;
        }
        if (result['same'] != true) {
          final merged = applyWorkspacePatch(current, result['patch'] as Json);
          if (digest(merged) != result['after']) {
            throw const FormatException('workspace hash');
          }
          final token = result['token'] as String;
          for (final id in (result['upload'] as List? ?? []).cast<String>()) {
            if (!active()) return;
            if (!allBooks || !current.containsKey('attachments/$id')) {
              throw const FormatException('file scope');
            }
            await client.upload(
              key,
              token,
              requireValidAttachmentId(id),
              controller.attachmentStore.openRead(id).map((chunk) {
                if (!active()) throw StateError('paused');
                return chunk;
              }),
            );
          }
          if (digest(merged) != hash) {
            AttachmentStore? stage;
            try {
              for (final entry in merged.entries) {
                if (!allBooks ||
                    !entry.key.startsWith('attachments/') ||
                    current.containsKey(entry.key)) {
                  continue;
                }
                if (!active()) return;
                final id = requireValidAttachmentId(entry.key.substring(12));
                stage ??= await controller.attachmentStore.createStagingStore();
                final target = stage;
                await client.download(key, token, id, (stream) async {
                  final count = await target.writeStream(
                    id,
                    stream.map((chunk) {
                      if (!active()) throw StateError('paused');
                      return chunk;
                    }),
                  );
                  final size = (entry.value as Json)['byteSize'];
                  if (size != 0 && size != count) {
                    throw const FormatException('file length');
                  }
                });
              }
              await controller.applyWorkspace(
                book,
                merged,
                expected: hash,
                allBooks: allBooks,
                readAttachment: stage?.readBytes,
                allowed: active,
              );
            } finally {
              if (stage != null) {
                await controller.attachmentStore.discardStagingStore(stage);
              }
            }
          }
          if (!active()) return;
          final ack = await client.post('workspace-ack', key, {
            'book': book,
            'token': result['token'],
            if (allBooks) 'allBooks': true,
          });
          if (ack['ok'] != true) {
            _set(LanStatus.retrying);
            return;
          }
          _acknowledgedWorkspace = merged;
          _acknowledgedHash = result['after'] as String;
        } else {
          _acknowledgedWorkspace = current;
          _acknowledgedHash = hash;
        }
        conflicts = [];
        choices.clear();
        lastSync = DateTime.now();
        _set(LanStatus.ready);
        if (!allBooks && p['allBooks'] == true && request['cursor'] != null) {
          wake(const Duration(milliseconds: 350));
        }
        return;
      }
      final accepted = <String>[], blocked = <String>[];
      if (!await controller.waitForPendingWritesSucceeded()) {
        throw StateError('storage');
      }
      // Persist operation IDs before touching SQLite. If the process dies between
      // committing a new entry and acknowledging it, a subsequent local deletion
      // must not be resurrected by replaying the original desktop request.
      final attempts = (p['attempts'] as List? ?? []).cast<String>().toSet();
      for (final raw in request['edits'] as List) {
        if (!active()) return;
        final edit = raw as Json;
        final op = edit['op'] as String;
        final replayOnly = !attempts.add(op);
        if (!replayOnly) {
          p['attempts'] = attempts.toList();
          await store.writeAndFlush(storageKey, jsonEncode(p));
        }
        if (!active()) return;
        final ok = await controller.applyLanEdit(
          book,
          edit,
          replayOnly: replayOnly,
        );
        (ok ? accepted : blocked).add(edit['op'] as String);
      }
      if (!active()) return;
      final data = _snapshot ??= controller.lanSnapshot();
      final hash = _digest ??= digest(data);
      await client.post('commit', key, {
        'book': book,
        if (hash != request['digest'])
          if (_lastSent != null && request['digest'] == _lastSentHash) ...{
            'delta': ledgerDelta(_lastSent!, data),
            'before': _lastSentHash,
            'after': hash,
          } else
            'snapshot': data,
        'accepted': accepted,
        'blocked': blocked,
      });
      if (!active()) return;
      if (p.remove('attempts') != null) {
        await store.writeAndFlush(storageKey, jsonEncode(p));
      }
      _lastSent = data;
      _lastSentHash = hash;
      lastSync = DateTime.now();
      _set(blocked.isEmpty ? LanStatus.ready : LanStatus.conflict);
    } on SocketException {
      _set(LanStatus.offline);
    } on Object {
      _set(LanStatus.failed);
      if (connected != null && active()) {
        try {
          await connected.post('sync-error', key, {'book': book});
        } on Object {
          // A dropped link is retried by the session monitor.
        }
      }
    } finally {
      _inFlight!.complete();
      _inFlight = null;
      if (!_closed && status == LanStatus.working) _set(LanStatus.retrying);
      if (_canAuto() && peer != null) {
        if (status == LanStatus.ready && _cursor != null) {
          unawaited(_watch());
        } else {
          wake(Duration(seconds: status == LanStatus.conflict ? 12 : 3));
        }
      }
    }
  }

  @override
  void dispose() {
    stopAutoSync();
    _desktop?.dispose();
    _closed = true;
    controller.removeListener(_invalidate);
    super.dispose();
  }
}
