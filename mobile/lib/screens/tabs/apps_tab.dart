// SPDX-License-Identifier: GPL-3.0-or-later
// Apps on the computer: the owner's shortcuts, favourites and every
// installed app, with search. Also used to pick an app for a button.

import 'package:flutter/material.dart';

import '../../agent_connection.dart';
import '../../buttons/custom_button.dart';

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
    final theme = Theme.of(context);
    final error = _error;
    if (error != null) {
      return _Message(
        icon: error.code == 'not_allowed' ? Icons.block : Icons.error_outline,
        text: error.message,
        action: error.code == 'not_allowed' || error.code == 'unsupported' ? null : _load,
      );
    }
    final list = _list;
    if (list == null) {
      return const Center(child: CircularProgressIndicator());
    }

    bool matches(RemoteApp a) => _query.isEmpty || a.name.toLowerCase().contains(_query);
    final all = [...list.shortcuts, ...list.apps];
    final favs = [for (final id in _favs) ...all.where((a) => a.id == id && matches(a)).take(1)];
    final shortcuts = list.shortcuts.where(matches).toList();
    final apps = list.apps.where(matches).toList();

    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
    );
    Widget tile(RemoteApp a) => ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.secondaryContainer,
        foregroundColor: theme.colorScheme.onSecondaryContainer,
        child: _busyId == a.id
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(_kindIcon(a.kind), size: 20),
      ),
      title: Text(a.name, overflow: TextOverflow.ellipsis),
      onTap: () => _tap(a),
      trailing: widget.laptopKey == null
          ? null
          : IconButton(
              tooltip: _favs.contains(a.id) ? 'Remove from favourites' : 'Add to favourites',
              icon: Icon(_favs.contains(a.id) ? Icons.star : Icons.star_border),
              onPressed: () => _toggleFav(a),
            ),
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: SearchBar(
            controller: _search,
            hintText: 'Search apps',
            leading: const Icon(Icons.search),
            elevation: const WidgetStatePropertyAll(0),
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            trailing: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _load)],
          ),
        ),
        Expanded(
          child: all.isEmpty
              ? const _Message(
                  icon: Icons.apps_outlined,
                  text: 'No apps found on the computer. Add shortcuts in PairDesk settings there.',
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    if (favs.isNotEmpty) ...[header('Favourites'), ...favs.map(tile)],
                    if (shortcuts.isNotEmpty) ...[header('Shortcuts'), ...shortcuts.map(tile)],
                    if (apps.isNotEmpty) ...[header('All apps'), ...apps.map(tile)],
                    if (favs.isEmpty && shortcuts.isEmpty && apps.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: Text('No matches')),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

IconData _kindIcon(String kind) => switch (kind) {
  'url' => Icons.public,
  'folder' => Icons.folder_outlined,
  'file' => Icons.description_outlined,
  'program' => Icons.terminal,
  _ => Icons.apps,
};

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: action, child: const Text('Try again')),
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
      body: AppsBrowser(connection: connection, onTap: (app) async => Navigator.of(context).pop(app)),
    );
  }
}
