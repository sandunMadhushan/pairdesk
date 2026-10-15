// SPDX-License-Identifier: GPL-3.0-or-later
// Paired computers. Tap one to connect; with a single computer the app
// connects by itself when it opens.

import 'package:flutter/material.dart';

import '../agent_connection.dart';
import '../app_model.dart';
import '../pairing/laptop.dart';
import '../pairing/pairing_link.dart';
import 'control_screen.dart';
import 'scan_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.model});

  final AppModel model;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppModel get _model => widget.model;
  AgentConnection get _conn => _model.connection;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_model.autoConnectDone && _model.laptops.length == 1) {
        _model.autoConnectDone = true;
        _connect(_model.laptops.first);
      }
    });
  }

  // ---- Actions --------------------------------------------------------

  Future<void> _connect(Laptop laptop) async {
    if (_busy) return;
    final ok = await _withProgress(() => _model.connect(laptop), laptop: laptop);
    if (ok) await _openControl(laptop);
  }

  Future<void> _addComputer() async {
    if (_busy) return;
    final link = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (link == null || !mounted) return;

    final PairingInfo info;
    try {
      info = parsePairingLink(link);
    } on PairingLinkException catch (e) {
      _showMessage('Can\'t use this code', e.message);
      return;
    }
    Laptop? paired;
    final ok = await _withProgress(() async => paired = await _model.pair(info));
    if (!ok || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Paired with ${paired!.name}. It\'s saved on this phone.')));
    await _openControl(paired!);
  }

  Future<void> _openControl(Laptop laptop) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ControlScreen(connection: _conn, laptopKey: laptop.key, settings: _model.settings),
      ),
    );
    if (!mounted) return;
    final error = _conn.lastError;
    if (error == null) return;
    if (error.kind == FailureKind.notPaired) {
      await _explainFailure(error, laptop);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message),
          action: SnackBarAction(label: 'Reconnect', onPressed: () => _connect(laptop)),
        ),
      );
    }
  }

  /// Runs [action] behind a progress dialog. Returns true on success.
  Future<bool> _withProgress(Future<void> Function() action, {Laptop? laptop}) async {
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    var dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProgressDialog(connection: _conn),
    ).then((_) => dialogOpen = false);

    var ok = false;
    try {
      await action();
      ok = true;
    } on AgentException catch (e) {
      if (dialogOpen) navigator.pop();
      dialogOpen = false;
      if (mounted && e.kind != FailureKind.cancelled) {
        await _explainFailure(e, laptop);
      }
    } finally {
      if (dialogOpen) navigator.pop();
      if (mounted) setState(() => _busy = false);
    }
    return ok;
  }

  Future<void> _explainFailure(AgentException e, Laptop? laptop) async {
    final network = laptop?.reachableAnywhere == true
        ? '• the phone and the computer are on the same Wi-Fi, or, away from home, '
              'Tailscale is on, on both of them'
        : '• the phone and the computer are on the same Wi-Fi\n\n'
              'To connect when you\'re away from home, set up Tailscale: Settings → Connect from anywhere.';
    final (title, body) = switch (e.kind) {
      FailureKind.unreachable => (
        'Can\'t reach the computer',
        'Check that:\n'
            '• the computer is on and not asleep\n'
            '• PairDesk is running on it (look for the tray icon)\n'
            '$network',
      ),
      FailureKind.wrongComputer => (
        'Different computer',
        'Another device answered at this computer\'s address, so PairDesk didn\'t connect. '
            'Make sure the computer is on this Wi-Fi, or that Tailscale is on.',
      ),
      FailureKind.notPaired => (
        'Pair again',
        'This computer no longer recognises this phone. It may have been removed in '
            'PairDesk settings on the computer. Remove it here and scan a new code.',
      ),
      FailureKind.badToken => (
        'Code expired',
        'This pairing code was already used or has expired. Show a new code on the computer '
            'and scan it again.',
      ),
      FailureKind.version => ('Update needed', e.message),
      _ => ('Couldn\'t connect', e.message),
    };
    await _showMessage(title, body, forget: e.kind == FailureKind.notPaired ? laptop : null);
  }

  Future<void> _showMessage(String title, String body, {Laptop? forget}) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          if (forget != null)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _model.forget(forget);
              },
              child: Text('Remove ${forget.name}'),
            ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _confirmForget(Laptop laptop) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${laptop.name}?'),
        content: const Text(
          'This phone will forget the computer. To use it again, scan a new pairing code. '
          'To also remove this phone from the computer, use PairDesk settings there.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (yes == true) await _model.forget(laptop);
  }

  Future<void> _rename(Laptop laptop) async {
    final controller = TextEditingController(text: laptop.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 64,
          decoration: const InputDecoration(labelText: 'Name on this phone'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) await _model.rename(laptop, name);
  }

  // ---- UI -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _model,
      builder: (context, _) {
        final laptops = _model.laptops;
        return Scaffold(
          appBar: AppBar(
            title: const Text('PairDesk'),
            actions: [
              if (_model.settings case final settings?)
                IconButton(
                  tooltip: 'Settings',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () =>
                      Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => SettingsScreen(settings: settings))),
                ),
            ],
          ),
          floatingActionButton: laptops.isEmpty
              ? null
              : FloatingActionButton.extended(
                  onPressed: _busy ? null : _addComputer,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan pairing code'),
                ),
          body: laptops.isEmpty
              ? _EmptyState(onAdd: _busy ? null : _addComputer)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                  children: [
                    for (final l in laptops)
                      _LaptopTile(
                        laptop: l,
                        onTap: _busy ? null : () => _connect(l),
                        onRename: () => _rename(l),
                        onForget: () => _confirmForget(l),
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class _LaptopTile extends StatelessWidget {
  const _LaptopTile({
    required this.laptop,
    required this.onTap,
    required this.onRename,
    required this.onForget,
  });

  final Laptop laptop;
  final VoidCallback? onTap;
  final VoidCallback onRename;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final os = switch (laptop.os) {
      'windows' => 'Windows',
      'linux' => 'Linux',
      'macos' => 'macOS',
      _ => null,
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          foregroundColor: scheme.onPrimaryContainer,
          child: const Icon(Icons.laptop),
        ),
        title: Text(laptop.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(switch ((os, laptop.reachableAnywhere)) {
          (null, true) => 'Wi-Fi or Tailscale',
          (null, false) => 'Tap to connect',
          (final os?, true) => '$os · Wi-Fi or Tailscale',
          (final os?, false) => '$os · tap to connect',
        }),
        onTap: onTap,
        trailing: PopupMenuButton<String>(
          tooltip: 'More',
          onSelected: (v) => v == 'rename' ? onRename() : onForget(),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'forget', child: Text('Remove')),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget step(String n, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(radius: 12, child: Text(n, style: const TextStyle(fontSize: 12))),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyLarge)),
        ],
      ),
    );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.phonelink, size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('Pair your computer', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'You only do this once. After that, open the app and you\'re connected.',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              step('1', 'Install PairDesk on your computer and open it.'),
              step('2', 'It shows a QR code. Tap below and scan it.'),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan pairing code'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgressDialog extends StatelessWidget {
  const _ProgressDialog({required this.connection});

  final AgentConnection connection;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: ListenableBuilder(
          listenable: connection,
          builder: (_, _) => Row(
            children: [
              const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
              const SizedBox(width: 20),
              Expanded(child: Text(connection.progress ?? 'Connecting…')),
            ],
          ),
        ),
        actions: [TextButton(onPressed: connection.cancel, child: const Text('Cancel'))],
      ),
    );
  }
}
