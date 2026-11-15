import 'package:flutter/material.dart';
import 'package:lan_sync/lan_sync.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app/app_lock_session.dart';
import '../app/common_widgets.dart';
import '../app/lan_session.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';

class LanSyncPage extends StatefulWidget {
  const LanSyncPage({super.key});
  @override
  State<LanSyncPage> createState() => _LanSyncPageState();
}

class _LanSyncPageState extends State<LanSyncPage> {
  bool invalid = false;
  bool _allowed() =>
      mounted &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      !AppLockSessionScope.isLocked(context) &&
      ModalRoute.of(context)?.isCurrent == true;
  Future<void> _scan() async {
    final raw = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _ScanPage()),
    );
    if (!mounted || raw == null) return;
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
      if (_allowed()) await controller.lanSession.sync(_allowed);
    } on Object {
      if (mounted) setState(() => invalid = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = VeriFinScope.of(context).lanSession;
    final l = AppLocalizations.of(context);
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
                    LanStatus.ready => l.lanDone,
                    LanStatus.working => l.lanWorking,
                    LanStatus.offline => l.lanOffline,
                    LanStatus.conflict => l.lanConflict,
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
                                    : () => session.sync(_allowed),
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
