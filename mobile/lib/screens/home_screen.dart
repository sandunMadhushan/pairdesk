// SPDX-License-Identifier: GPL-3.0-or-later
// The app's home: paired computers (the last one used gets the big card),
// and Settings, under a floating bar with "+" to add a computer. With a
// single computer the app connects by itself when it opens.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, HapticFeedback;
import 'package:url_launcher/url_launcher.dart';

import '../agent_connection.dart';
import '../app_model.dart';
import '../files/native_files.dart';
import '../files/share_inbox.dart';
import '../pairing/laptop.dart';
import '../pairing/pairing_link.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import '../update_check.dart';
import '../update_install.dart';
import 'control_screen.dart';
import 'remote_help_screen.dart';
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

  /// The computer being connected to: its card shows the progress.
  String? _connectingKey;
  int _tab = 0;

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
    if (_tab != 0) setState(() => _tab = 0);
    final ok = await _withProgress(() => _model.connect(laptop), laptop: laptop);
    if (ok) await _openControl(laptop);
  }

  /// "+": scan a code or paste a link.
  Future<void> _addComputer() async {
    if (_busy) return;
    final choice = await showPdSheet<String>(context, (ctx) => const _AddSheet());
    if (!mounted) return;
    if (choice == 'scan') await _scan();
    if (choice == 'paste') await _pasteLink();
  }

  Future<void> _scan() async {
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
    final link = await showPdSheet<String>(
      context,
      (ctx) => _PasteLinkSheet(
        initial: clip.startsWith('pairdesk://') || clip.startsWith('https://pairdesk.') ? clip : '',
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
      final yes = await showPdSheet<bool>(
        context,
        (ctx) => _Confirm(
          icon: Icons.support_agent_rounded,
          title: 'Help on ${info.name}?',
          body:
              'Someone asked for your help. You\'ll see and control their computer for up to '
              '2 hours, or until either of you ends it. They see that you\'re connected.',
          action: 'Connect',
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
      PageRouteBuilder<void>(
        transitionDuration: PdMotion.move,
        reverseTransitionDuration: PdMotion.fade,
        pageBuilder: (_, _, _) => ControlScreen(
          connection: _conn,
          laptopKey: laptop.key,
          settings: _model.settings,
          helping: laptop.helping,
        ),
        transitionsBuilder: (context, a, _, child) {
          if (PdMotion.reduced(context)) return FadeTransition(opacity: a, child: child);
          final curved = CurvedAnimation(parent: a, curve: PdMotion.curve);
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(scale: Tween(begin: 0.94, end: 1.0).animate(curved), child: child),
          );
        },
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

  /// Runs [action]: connecting shows on the computer's card, pairing in a
  /// small sheet. Returns true on success.
  Future<bool> _withProgress(Future<void> Function() action, {Laptop? laptop}) async {
    setState(() {
      _busy = true;
      _connectingKey = laptop?.key;
    });
    final navigator = Navigator.of(context);
    var sheetOpen = laptop == null;
    if (sheetOpen) {
      showModalBottomSheet<void>(
        context: context,
        isDismissible: false,
        enableDrag: false,
        showDragHandle: false,
        builder: (_) => _ProgressSheet(connection: _conn),
      ).then((_) => sheetOpen = false);
    }

    var ok = false;
    try {
      await action();
      ok = true;
    } on AgentException catch (e) {
      if (sheetOpen) navigator.pop();
      sheetOpen = false;
      if (mounted) {
        setState(() => _connectingKey = null);
        if (e.kind != FailureKind.cancelled) await _explainFailure(e, laptop);
      }
    } finally {
      if (sheetOpen) navigator.pop();
      if (mounted) {
        setState(() {
          _busy = false;
          _connectingKey = null;
        });
      }
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
    if (e.kind == FailureKind.unreachable && laptop != null) {
      final again = await showPdSheet<String>(context, (ctx) => _CantReach(laptop: laptop));
      if (!mounted) return;
      switch (again) {
        case 'retry':
          await _connect(laptop);
        case 'address':
          await _addAddress(laptop);
        case 'help':
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RemoteHelpScreen()));
      }
      return;
    }
    final (title, body) = switch (e.kind) {
      FailureKind.unreachable => (
        'Can\'t reach the computer',
        'Check that the computer is on and awake, and that PairDesk is running on it (look for '
            'the tray icon).',
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
    return showPdSheet<void>(
      context,
      (ctx) => _Message(
        title: title,
        body: body,
        forget: forget == null
            ? null
            : () {
                Navigator.pop(ctx);
                _model.forget(forget);
              },
        forgetLabel: forget == null ? null : 'Remove ${forget.name}',
      ),
    );
  }

  Future<void> _menu(Laptop laptop) async {
    final choice = await showPdSheet<String>(context, (ctx) => _ComputerMenu(laptop: laptop));
    if (!mounted) return;
    switch (choice) {
      case 'rename':
        await _rename(laptop);
      case 'address':
        await _addAddress(laptop);
      case 'remove':
        await _confirmForget(laptop);
    }
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
              'without it, if your router forwards the port — add ":port" if the router '
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

  String _greeting() {
    final h = DateTime.now().hour;
    return h < 5
        ? 'Good night'
        : h < 12
        ? 'Good morning'
        : h < 18
        ? 'Good afternoon'
        : 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_model, ?widget.updates, ?widget.installer, _conn]),
      builder: (context, _) {
        final settings = _model.settings;
        return Scaffold(
          backgroundColor: c.bg,
          extendBody: true,
          body: FadeIndexedStack(
            index: settings == null ? 0 : _tab,
            children: [
              SafeArea(bottom: false, child: _computers(context)),
              if (settings != null)
                SettingsScreen(settings: settings, updates: widget.updates, embedded: true),
            ],
          ),
          bottomNavigationBar: SafeArea(
            minimum: const EdgeInsets.only(bottom: 16),
            child: Center(
              heightFactor: 1,
              child: _HomeNav(
                tab: _tab,
                showSettings: settings != null,
                onTab: (i) => setState(() => _tab = i),
                onAdd: _busy ? null : _addComputer,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _computers(BuildContext context) {
    final c = PdColors.of(context);
    final laptops = _model.laptops;
    final update = widget.updates?.available;
    final installer = widget.installer;
    final shared = ShareInbox.instance.pending;
    final head = Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 18, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_greeting(), style: TextStyle(fontSize: 15, color: c.sub)),
                const Text(
                  'Your computers',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.5),
                ),
              ],
            ),
          ),
          RoundButton(
            icon: Icons.add_link_rounded,
            tooltip: 'Paste a link',
            onPressed: _busy ? null : _pasteLink,
          ),
        ],
      ),
    );
    if (laptops.isEmpty) {
      return ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          head,
          if (update != null && installer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _UpdateCard(update: update, installer: installer, onDismiss: widget.updates!.dismiss),
            ),
          FadeRise(
            child: _EmptyState(onScan: _busy ? null : _scan, onPaste: _busy ? null : _pasteLink),
          ),
        ],
      );
    }
    final hero = laptops.first;
    return ListView(
      padding: const EdgeInsets.only(bottom: 120),
      children: [
        head,
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (update != null && installer != null) ...[
                _UpdateCard(update: update, installer: installer, onDismiss: widget.updates!.dismiss),
                const SizedBox(height: 12),
              ],
              FadeRise(
                child: _HeroCard(
                  laptop: hero,
                  connecting: _connectingKey == hero.key,
                  progress: _conn.progress,
                  onConnect: _busy ? null : () => _connect(hero),
                  onCancel: _conn.cancel,
                  onMore: () => _menu(hero),
                ),
              ),
              for (final (i, l) in laptops.skip(1).indexed) ...[
                const SizedBox(height: 10),
                FadeRise(
                  delay: Duration(milliseconds: 40 * (i + 1)),
                  child: _LaptopRow(
                    laptop: l,
                    connecting: _connectingKey == l.key,
                    onTap: _busy ? null : () => _connect(l),
                    onCancel: _conn.cancel,
                    onMore: () => _menu(l),
                  ),
                ),
              ],
              if (shared != null) ...[const SizedBox(height: 10), _SharedCard(shared: shared)],
            ],
          ),
        ),
      ],
    );
  }
}

String _subtitle(Laptop laptop) {
  final os = switch (laptop.os) {
    'windows' => 'Windows',
    'linux' => 'Linux',
    'macos' => 'macOS',
    _ => null,
  };
  if (laptop.helping) return 'Helping · temporary access';
  return switch ((os, laptop.reachableAnywhere)) {
    (null, true) => 'Here or away',
    (null, false) => 'Tap to connect',
    (final os?, true) => '$os · here or away',
    (final os?, false) => '$os · tap to connect',
  };
}

IconData _laptopIcon(Laptop l) => l.helping ? Icons.support_agent_rounded : Icons.laptop_rounded;

/// The last-used computer: the big lime card with Connect.
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.laptop,
    required this.connecting,
    required this.progress,
    required this.onConnect,
    required this.onCancel,
    required this.onMore,
  });

  final Laptop laptop;
  final bool connecting;
  final String? progress;
  final VoidCallback? onConnect;
  final VoidCallback onCancel;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    const ink = PdColors.onAccent;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(32), boxShadow: c.glow),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(18)),
                child: Icon(_laptopIcon(laptop), size: 28, color: PdColors.lime),
              ),
              const Spacer(),
              RoundButton(
                icon: Icons.more_horiz_rounded,
                tooltip: 'More',
                onPressed: onMore,
                background: const Color(0x14111111),
                foreground: ink,
                size: 44,
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            laptop.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
              color: ink,
            ),
          ),
          const SizedBox(height: 4),
          AnimatedSwitcher(
            duration: PdMotion.fade,
            layoutBuilder: (current, previous) =>
                Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
            child: Text(
              connecting ? (progress ?? 'Connecting…') : _subtitle(laptop),
              key: ValueKey(connecting ? 'p:$progress' : 's'),
              maxLines: 2,
              style: const TextStyle(fontSize: 15, color: Color(0xFF2E3320)),
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 56,
            child: Row(
              children: [
                Expanded(
                  child: _ConnectButton(connecting: connecting, onPressed: onConnect),
                ),
                AnimatedSize(
                  duration: PdMotion.move,
                  curve: PdMotion.curve,
                  child: connecting
                      ? Padding(
                          padding: const EdgeInsets.only(left: 10),
                          child: SecondaryButton(
                            label: 'Cancel',
                            onPressed: onCancel,
                            background: const Color(0x14111111),
                            foreground: ink,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Black "Connect" pill that shrinks into a spinner while connecting.
class _ConnectButton extends StatelessWidget {
  const _ConnectButton({required this.connecting, required this.onPressed});
  final bool connecting;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: connecting ? 'Connecting' : 'Connect',
      excludeSemantics: true,
      child: Pressable(
        onTap: connecting ? null : onPressed,
        child: Container(
          decoration: BoxDecoration(color: PdColors.onAccent, borderRadius: BorderRadius.circular(999)),
          alignment: Alignment.center,
          child: AnimatedSwitcher(
            duration: PdMotion.fade,
            child: connecting
                ? const Row(
                    key: ValueKey(1),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PdSpinner(track: Color(0x40FFFFFF)),
                      SizedBox(width: 12),
                      Text(
                        'Connecting',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ],
                  )
                : const Row(
                    key: ValueKey(0),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Connect',
                        style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                      ),
                      SizedBox(width: 8),
                      Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _LaptopRow extends StatelessWidget {
  const _LaptopRow({
    required this.laptop,
    required this.connecting,
    required this.onTap,
    required this.onCancel,
    required this.onMore,
  });

  final Laptop laptop;
  final bool connecting;
  final VoidCallback? onTap;
  final VoidCallback onCancel;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return Pressable(
      scale: 0.97,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: c.s1, borderRadius: BorderRadius.circular(24)),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: c.s2, borderRadius: BorderRadius.circular(16)),
              child: connecting
                  ? Center(child: PdSpinner(color: c.ink, size: 22))
                  : Icon(_laptopIcon(laptop), size: 24, color: c.ink),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    laptop.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    connecting ? 'Connecting…' : _subtitle(laptop),
                    style: TextStyle(fontSize: 13, color: c.sub),
                  ),
                ],
              ),
            ),
            if (connecting)
              TextButton(onPressed: onCancel, child: const Text('Cancel'))
            else
              RoundButton(
                icon: Icons.more_horiz_rounded,
                tooltip: 'More',
                onPressed: onMore,
                background: c.s2,
                size: 44,
              ),
          ],
        ),
      ),
    );
  }
}

class _SharedCard extends StatelessWidget {
  const _SharedCard({required this.shared});
  final SharedItems shared;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: c.sub.withValues(alpha: 0.5), width: 1.5),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: c.s1, borderRadius: BorderRadius.circular(16)),
            child: Icon(Icons.ios_share_rounded, color: c.ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  shared.files.isEmpty
                      ? 'Text to send to a computer\'s clipboard'
                      : shared.files.length == 1
                      ? '${shared.files.single.name} to send'
                      : '${shared.files.length} files to send',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                Text('Choose a computer above', style: TextStyle(fontSize: 13, color: c.sub)),
              ],
            ),
          ),
          RoundButton(
            icon: Icons.close_rounded,
            tooltip: 'Discard',
            onPressed: () => ShareInbox.instance.take(),
            background: Colors.transparent,
            size: 44,
          ),
        ],
      ),
    );
  }
}

class _HomeNav extends StatelessWidget {
  const _HomeNav({required this.tab, required this.showSettings, required this.onTab, required this.onAdd});

  final int tab;
  final bool showSettings;
  final ValueChanged<int> onTab;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    Widget item(int i, IconData icon, String label) {
      final active = tab == i;
      return Semantics(
        button: true,
        selected: active,
        label: label,
        excludeSemantics: true,
        child: GestureDetector(
          onTap: () {
            if (!active) HapticFeedback.selectionClick();
            onTab(i);
          },
          child: AnimatedContainer(
            duration: PdMotion.move,
            curve: PdMotion.spring,
            height: 52,
            padding: EdgeInsets.symmetric(horizontal: active ? 18 : 14),
            decoration: BoxDecoration(
              color: active ? c.navOn : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22, color: active ? PdColors.onAccent : c.navFg),
                AnimatedSize(
                  duration: PdMotion.move,
                  curve: PdMotion.spring,
                  child: active
                      ? Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            label,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: PdColors.onAccent,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      height: 66,
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: c.nav,
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [BoxShadow(color: Color(0x38000000), blurRadius: 30, offset: Offset(0, 14))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          item(0, Icons.laptop_rounded, 'Computers'),
          const SizedBox(width: 8),
          RoundButton(
            icon: Icons.add_rounded,
            tooltip: 'Add a computer',
            onPressed: onAdd,
            background: c.dark ? c.s2 : const Color(0xFF2A2A2A),
            foreground: c.dark ? c.ink : Colors.white,
            size: 52,
            iconSize: 26,
          ),
          if (showSettings) ...[const SizedBox(width: 8), item(1, Icons.tune_rounded, 'Settings')],
        ],
      ),
    );
  }
}

class _AddSheet extends StatelessWidget {
  const _AddSheet();

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    Widget option(String value, IconData icon, String title, String sub, {bool primary = false}) {
      final fg = primary ? PdColors.onAccent : c.ink;
      return Pressable(
        scale: 0.97,
        onTap: () => Navigator.pop(context, value),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: primary ? c.accent : c.s2,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(color: primary ? PdColors.onAccent : c.s1, shape: BoxShape.circle),
                child: Icon(icon, color: primary ? PdColors.lime : c.ink),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: fg),
                    ),
                    Text(
                      sub,
                      style: TextStyle(fontSize: 14, color: primary ? const Color(0xFF2E3320) : c.sub),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: fg),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PdTitle('Add a computer', subtitle: 'Open PairDesk on the computer first.'),
          const SizedBox(height: 16),
          option(
            'scan',
            Icons.qr_code_scanner_rounded,
            'Scan pairing code',
            'The QR code on the computer',
            primary: true,
          ),
          const SizedBox(height: 10),
          option('paste', Icons.add_link_rounded, 'Paste a link', 'A pairing or "Get help" link'),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.support_agent_rounded, color: c.sub, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Helping someone? Ask them for a "Get help" link and paste it here.',
                  style: TextStyle(fontSize: 14, color: c.sub, height: 1.4),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PasteLinkSheet extends StatefulWidget {
  const _PasteLinkSheet({required this.initial});
  final String initial;

  @override
  State<_PasteLinkSheet> createState() => _PasteLinkSheetState();
}

class _PasteLinkSheetState extends State<_PasteLinkSheet> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (clip.isNotEmpty) _controller.text = clip;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PdTitle('Paste a link', subtitle: 'From PairDesk on a computer, or a "Get help" link.'),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: _controller.text.isEmpty,
            maxLines: 3,
            minLines: 1,
            decoration: InputDecoration(
              hintText: 'https://pairdesk.madhushan.me/p#…',
              suffixIcon: TextButton(onPressed: _paste, child: const Text('Paste')),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(context)),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: PrimaryButton(
                  label: 'Continue',
                  onPressed: () => Navigator.pop(context, _controller.text.trim()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ComputerMenu extends StatelessWidget {
  const _ComputerMenu({required this.laptop});
  final Laptop laptop;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(16)),
                child: Icon(_laptopIcon(laptop), color: PdColors.onAccent),
              ),
              const SizedBox(width: 12),
              Expanded(child: PdTitle(laptop.name, subtitle: _subtitle(laptop), size: 22)),
            ],
          ),
          const SizedBox(height: 14),
          PdCard(
            color: c.s2,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              children: [
                PdRow(
                  icon: Icons.edit_outlined,
                  title: 'Rename',
                  subtitle: 'Only on this phone',
                  iconBackground: c.s1,
                  onTap: () => Navigator.pop(context, 'rename'),
                ),
                const PdDivider(),
                PdRow(
                  icon: Icons.public_rounded,
                  title: 'Add an address',
                  subtitle: 'Tailscale, a name of your own, or your router',
                  iconBackground: c.s1,
                  onTap: () => Navigator.pop(context, 'address'),
                ),
                const PdDivider(),
                PdRow(
                  icon: Icons.delete_outline_rounded,
                  title: 'Remove',
                  subtitle: 'Forget it on this phone',
                  iconBackground: c.s1,
                  onTap: () => Navigator.pop(context, 'remove'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Can't reach …": what to check, and three ways on.
class _CantReach extends StatelessWidget {
  const _CantReach({required this.laptop});
  final Laptop laptop;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    Widget check(String t) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_rounded, size: 20, color: c.ink),
          const SizedBox(width: 10),
          Expanded(child: Text(t, style: const TextStyle(fontSize: 15, height: 1.35))),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: c.s2, shape: BoxShape.circle),
              child: Icon(Icons.wifi_off_rounded, color: c.ink),
            ),
          ),
          const SizedBox(height: 12),
          PdTitle('Can\'t reach ${laptop.name}', subtitle: 'Check these, then try again:'),
          const SizedBox(height: 10),
          check('The computer is on and awake'),
          check('PairDesk is running on it (look for the tray icon)'),
          check(
            laptop.reachableAnywhere
                ? 'Away from home: the relay or Tailscale is on, on the computer'
                : 'The phone and the computer are on the same Wi-Fi',
          ),
          const SizedBox(height: 14),
          PrimaryButton(
            label: 'Try again',
            icon: Icons.refresh_rounded,
            onPressed: () => Navigator.pop(context, 'retry'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SecondaryButton(
                  label: 'Add an address',
                  height: 50,
                  onPressed: () => Navigator.pop(context, 'address'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SecondaryButton(
                  label: 'Away from home',
                  height: 50,
                  onPressed: () => Navigator.pop(context, 'help'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.body, this.forget, this.forgetLabel});
  final String title;
  final String body;
  final VoidCallback? forget;
  final String? forgetLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PdTitle(title),
          const SizedBox(height: 8),
          Text(body, style: TextStyle(fontSize: 15, height: 1.45, color: PdColors.of(context).sub)),
          const SizedBox(height: 18),
          Row(
            children: [
              if (forget != null) ...[
                Expanded(
                  child: SecondaryButton(label: forgetLabel!, onPressed: forget),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: PrimaryButton(label: 'OK', onPressed: () => Navigator.pop(context)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Confirm extends StatelessWidget {
  const _Confirm({required this.icon, required this.title, required this.body, required this.action});
  final IconData icon;
  final String title;
  final String body;
  final String action;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
              child: Icon(icon, color: PdColors.onAccent),
            ),
          ),
          const SizedBox(height: 12),
          PdTitle(title),
          const SizedBox(height: 8),
          Text(body, style: TextStyle(fontSize: 15, height: 1.45, color: c.sub)),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: PrimaryButton(label: action, onPressed: () => Navigator.pop(context, true)),
              ),
            ],
          ),
        ],
      ),
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
    final c = PdColors.of(context);
    final update = widget.update;
    final installer = widget.installer;
    final failed = installer.stage == UpdateStage.failed;
    final (title, detail) = switch (installer.stage) {
      UpdateStage.downloading => ('Downloading ${update.version}', null),
      UpdateStage.installing => ('Getting it ready…', null),
      UpdateStage.waiting => (
        'Finish in Android',
        'Android is asking you to confirm. PairDesk restarts once it is installed.',
      ),
      UpdateStage.failed => ('Update failed', installer.error),
      UpdateStage.idle => ('Version ${update.version} is ready', 'Downloads and installs over this one'),
    };
    Widget small(String label, VoidCallback onTap, {bool strong = false}) => Pressable(
      onTap: onTap,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: strong ? c.inv : c.s2, borderRadius: BorderRadius.circular(999)),
        child: Text(
          label,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: strong ? c.onInv : c.ink),
        ),
      ),
    );
    return PdCard(
      padding: const EdgeInsets.all(12),
      radius: 24,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: c.inv, shape: BoxShape.circle),
                child: Icon(
                  failed ? Icons.error_outline_rounded : Icons.system_update_alt_rounded,
                  size: 20,
                  color: c.dark ? PdColors.onAccent : PdColors.lime,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    if (detail != null) Text(detail, style: TextStyle(fontSize: 13, color: c.sub)),
                  ],
                ),
              ),
              if (installer.stage == UpdateStage.idle) small('Update', _update, strong: true),
            ],
          ),
          if (installer.stage == UpdateStage.downloading)
            Padding(
              padding: const EdgeInsets.fromLTRB(54, 10, 4, 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(value: installer.progress, minHeight: 6),
              ),
            ),
          if (installer.stage != UpdateStage.downloading && installer.stage != UpdateStage.installing)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: switch (installer.stage) {
                  UpdateStage.waiting => [small('Close', installer.reset)],
                  UpdateStage.failed => [
                    small('Close', installer.reset),
                    small('Open GitHub', () => launchUrl(update.notes, mode: LaunchMode.externalApplication)),
                    small('Try again', _update, strong: true),
                  ],
                  _ => [
                    small('Not now', widget.onDismiss),
                    small('What\'s new', () => launchUrl(update.notes, mode: LaunchMode.externalApplication)),
                  ],
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onScan, required this.onPaste});

  final VoidCallback? onScan;
  final VoidCallback? onPaste;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    Widget step(String n, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.s2, shape: BoxShape.circle),
            child: Text(n, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 15))),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 230,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: c.accent,
              borderRadius: BorderRadius.circular(34),
              boxShadow: c.glow,
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(Icons.phonelink_rounded, size: 40, color: PdColors.onAccent),
                Text(
                  'Pair your computer',
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.8,
                    height: 1.05,
                    color: PdColors.onAccent,
                  ),
                ),
                Text(
                  'You do this once. After that, PairDesk connects by itself.',
                  style: TextStyle(fontSize: 15, color: Color(0xFF2E3320)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          PdCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              children: [
                step('1', 'Install PairDesk on your computer and open it.'),
                step('2', 'It shows a QR code. Tap below and scan it.'),
              ],
            ),
          ),
          const SizedBox(height: 14),
          PrimaryButton(label: 'Scan pairing code', icon: Icons.qr_code_scanner_rounded, onPressed: onScan),
          const SizedBox(height: 10),
          SecondaryButton(label: 'Paste a link instead', icon: Icons.add_link_rounded, onPressed: onPaste),
        ],
      ),
    );
  }
}

class _ProgressSheet extends StatelessWidget {
  const _ProgressSheet({required this.connection});

  final AgentConnection connection;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return PopScope(
      canPop: false,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
          child: ListenableBuilder(
            listenable: connection,
            builder: (_, _) => Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(color: c.inv, shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: PdSpinner(size: 24, color: c.dark ? PdColors.onAccent : PdColors.lime),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    connection.progress ?? 'Connecting…',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(onPressed: connection.cancel, child: const Text('Cancel')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
