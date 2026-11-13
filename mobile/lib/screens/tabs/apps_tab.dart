// SPDX-License-Identifier: GPL-3.0-or-later
// Apps on the computer: the owner's shortcuts, favourites and every
// installed app, with search. Also used to pick an app for a button.

import 'package:flutter/material.dart';

import '../../agent_connection.dart';
import '../../buttons/custom_button.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class AppsBrowser extends StatefulWidget {
  const AppsBrowser({super.key, required this.connection, required this.onTap, this.laptopKey});

  final AgentConnection connection;
  final Future<void> Function(RemoteApp app) onTap;

  /// Enables favourites for this computer when set.
  final String? laptopKey;

  @override
  State<AppsBrowser> createState() => _AppsBrowserState();
}

class _AppsBrowserState extends State<AppsBrowser> {
  final _search = TextEditingController();
  final _favStore = FavouriteStore();
  AppsList? _list;
  RequestException? _error;
  List<String> _favs = const [];
  String _query = '';
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
    final key = widget.laptopKey;
    if (key != null) {
      _favStore.load(key).then((f) {
        if (mounted) setState(() => _favs = f);
      });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _list = null;
    });
    try {
      final list = await widget.connection.fetchApps();
      if (mounted) setState(() => _list = list);
    } on RequestException catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _toggleFav(RemoteApp app) async {
    final key = widget.laptopKey;
    if (key == null) return;
    final favs = _favs.contains(app.id) ? (_favs.where((f) => f != app.id).toList()) : [..._favs, app.id];
    setState(() => _favs = favs);
    await _favStore.save(key, favs);
  }

  Future<void> _tap(RemoteApp app) async {
    if (_busyId != null) return;
    setState(() => _busyId = app.id);
    try {
      await widget.onTap(app);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    final error = _error;
    if (error != null) {
      return _Message(
        icon: error.code == 'not_allowed' ? Icons.block_rounded : Icons.error_outline_rounded,
        text: error.message,
        action: error.code == 'not_allowed' || error.code == 'unsupported' ? null : _load,
      );
    }
    final list = _list;
    if (list == null) {
      return Center(child: PdSpinner(color: c.ink, size: 28));
    }

    bool matches(RemoteApp a) => _query.isEmpty || a.name.toLowerCase().contains(_query);
    final all = [...list.shortcuts, ...list.apps];
    final favs = [for (final id in _favs) ...all.where((a) => a.id == id && matches(a)).take(1)];
    final shortcuts = list.shortcuts.where(matches).toList();
    final apps = list.apps.where(matches).toList();

    Widget tile(RemoteApp a) {
      final fav = _favs.contains(a.id);
      return Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _tap(a),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 60),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: c.s2, borderRadius: BorderRadius.circular(12)),
                  child: _busyId == a.id
                      ? Center(child: PdSpinner(color: c.ink, size: 18))
                      : Icon(_kindIcon(a.kind), size: 20, color: c.ink),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    a.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                if (widget.laptopKey != null)
                  IconButton(
                    tooltip: fav ? 'Remove from favourites' : 'Add to favourites',
                    icon: Icon(
                      fav ? Icons.star_rounded : Icons.star_outline_rounded,
                      color: fav ? (c.dark ? PdColors.lime : c.ink) : c.sub,
                    ),
                    onPressed: () => _toggleFav(a),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    Widget group(String title, List<RemoteApp> items) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
            child: Text(title, style: TextStyle(fontSize: 14, color: c.sub)),
          ),
          PdCard(
            padding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
            child: Column(
              children: [
                for (final (i, a) in items.indexed) ...[if (i > 0) const PdDivider(), tile(a)],
              ],
            ),
          ),
        ],
      ),
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: SearchBar(
            controller: _search,
            hintText: 'Search apps',
            leading: Icon(Icons.search_rounded, color: c.sub),
            elevation: const WidgetStatePropertyAll(0),
            constraints: const BoxConstraints(minHeight: 52),
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            trailing: [
              IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded), onPressed: _load),
            ],
          ),
        ),
        Expanded(
          child: all.isEmpty
              ? const _Message(
                  icon: Icons.apps_rounded,
                  text: 'No apps found on the computer. Add shortcuts in PairDesk settings there.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    if (favs.isNotEmpty) group('Favourites', favs),
                    if (shortcuts.isNotEmpty) group('Shortcuts', shortcuts),
                    if (apps.isNotEmpty) group('All apps', apps),
                    if (favs.isEmpty && shortcuts.isEmpty && apps.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Center(
                          child: Text('No matches', style: TextStyle(color: c.sub)),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

IconData _kindIcon(String kind) => switch (kind) {
  'url' => Icons.public_rounded,
  'folder' => Icons.folder_outlined,
  'file' => Icons.description_outlined,
  'program' => Icons.terminal_rounded,
  _ => Icons.apps_rounded,
};

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: c.sub),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, height: 1.4)),
            if (action != null) ...[
              const SizedBox(height: 12),
              SecondaryButton(label: 'Try again', height: 46, onPressed: action),
            ],
          ],
        ),
      ),
    );
  }
}

/// The Apps tab: tap opens the app on the computer.
class AppsTab extends StatelessWidget {
  const AppsTab({super.key, required this.connection, required this.laptopKey});
  final AgentConnection connection;
  final String laptopKey;

  @override
  Widget build(BuildContext context) {
    return AppsBrowser(
      connection: connection,
      laptopKey: laptopKey,
      onTap: (app) async {
        final messenger = ScaffoldMessenger.of(context);
        try {
          await connection.launch(app.id);
          messenger.showSnackBar(
            SnackBar(content: Text('Opening ${app.name}'), duration: const Duration(seconds: 2)),
          );
        } on RequestException catch (e) {
          messenger.showSnackBar(SnackBar(content: Text(e.message)));
        }
      },
    );
  }
}

/// Full-screen picker used by the button editor.
class AppPickerScreen extends StatelessWidget {
  const AppPickerScreen({super.key, required this.connection});
  final AgentConnection connection;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choose an app')),
      body: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: AppsBrowser(connection: connection, onTap: (app) async => Navigator.of(context).pop(app)),
      ),
    );
  }
}
