// SPDX-License-Identifier: GPL-3.0-or-later
// A grid of one-tap buttons: shortcuts, text, apps and power actions.
// Long-press a button to change or remove it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../agent_connection.dart';
import '../../buttons/custom_button.dart';
import '../button_editor.dart';
import 'power_tab.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

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
    final choice = await showPdSheet<String>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PdTitle(b.label, subtitle: _subtitle(b.action), size: 22),
            const SizedBox(height: 14),
            PdCard(
              color: PdColors.of(ctx).s2,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Column(
                children: [
                  PdRow(
                    icon: Icons.edit_outlined,
                    title: 'Edit',
                    iconBackground: PdColors.of(ctx).s1,
                    onTap: () => Navigator.pop(ctx, 'edit'),
                  ),
                  const PdDivider(),
                  PdRow(
                    icon: Icons.arrow_upward_rounded,
                    title: 'Move to start',
                    iconBackground: PdColors.of(ctx).s1,
                    onTap: () => Navigator.pop(ctx, 'first'),
                  ),
                  const PdDivider(),
                  PdRow(
                    icon: Icons.delete_outline_rounded,
                    title: 'Remove',
                    iconBackground: PdColors.of(ctx).s1,
                    onTap: () => Navigator.pop(ctx, 'remove'),
                  ),
                ],
              ),
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

  IconData _icon(ButtonAction a) => switch (a) {
    ComboAction() => Icons.keyboard_command_key_rounded,
    TextAction() => Icons.text_fields_rounded,
    AppAction() => Icons.open_in_new_rounded,
    PowerButtonAction(:final action) => powerIcon(action),
  };

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    final buttons = _buttons;
    if (buttons == null) return Center(child: PdSpinner(color: c.ink, size: 28));
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
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('Hold a tile to edit or move it', style: TextStyle(fontSize: 14, color: c.sub)),
                ),
                TextButton(onPressed: _reset, child: const Text('Reset')),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              mainAxisExtent: 108,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
            ),
            itemCount: buttons.length,
            itemBuilder: (context, i) {
              final b = buttons[i];
              return FadeRise(
                delay: Duration(milliseconds: (40 * i).clamp(0, 400)),
                child: Pressable(
                  onTap: () => _press(b),
                  onLongPress: () => _menu(b),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: c.s1, borderRadius: BorderRadius.circular(24)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(color: c.s2, shape: BoxShape.circle),
                          child: Icon(_icon(b.action), size: 18, color: c.ink),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              b.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                            ),
                            Text(
                              _subtitle(b.action),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: c.sub),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: PrimaryButton(
              label: 'New shortcut',
              icon: Icons.add_rounded,
              onPressed: () => _edit(null),
            ),
          ),
        ),
      ],
    );
  }
}
