import 'dart:async';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import '../app/app_lock_session.dart';
import '../app/lan_session.dart';
import '../app/veri_fin_scope.dart';
import 'lan_sync_page.dart';
import 'onboarding_page.dart';

/// Keeps the authenticated LAN session alive across navigation and dialogs.
class LanDeviceGate extends StatefulWidget {
  const LanDeviceGate({super.key, required this.child});
  final Widget child;
  @override
  State<LanDeviceGate> createState() => _LanDeviceGateState();
}

class _LanDeviceGateState extends State<LanDeviceGate>
    with WidgetsBindingObserver {
  LanSession? _session;
  bool _locked = true;
  bool get _windows => defaultTargetPlatform == TargetPlatform.windows;
  bool _allowed() =>
      mounted &&
      !_locked &&
      (_windows ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = VeriFinScope.of(context).lanSession;
    final locked = AppLockSessionScope.isLocked(context);
    if (identical(session, _session) && locked == _locked) return;
    _session?.stopAutoSync();
    _session = session;
    _locked = locked;
    if (_windows) {
      session.desktop.allowed = _allowed;
      if (!locked) unawaited(session.desktop.open());
    } else {
      session.startAutoSync(_allowed);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_windows && state == AppLifecycleState.resumed) _session?.wake();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session?.stopAutoSync();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_windows) return OnboardingGate(child: widget.child);
    final desk = _session!.desktop;
    return ListenableBuilder(
      listenable: desk,
      child: widget.child,
      builder: (context, content) {
        if (desk.host?.store.get('workspaceHash') != null) return content!;
        return Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => const LanSyncPage(companionSetup: true),
          ),
        );
      },
    );
  }
}
