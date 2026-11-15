import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:lan_sync/lan_sync.dart';
import 'package:lan_sync/workspace_merge.dart';
import 'package:verifin_desktop/lan_host.dart';
import 'package:verifin_desktop/ledger_store.dart' show openDesktopLedger;
import 'attachments/attachment_store.dart';
import 'veri_fin_controller.dart';

class DesktopLan extends ChangeNotifier {
  DesktopLan(this.controller) {
    controller.addListener(invalidate);
  }
  final VeriFinController controller;
  LanHost? host;
  bool Function() allowed = () => false;
  bool _full = false;
  AttachmentStore? _stage;
  String? _stageToken;
  bool get canStartMirror {
    final s = host?.store;
    if (s == null ||
        s.get('workspaceHash') == null ||
        s.get('scope') == 'all') {
      return true;
    }
    return digest(controller.workspaceFor(s.get('book')!)) ==
        s.get('workspaceHash');
  }

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
      candidate.transferReceipt = transferReceipt;
      candidate.canStartMirror = () => canStartMirror;
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
  bool get hasPendingChanges {
    final s = host?.store;
    final book = s?.get('book');
    if (s == null || book == null) return false;
    final full = s.get('scope') == 'all';
    final current = _cachedBook == book && _full == full ? _hash : null;
    return (current ?? digest(controller.workspaceFor(book, allBooks: full))) !=
        s.get('workspaceHash');
  }

  void invalidate() {
    host?.signalChange();
    _local = null;
    _hash = null;
  }

  Future<void> transferReceipt(
    HttpRequest request,
    bool Function() authorized,
  ) async {
    final s = host!.store;
    final token = request.headers.value('x-proposal'),
        id = requireValidAttachmentId(request.headers.value('x-receipt') ?? '');
    bool active() =>
        !_closed &&
        _full &&
        allowed() &&
        authorized() &&
        token != null &&
        token == _stageToken;
    if (!active()) throw StateError('file session');
    final proposal = jsonDecode(s.get('proposal')!) as Json;
    final meta = (proposal['records'] as Json)['attachments/$id'] as Json?;
    if (proposal['token'] != token || meta == null) {
      throw const FormatException('file scope');
    }
    final known =
        (_local ?? controller.workspaceFor(s.get('book')!, allBooks: true))
            .containsKey('attachments/$id');
    if (request.uri.path.endsWith('download') && known) {
      final source = controller.attachmentStore;
      request.response.contentLength = await source.sizeOf(id);
      await request.response.addStream(
        source.openRead(id).map((chunk) {
          if (!active()) throw StateError('paused');
          return chunk;
        }),
      );
    } else if (request.uri.path.endsWith('upload') &&
        !known &&
        _stage != null) {
      final expected = meta['byteSize'] as int;
      var received = 0;
      final input = request.timeout(const Duration(seconds: 15)).map((chunk) {
        received += chunk.length;
        if (!active() || (expected > 0 && received > expected)) {
          throw const FormatException('file length');
        }
        return chunk;
      });
      final actual = await _stage!.writeStream(id, input);
      if (expected > 0 && actual != expected) {
        await _stage!.delete(id);
        throw const FormatException('file length');
      }
    } else {
      throw const FormatException('file direction');
    }
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
    final allBooks = message['allBooks'] == true;
    if (!allBooks && store.get('scope') == 'all') return {'upgrade': true};
    if (allBooks && !canStartMirror) return {'busy': true};
    if (_cachedBook != book || _full != allBooks) {
      _full = allBooks;
      invalidate();
      _cachedBook = book;
    }
    final local = _local ??= controller.workspaceFor(book, allBooks: allBooks);
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
        if (allBooks && proposal['token'] != _stageToken) {
          return {'retry': true};
        }
        if (hash != digest(merged)) {
          await controller.applyWorkspace(
            book,
            merged,
            expected: hash,
            allowed: active,
            selectBook: store.get('workspaceBase') == null,
            allBooks: allBooks,
            readAttachment: allBooks && _stage != null
                ? (id) => _stage!.existsSync(id)
                      ? _stage!.readBytes(id)
                      : controller.attachmentStore.readBytes(id)
                : null,
          );
        }
        if (!active()) return {'retry': true};
        store.atomic(() {
          store.set('scope', allBooks ? 'all' : 'book');
          store.set('workspaceBase', jsonEncode(merged));
          store.set('workspaceHash', digest(merged));
          store.db.execute("DELETE FROM settings WHERE k='proposal'");
        });
        await _discardStage();
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
    final raw = allBooks && store.get('scope') != 'all'
        ? null
        : store.get('workspaceBase');
    final common = raw == null ? null : jsonDecode(raw) as Json;
    if (message['records'] == null && message['delta'] == null) {
      return {
        'send': true,
        'base': raw == null ? null : store.get('workspaceHash'),
      };
    }
    if (message['delta'] != null &&
        (common == null || message['base'] != store.get('workspaceHash'))) {
      return {'busy': true};
    }
    final phone = message['delta'] == null
        ? message['records'] as Json
        : applyWorkspacePatch(common!, message['delta'] as Json);
    if (digest(phone) != message['hash']) throw const FormatException('digest');
    final merge = common == null
        ? (records: phone, conflicts: <Json>[])
        : mergeWorkspace(
            common,
            phone,
            local,
            message['choices'] as Json? ?? {},
          );
    if (merge.conflicts.isNotEmpty) return {'conflicts': merge.conflicts};
    final token = secret();
    await _discardStage();
    final missing = <String>[
      if (allBooks)
        for (final k in merge.records.keys)
          if (k.startsWith('attachments/') && !local.containsKey(k))
            requireValidAttachmentId(k.substring(12)),
    ];
    if (missing.isNotEmpty) {
      _stage = await controller.attachmentStore.createStagingStore();
    }
    _stageToken = token;
    store.set(
      'proposal',
      jsonEncode({'expected': hash, 'records': merge.records, 'token': token}),
    );
    return {
      'patch': workspacePatch(phone, merge.records),
      if (missing.isNotEmpty) 'upload': missing,
      'after': digest(merge.records),
      'token': token,
    };
  }

  Future<void> _discardStage() async {
    final stage = _stage;
    _stage = null;
    _stageToken = null;
    if (stage != null) {
      await controller.attachmentStore.discardStagingStore(stage);
    }
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(_discardStage());
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
