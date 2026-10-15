// SPDX-License-Identifier: GPL-3.0-or-later
// Optional app lock: asks for the phone's fingerprint, face or screen lock
// when PairDesk opens, and again after it was in the background.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'app_settings.dart';

typedef Authenticator = Future<bool> Function(String reason);

/// Uses the phone's own lock: fingerprint, face or PIN/pattern/password.
Future<bool> deviceAuthenticate(String reason) async {
  try {
    return await LocalAuthentication().authenticate(
      localizedReason: reason,
      persistAcrossBackgrounding: true,
    );
  } on PlatformException {
    return false;
  } on Exception {
    return false;
  }
}

/// True if the phone has a screen lock or biometrics that can unlock the app.
Future<bool> deviceCanAuthenticate() async {
  try {
    return await LocalAuthentication().isDeviceSupported();
  } on Exception {
    return false;
  }
}

class AppLockGate extends StatefulWidget {
  const AppLockGate({
    super.key,
    required this.settings,
    required this.child,
    this.authenticate = deviceAuthenticate,
  });

  final AppSettings settings;
  final Widget child;
  final Authenticator authenticate;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  late bool _locked = widget.settings.appLock;
  bool _authenticating = false;
  DateTime? _backgroundedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The unlock prompt itself pauses the app; ignore that.
    if (_authenticating) return;
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _backgroundedAt ??= DateTime.now();
      case AppLifecycleState.resumed:
        final lock = shouldLock(
          enabled: widget.settings.appLock,
          after: widget.settings.lockAfter,
          backgroundedAt: _backgroundedAt,
          now: DateTime.now(),
        );
        _backgroundedAt = null;
        if (lock && !_locked) {
          setState(() => _locked = true);
          _unlock();
        }
      default:
        break;
    }
  }

  Future<void> _unlock() async {
    if (_authenticating || !_locked) return;
    _authenticating = true;
    try {
      final ok = await widget.authenticate('Unlock PairDesk');
      if (ok && mounted) setState(() => _locked = false);
    } finally {
      _authenticating = false;
      _backgroundedAt = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        // Hidden from touch and screen readers while locked.
        ExcludeSemantics(
          excluding: _locked,
          child: AbsorbPointer(absorbing: _locked, child: widget.child),
        ),
        if (_locked) _LockScreen(onUnlock: _unlock),
      ],
    );
  }
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.onUnlock});
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned.fill(
      child: Material(
        color: theme.colorScheme.surface,
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text('PairDesk is locked', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text('Unlock with your fingerprint, face or screen lock.', style: theme.textTheme.bodyMedium),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onUnlock,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Unlock'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
