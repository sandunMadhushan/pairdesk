// SPDX-License-Identifier: GPL-3.0-or-later
// Paired computers. Tap one to connect; with a single computer the app
// connects by itself when it opens.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;
import 'package:url_launcher/url_launcher.dart';

import '../agent_connection.dart';
import '../files/share_inbox.dart';
import '../app_model.dart';
import '../pairing/laptop.dart';
import '../pairing/pairing_link.dart';
import '../update_check.dart';
import '../update_install.dart';
import 'control_screen.dart';
import 'scan_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.model, this.updates, this.installer});

  final AppModel model;

  /// New releases on GitHub (only in GitHub builds).
  final UpdateChecker? updates;

  /// Downloads and installs an update. Null in tests and on F-Droid builds.
  final UpdateInstaller? installer;

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
    ShareInbox.instance.addListener(_onShared);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Opened from a pairing or "Get help" link.
      if (ShareInbox.instance.link != null) {
        _onShared();
        return;
      }
      if (!_model.autoConnectDone && _model.laptops.length == 1) {
        _model.autoConnectDone = true;
        _connect(_model.laptops.first);
      }
    });
  }

  @override
  void dispose() {
    ShareInbox.instance.removeListener(_onShared);
    super.dispose();
  }

  /// Something was shared with PairDesk while no computer is open: with
  /// one computer, go straight to it (the control screen sends it).
  void _onShared() {
    if (!mounted) return;
    setState(() {});
    final route = ModalRoute.of(context);
    if (ShareInbox.instance.link != null && route != null && route.isCurrent && !_busy) {
      final link = ShareInbox.instance.takeLink();
      if (link != null) _pairWithLink(link);
      return;
    }
    if (ShareInbox.instance.pending != null &&
        route != null &&
        route.isCurrent &&
        !_busy &&
        _model.laptops.length == 1) {
      _connect(_model.laptops.first);
    }
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
    await _pairWithLink(link);
  }

  /// A link someone sent (pairing, or "Get help"), pasted in.
  Future<void> _pasteLink() async {
    if (_busy) return;
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (!mounted) return;
    final controller = TextEditingController(
      text: clip.startsWith('pairdesk://') || clip.startsWith('https://pairdesk.') ? clip : '',
    );
    final link = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste a link'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('A pairing or "Get help" link from PairDesk on a computer.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: controller.text.isEmpty,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(hintText: 'https://pairdesk.madhushan.me/p#…'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (link == null || link.isEmpty || !mounted) return;
    await _pairWithLink(link);
  }

  Future<void> _pairWithLink(String link) async {
    final PairingInfo info;
    try {
      info = parsePairingLink(link);
    } on PairingLinkException catch (e) {
      _showMessage('Can\'t use this link', e.message);
      return;
    }
    if (info.help) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.support_agent),
          title: Text('Help on ${info.name}?'),
          content: const Text(
            'Someone asked for your help. You\'ll see and control their computer for up to '
            '2 hours, or until either of you ends it. They see that you\'re connected.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Connect')),
          ],
        ),
      );
      if (yes != true || !mounted) return;
    }
    Laptop? paired;
    final ok = await _withProgress(() async => paired = await _model.pair(info));
    if (!ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          info.help
              ? 'Connected to ${paired!.name}.'
              : 'Paired with ${paired!.name}. It\'s saved on this phone.',
        ),
      ),
    );
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
    if (error.kind == FailureKind.notPaired && laptop.helping) {
      await _helpEnded(laptop);
    } else if (error.kind == FailureKind.notPaired) {
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

  /// A help session's access ended on the computer: forget it here too.
  Future<void> _helpEnded(Laptop laptop) async {
    await _model.forget(laptop);
    if (!mounted) return;
    await _showMessage(
      'Help session ended',
      'Your access to ${laptop.name} ended. To help again, ask for a new "Get help" link.',
    );
  }

  Future<void> _explainFailure(AgentException e, Laptop? laptop) async {
    if (e.kind == FailureKind.notPaired && laptop != null && laptop.helping) return _helpEnded(laptop);
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

  /// Lets the owner type an address PairDesk hasn't seen, so a computer
  /// paired before Tailscale was set up isn't a dead end.
  Future<void> _addAddress(Laptop laptop) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add an address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'An address this computer can be reached at. Its Remote access page shows them: '
              'the Tailscale one (100.x.x.x, or a name ending in .ts.net) works from anywhere '
              'with Tailscale on. A name of your own that points at your home connection works '
              'without it, if your router forwards the port \u2014 add ":port" if the router '
              'uses a different one.',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 253,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Address', hintText: '100.101.102.103'),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    final ok = await _model.addAddress(laptop, value);
    if (!mounted) return;
    if (!ok) {
      await _showMessage(
        'Not an address PairDesk can use',
        'Type an IP address (like 192.168.1.5 or 100.101.102.103) or a name '
            '(like pc.tail1234.ts.net or home.example.org), and ":port" after it if '
            'the port is not the usual one.',
      );
    }
  }

  // ---- UI -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_model, ?widget.updates, ?widget.installer]),
      builder: (context, _) {
        final laptops = _model.laptops;
        final update = widget.updates?.available;
        final installer = widget.installer;
        return Scaffold(
          appBar: AppBar(
            title: const Text('PairDesk'),
            actions: [
              IconButton(
                tooltip: 'Paste a link',
                icon: const Icon(Icons.add_link),
                onPressed: _busy ? null : _pasteLink,
              ),
              if (_model.settings case final settings?)
                IconButton(
                  tooltip: 'Settings',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SettingsScreen(settings: settings, updates: widget.updates),
                    ),
                  ),
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
              ? Column(
                  children: [
                    if (update != null && installer != null)
                      _UpdateCard(update: update, installer: installer, onDismiss: widget.updates!.dismiss),
                    Expanded(
                      child: _EmptyState(
                        onAdd: _busy ? null : _addComputer,
                        onPaste: _busy ? null : _pasteLink,
                      ),
                    ),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                  children: [
                    if (update != null && installer != null)
                      _UpdateCard(update: update, installer: installer, onDismiss: widget.updates!.dismiss),
                    if (ShareInbox.instance.pending case final shared?)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.ios_share),
                          title: Text(
                            shared.files.isEmpty
                                ? 'Text to send to a computer\'s clipboard'
                                : shared.files.length == 1
                                ? '${shared.files.single.name} to send'
                                : '${shared.files.length} files to send',
                          ),
                          subtitle: const Text('Choose a computer below.'),
                          trailing: IconButton(
                            tooltip: 'Discard',
                            icon: const Icon(Icons.close),
                            onPressed: () => ShareInbox.instance.take(),
                          ),
                        ),
                      ),
                    for (final l in laptops)
                      _LaptopTile(
                        laptop: l,
                        onTap: _busy ? null : () => _connect(l),
                        onRename: () => _rename(l),
                        onAddAddress: () => _addAddress(l),
                        onForget: () => _confirmForget(l),
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class _UpdateCard extends StatefulWidget {
  const _UpdateCard({required this.update, required this.installer, required this.onDismiss});

  final AvailableUpdate update;
  final UpdateInstaller installer;
  final VoidCallback onDismiss;

  @override
  State<_UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<_UpdateCard> {
  Future<void> _update() async {
    final installer = widget.installer;
    if (!await installer.canInstall()) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Let PairDesk install updates'),
          content: const Text(
            'Android asks for this once. On the next screen turn on "Allow from this source" '
            'for PairDesk, then come back and press Update.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Open settings')),
          ],
        ),
      );
      if (go == true) await installer.requestPermission();
      return;
    }
    await installer.install(widget.update);
  }

  @override
  Widget build(BuildContext context) {
    final update = widget.update;
    final installer = widget.installer;
    final theme = Theme.of(context);
    final (title, detail) = switch (installer.stage) {
      UpdateStage.downloading => ('Downloading PairDesk ${update.version}', null),
      UpdateStage.installing => ('Getting it ready\u2026', null),
      UpdateStage.waiting => (
        'Finish in Android',
        'Android is asking you to confirm. PairDesk restarts once it is installed.',
      ),
      UpdateStage.failed => ('Update failed', installer.error),
      UpdateStage.idle => (
        'PairDesk ${update.version} is available',
        'Press Update: PairDesk downloads it and Android installs it over this version.',
      ),
    };
    return Card(
      margin: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  installer.stage == UpdateStage.failed ? Icons.error_outline : Icons.system_update_outlined,
                  color: installer.stage == UpdateStage.failed ? theme.colorScheme.error : null,
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
              ],
            ),
            if (detail != null)
              Padding(padding: const EdgeInsets.only(left: 36, top: 4), child: Text(detail)),
            if (installer.stage == UpdateStage.downloading)
              Padding(
                padding: const EdgeInsets.only(left: 36, top: 12, right: 8),
                child: LinearProgressIndicator(value: installer.progress),
              ),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              children: switch (installer.stage) {
                UpdateStage.downloading || UpdateStage.installing => const <Widget>[],
                UpdateStage.waiting => [TextButton(onPressed: installer.reset, child: const Text('Close'))],
                UpdateStage.failed => [
                  TextButton(onPressed: installer.reset, child: const Text('Close')),
                  TextButton(
                    onPressed: () => launchUrl(update.notes, mode: LaunchMode.externalApplication),
                    child: const Text('Open GitHub'),
                  ),
                  FilledButton.tonal(onPressed: _update, child: const Text('Try again')),
                ],
                UpdateStage.idle => [
                  TextButton(onPressed: widget.onDismiss, child: const Text('Not now')),
                  TextButton(
                    onPressed: () => launchUrl(update.notes, mode: LaunchMode.externalApplication),
                    child: const Text('What\'s new'),
                  ),
                  FilledButton.tonal(onPressed: _update, child: const Text('Update')),
                ],
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _LaptopTile extends StatelessWidget {
  const _LaptopTile({
    required this.laptop,
    required this.onTap,
    required this.onRename,
    required this.onAddAddress,
    required this.onForget,
  });

  final Laptop laptop;
  final VoidCallback? onTap;
  final VoidCallback onRename;
  final VoidCallback onAddAddress;
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
          child: Icon(laptop.helping ? Icons.support_agent : Icons.laptop),
        ),
        title: Text(laptop.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          laptop.helping
              ? 'Helping · temporary access'
              : switch ((os, laptop.reachableAnywhere)) {
                  (null, true) => 'Here or away',
                  (null, false) => 'Tap to connect',
                  (final os?, true) => '$os · here or away',
                  (final os?, false) => '$os · tap to connect',
                },
        ),
        onTap: onTap,
        trailing: PopupMenuButton<String>(
          tooltip: 'More',
          onSelected: (v) => switch (v) {
            'rename' => onRename(),
            'address' => onAddAddress(),
            _ => onForget(),
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'address', child: Text('Add an address')),
            PopupMenuItem(value: 'forget', child: Text('Remove')),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd, required this.onPaste});

  final VoidCallback? onAdd;
  final VoidCallback? onPaste;

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
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onPaste,
                  icon: const Icon(Icons.add_link),
                  label: const Text('Paste a link instead'),
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
