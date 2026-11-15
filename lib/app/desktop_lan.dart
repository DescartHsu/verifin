import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:lan_sync/lan_sync.dart';
import 'package:lan_sync/workspace_merge.dart';
import 'package:verifin_desktop/lan_host.dart';
import 'package:verifin_desktop/ledger_store.dart' show openDesktopLedger;
import 'veri_fin_controller.dart';

class DesktopLan extends ChangeNotifier {
  DesktopLan(this.controller) {
    controller.addListener(invalidate);
  }
  final VeriFinController controller;
  LanHost? host;
  bool Function() allowed = () => false;
  bool onSyncPage = false;
  bool applying = false;
  bool _closed = false;
  Future<void>? _opening;
  Object? error;
  Future<void> open() =>
      _opening ??= _open().whenComplete(() => _opening = null);
  Future<void> _open() async {
    if (host != null || _closed) return;
    LanHost? candidate;
    try {
      candidate = LanHost(await openDesktopLedger());
      candidate.exchangeWorkspace = exchange;
      await candidate.start();
      if (_closed) {
        await candidate.stop();
        candidate.store.db.close();
        return;
      }
      host = candidate..addListener(notifyListeners);
      error = null;
    } catch (e) {
      await candidate?.stop();
      candidate?.store.db.close();
      error = e;
    }
    if (!_closed) notifyListeners();
  }

  String? _cachedBook;
  Json? _local;
  String? _hash;
  void invalidate() {
    _local = null;
    _hash = null;
  }

  Future<Json> exchange(String path, Json message) async {
    final h = host!, store = h.store, book = message['book'] as String;
    final peer = store.get('peer');
    bool active() =>
        !_closed &&
        host == h &&
        peer != null &&
        store.get('peer') == peer &&
        store.get('book') == book &&
        allowed();
    if (!active() || applying) return {'busy': true};
    if (_cachedBook != book) {
      invalidate();
      _cachedBook = book;
    }
    final local = _local ??= controller.workspaceFor(book);
    final hash = _hash ??= digest(local);
    if (path.endsWith('-ack')) {
      final raw = store.get('proposal');
      if (raw == null) return {'retry': true};
      final proposal = jsonDecode(raw) as Json;
      if (proposal['token'] != message['token'] ||
          proposal['expected'] != hash) {
        return {'retry': true};
      }
      applying = true;
      notifyListeners();
      try {
        final merged = proposal['records'] as Json;
        if (hash != digest(merged)) {
          await controller.applyWorkspace(
            book,
            merged,
            expected: hash,
            allowed: active,
            selectBook: store.get('workspaceBase') == null,
          );
        }
        if (!active()) return {'retry': true};
        store.atomic(() {
          store.set('workspaceBase', jsonEncode(merged));
          store.set('workspaceHash', digest(merged));
          store.db.execute("DELETE FROM settings WHERE k='proposal'");
        });
        invalidate();
        return {'ok': true};
      } finally {
        applying = false;
        if (!_closed) notifyListeners();
      }
    }
    if (message['hash'] == hash && hash == store.get('workspaceHash')) {
      return {'same': true};
    }
    final raw = store.get('workspaceBase');
    final common = raw == null ? null : jsonDecode(raw) as Json;
    if (message['records'] == null && message['delta'] == null) {
      return {'send': true, 'base': store.get('workspaceHash')};
    }
    if (message['delta'] != null &&
        (common == null || message['base'] != store.get('workspaceHash'))) {
      return {'busy': true};
    }
    final phone = message['delta'] == null
        ? message['records'] as Json
        : applyWorkspacePatch(common!, message['delta'] as Json);
    if (digest(phone) != message['hash']) throw const FormatException('digest');
    final merge = common == null && controller.isFreshDesktopBook(local)
        ? (records: phone, conflicts: <Json>[])
        : mergeWorkspace(
            common,
            phone,
            local,
            message['choices'] as Json? ?? {},
          );
    if (merge.conflicts.isNotEmpty) return {'conflicts': merge.conflicts};
    final token = secret();
    store.set(
      'proposal',
      jsonEncode({'expected': hash, 'records': merge.records, 'token': token}),
    );
    return {
      'patch': workspacePatch(phone, merge.records),
      'after': digest(merge.records),
      'token': token,
    };
  }

  @override
  void dispose() {
    _closed = true;
    controller.removeListener(invalidate);
    final h = host;
    if (h != null) {
      h.removeListener(notifyListeners);
      unawaited(
        h.stop().then((_) {
          h.dispose();
          h.store.db.close();
        }),
      );
    }
    super.dispose();
  }
}
