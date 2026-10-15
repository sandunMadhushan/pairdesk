// SPDX-License-Identifier: GPL-3.0-or-later
// A grid of one-tap buttons: shortcuts, text, apps and power actions.
// Long-press a button to change or remove it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../agent_connection.dart';
import '../../buttons/custom_button.dart';
import '../button_editor.dart';
import 'power_tab.dart';

class ButtonsTab extends StatefulWidget {
  const ButtonsTab({super.key, required this.connection, this.store});

  final AgentConnection connection;
  final ButtonStore? store;

  @override
  State<ButtonsTab> createState() => _ButtonsTabState();
}

class _ButtonsTabState extends State<ButtonsTab> {
  late final ButtonStore _store = widget.store ?? ButtonStore();
  List<CustomButton>? _buttons;

  String? get _os => widget.connection.agentOs;

  @override
  void initState() {
    super.initState();
    _store.load().then((saved) {
      if (mounted) setState(() => _buttons = saved ?? defaultButtons(os: _os));
    });
  }

  Future<void> _save(List<CustomButton> buttons) async {
    setState(() => _buttons = buttons);
    await _store.save(buttons);
  }

  Future<void> _press(CustomButton b) async {
    HapticFeedback.lightImpact();
    final messenger = ScaffoldMessenger.of(context);
    final action = b.action;
    if (action is PowerButtonAction) {
      await doPower(context, widget.connection, action.action);
      return;
    }
    try {
      await runButton(widget.connection, action);
      if (action is AppAction) {
        messenger.showSnackBar(
          SnackBar(content: Text('Opening ${action.appName}'), duration: const Duration(seconds: 2)),
        );
      }
    } on RequestException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _edit(CustomButton? existing) async {
    final result = await Navigator.of(context).push<CustomButton>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ButtonEditor(connection: widget.connection, initial: existing),
      ),
    );
    if (result == null) return;
    final list = [..._buttons!];
    final i = list.indexWhere((b) => b.id == result.id);
    if (i >= 0) {
      list[i] = result;
    } else {
      list.add(result);
    }
    await _save(list);
  }

  Future<void> _menu(CustomButton b) async {
    HapticFeedback.mediumImpact();
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(b.label, style: Theme.of(ctx).textTheme.titleMedium)),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_upward),
              title: const Text('Move to start'),
              onTap: () => Navigator.pop(ctx, 'first'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove'),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
          ],
        ),
      ),
    );
    final list = [..._buttons!];
    switch (choice) {
      case 'edit':
        await _edit(b);
      case 'first':
        list.removeWhere((x) => x.id == b.id);
        await _save([b, ...list]);
      case 'remove':
        await _save(list.where((x) => x.id != b.id).toList());
    }
  }

  Future<void> _reset() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset buttons?'),
        content: const Text('Your own buttons will be removed and the default set restored.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (yes != true) return;
    await _store.reset();
    setState(() => _buttons = defaultButtons(os: _os));
  }

  String _subtitle(ButtonAction a) => switch (a) {
    ComboAction() => a.describe(os: _os),
    TextAction(:final text) => 'Types "${text.length > 18 ? '${text.substring(0, 18)}…' : text}"',
    AppAction(:final appName) => 'Opens $appName',
    PowerButtonAction(:final action) => powerLabel(action),
  };

  @override
  Widget build(BuildContext context) {
    final buttons = _buttons;
    if (buttons == null) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);
    if (!widget.connection.features.contains('combo')) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(widget.connection.outdatedComputerMessage(), textAlign: TextAlign.center),
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
            child: Row(
              children: [
                Expanded(child: Text('Long-press a button to change it.', style: theme.textTheme.bodySmall)),
                TextButton(onPressed: _reset, child: const Text('Reset')),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisExtent: 76,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
            ),
            itemCount: buttons.length + 1,
            itemBuilder: (context, i) {
              if (i == buttons.length) {
                return OutlinedButton.icon(
                  onPressed: () => _edit(null),
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                );
              }
              final b = buttons[i];
              return Material(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _press(b),
                  onLongPress: () => _menu(b),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          b.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _subtitle(b.action),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
