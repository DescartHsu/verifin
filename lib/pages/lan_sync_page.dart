import 'dart:convert';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:verifin_desktop/main.dart' show DesktopPairDialog, DesktopHome;
import '../app/desktop_lan.dart';
import 'package:lan_sync/lan_sync.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app/app_lock_session.dart';
import '../app/common_widgets.dart';
import '../app/lan_session.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';

class HomeLanAction extends StatelessWidget {
  const HomeLanAction({super.key});
  @override
  Widget build(BuildContext context) {
    final session = VeriFinScope.of(context).lanSession;
    final l = AppLocalizations.of(context);
    final desktop = defaultTargetPlatform == TargetPlatform.windows;
    return ListenableBuilder(
      listenable: desktop ? session.desktop : session,
      builder: (context, _) {
        final paired = desktop
            ? session.desktop.host?.paired == true
            : session.peer != null;
        return HeaderAction(
          key: const Key('home_lan_sync'),
          icon: paired ? Icons.sync : Icons.qr_code_scanner,
          tooltip: desktop
              ? l.lanSync
              : paired
              ? l.lanNow
              : l.lanScan,
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => const LanSyncPage(quick: true)),
          ),
        );
      },
    );
  }
}

class LanSyncPage extends StatefulWidget {
  const LanSyncPage({
    super.key,
    this.quick = false,
    this.companionSetup = false,
  });
  final bool quick;
  final bool companionSetup;
  @override
  State<LanSyncPage> createState() => _LanSyncPageState();
}

class _LanSyncPageState extends State<LanSyncPage> {
  bool invalid = false;
  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.windows) return;
    if (widget.quick) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final session = VeriFinScope.of(context).lanSession;
        if (session.peer == null) {
          _scan();
        } else {
          session.syncNow(_allowed);
        }
      });
    }
  }

  bool _allowed() =>
      mounted &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      !AppLockSessionScope.isLocked(context);
  Future<void> _scan() async {
    final raw = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _ScanPage()),
    );
    if (!mounted) return;
    if (raw == null) {
      if (widget.quick) Navigator.of(context).pop();
      return;
    }
    final l = AppLocalizations.of(context);
    final controller = VeriFinScope.of(context);
    try {
      final invite = Invitation.parse(raw);
      final book = controller.activeBook;
      final yes = await showConfirmDialog(
        context,
        title: l.lanAuthorize,
        message: l.lanConsent(book.name, invite.name),
      );
      if (!yes || !_allowed() || controller.activeBook.id != book.id) return;
      await controller.lanSession.pair(invite);
      if (_allowed()) await controller.lanSession.syncNow(_allowed);
    } on Object {
      if (mounted) setState(() => invalid = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = VeriFinScope.of(context).lanSession;
    final l = AppLocalizations.of(context);
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return _ComputerSync(
        desk: session.desktop,
        quick: widget.quick,
        setup: widget.companionSetup,
      );
    }
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              VeriHeader(title: l.lanSync, showBack: true),
              const SizedBox(height: 12),
              ListenableBuilder(
                listenable: session,
                builder: (context, _) {
                  final peer = session.peer;
                  final status = switch (session.status) {
                    LanStatus.idle => l.lanWaiting,
                    LanStatus.retrying => l.lanRetrying,
                    LanStatus.ready => l.lanDone,
                    LanStatus.working => l.lanWorking,
                    LanStatus.offline => l.lanOffline,
                    LanStatus.conflict =>
                      session.conflicts.isEmpty
                          ? l.lanLegacyConflict
                          : l.lanConflict,
                    LanStatus.wrongBook => l.lanBook,
                    LanStatus.failed => l.lanFailed,
                  };
                  return VeriCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          peer == null ? l.lanSetup : peer['name'] as String,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(peer == null ? l.lanHint : status),
                        if (invalid) Text(l.lanInvalid),
                        if (peer != null && peer['allBooks'] != true)
                          TextButton(
                            onPressed: () async {
                              final c = VeriFinScope.of(context);
                              if (await showConfirmDialog(
                                    context,
                                    title: l.lanAuthorize,
                                    message: l.lanConsent(
                                      c.activeBook.name,
                                      peer['name'] as String,
                                    ),
                                  ) &&
                                  _allowed()) {
                                await session.enableWorkspace();
                                if (_allowed()) await session.syncNow(_allowed);
                              }
                            },
                            child: Text(l.lanFull),
                          ),
                        for (final conflict in session.conflicts)
                          ExpansionTile(
                            title: Text(_conflictTitle(conflict)),
                            children: [
                              for (final side in ['phone', 'desktop'])
                                ListTile(
                                  selected:
                                      session.choices[conflict['signature']] ==
                                      side,
                                  title: Text(
                                    side == 'phone'
                                        ? l.lanPhoneChoice
                                        : l.lanComputerChoice,
                                  ),
                                  subtitle: Text(
                                    _conflictValue(
                                      conflict[side],
                                      conflict[side == 'phone'
                                          ? 'desktop'
                                          : 'phone'],
                                    ),
                                    maxLines: 5,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () => setState(
                                    () =>
                                        session.choices[conflict['signature']
                                                as String] =
                                            side,
                                  ),
                                ),
                            ],
                          ),

                        const SizedBox(height: 12),
                        if (peer == null)
                          FilledButton.icon(
                            onPressed: _scan,
                            icon: const Icon(Icons.qr_code_scanner),
                            label: Text(l.lanScan),
                          )
                        else
                          Wrap(
                            spacing: 8,
                            children: [
                              FilledButton(
                                onPressed: session.status == LanStatus.working
                                    ? null
                                    : () => session.syncNow(_allowed),
                                child: Text(l.lanNow),
                              ),
                              TextButton(
                                onPressed: session.status == LanStatus.working
                                    ? null
                                    : () async {
                                        if (await showConfirmDialog(
                                          context,
                                          title: l.lanForget,
                                          message: l.lanForgetHint,
                                        )) {
                                          await session.forget();
                                        }
                                      },
                                child: Text(l.lanForget),
                              ),
                            ],
                          ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _conflictTitle(Json conflict) {
  for (final side in ['phone', 'desktop']) {
    final record = conflict[side];
    if (record is Map) {
      for (final field in ['name', 'note', 'label']) {
        final value = record[field];
        if (value is String && value.isNotEmpty) return value;
      }
    }
  }
  return conflict['key'] as String;
}

String _conflictValue(dynamic value, dynamic other) {
  final differences = value is Map && other is Map
      ? {
          for (final e in value.entries)
            if (jsonEncode(e.value) != jsonEncode(other[e.key])) e.key: e.value,
        }
      : value;
  final text = differences is String ? differences : jsonEncode(differences);
  return text.length > 360 ? '${text.substring(0, 360)}…' : text;
}

class _ComputerSync extends StatefulWidget {
  const _ComputerSync({
    required this.desk,
    required this.quick,
    required this.setup,
  });
  final DesktopLan desk;
  final bool setup;
  final bool quick;
  @override
  State<_ComputerSync> createState() => _ComputerSyncState();
}

class _ComputerSyncState extends State<_ComputerSync> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.desk.open();
      if (mounted && widget.quick && widget.desk.host?.paired == false) {
        await _pair();
      }
    });
  }

  Future<void> _pair() async {
    final h = widget.desk.host!;
    await h.refreshAddresses();
    if (!mounted) return;
    h.newInvitation();
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => DesktopPairDialog(h),
      );
    } finally {
      h.cancelInvite();
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.desk, l = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListenableBuilder(
            listenable: d,
            builder: (context, _) {
              final h = d.host;
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  VeriHeader(title: l.lanSync, showBack: !widget.setup),
                  if (h == null) ...[
                    Text(d.error == null ? l.lanWorking : l.lanFailed),
                    if (d.error != null)
                      TextButton(onPressed: d.open, child: Text(l.lanNow)),
                  ] else if (!h.paired)
                    FilledButton.icon(
                      onPressed: _pair,
                      icon: const Icon(Icons.qr_code),
                      label: Text(l.lanShowQr),
                    )
                  else ...[
                    Text(switch (h.syncState) {
                      'failed' => l.lanFailed,
                      'retry' => l.lanRetrying,
                      'conflict' => l.lanConflict,
                      'working' => l.lanWorking,
                      _ when d.applying => l.lanWorking,
                      _ when h.store.get('workspaceHash') == null =>
                        l.lanFirstSync,
                      _ when d.hasPendingChanges => l.lanDesktopDirty,
                      _ => l.lanDone,
                    }),
                    if (h.store.snapshot != null || h.store.edits.isNotEmpty)
                      TextButton(
                        onPressed: () => Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => DesktopHome(initialHost: h),
                          ),
                        ),
                        child: Text(l.lanPrevious),
                      ),
                    TextButton(
                      onPressed: d.applying
                          ? null
                          : () async {
                              if (await showConfirmDialog(
                                    context,
                                    title: l.lanForget,
                                    message:
                                        h.store.snapshot != null ||
                                            h.store.edits.isNotEmpty
                                        ? l.lanForgetLegacy
                                        : l.lanForgetHint,
                                  ) &&
                                  mounted) {
                                h.forget();
                              }
                            },
                      child: Text(l.lanForget),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ScanPage extends StatefulWidget {
  const _ScanPage();
  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  bool closed = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(AppLocalizations.of(context).lanScan)),
    body: MobileScanner(
      onDetect: (capture) {
        final raw = capture.barcodes
            .where((b) => b.format == BarcodeFormat.qrCode)
            .map((b) => b.rawValue)
            .whereType<String>()
            .firstOrNull;
        if (!closed && raw != null) {
          closed = true;
          Navigator.pop(context, raw);
        }
      },
    ),
  );
}
