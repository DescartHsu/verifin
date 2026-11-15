import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lan_sync/ledger_delta.dart';
import 'package:flutter/foundation.dart';
import 'package:lan_sync/lan_sync.dart';
import '../local_storage/local_storage.dart';
import 'veri_fin_controller.dart';

enum LanStatus { idle, working, offline, ready, conflict, wrongBook, failed }

class LanSession extends ChangeNotifier {
  LanSession(this.controller, this.store) {
    controller.addListener(_invalidate);
  }
  final VeriFinController controller;
  final LocalKeyValueStore store;
  static const storageKey = 'verifin.lan_peer.v1';
  LanStatus status = LanStatus.idle;
  DateTime? lastSync;
  bool _busy = false, _closed = false;
  Json? _snapshot, _lastSent;
  String? _lastSentHash;
  String? _digest;
  Json? get peer {
    final raw = store.read(storageKey);
    return raw == null ? null : jsonDecode(raw) as Json;
  }

  void _invalidate() {
    _snapshot = null;
    _digest = null;
  }

  void _set(LanStatus next) {
    status = next;
    if (!_closed) notifyListeners();
  }

  Future<void> pair(Invitation invite) async {
    if (peer != null || _busy) throw StateError('paired');
    final p = <String, dynamic>{
      'ip': invite.host,
      'pin': invite.fingerprint,
      'name': invite.name,
      'key': secret(),
      'book': controller.activeBook.id,
      'invite': invite.code,
    };
    await store.writeAndFlush(storageKey, jsonEncode(p));
    notifyListeners();
  }

  Future<void> forget() async {
    await store.deleteAndFlush(storageKey);
    _invalidate();
    _lastSent = null;
    _lastSentHash = null;
    lastSync = null;
    _set(LanStatus.idle);
  }

  Future<void> sync(bool Function() allowed) async {
    final p = peer;
    if (_busy || p == null || _closed || !allowed()) return;
    final book = p['book'] as String, key = p['key'] as String;
    bool active() =>
        !_closed &&
        allowed() &&
        peer?['key'] == key &&
        controller.activeBook.id == book;
    if (controller.activeBook.id != book) {
      _set(LanStatus.wrongBook);
      return;
    }
    _busy = true;
    _set(LanStatus.working);
    try {
      var client = LanClient(p['ip'] as String, p['pin'] as String);
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
        client = LanClient(host, client.fingerprint);
        request = await pending();
        p['ip'] = host;
      }
      if (!active()) return;
      if (p.containsKey('invite') || p['ip'] != peer?['ip']) {
        p.remove('invite');
        await store.writeAndFlush(storageKey, jsonEncode(p));
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
    } finally {
      _busy = false;
      if (!_closed && status == LanStatus.working) _set(LanStatus.idle);
    }
  }

  @override
  void dispose() {
    _closed = true;
    controller.removeListener(_invalidate);
    super.dispose();
  }
}
