// SPDX-License-Identifier: GPL-3.0-or-later
// Files: send files to the computer, move clipboard text both ways, and
// follow transfers in both directions.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../agent_connection.dart';
import '../../files/transfers.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../exchange_sheet.dart';

class FilesTab extends StatelessWidget {
  const FilesTab({super.key, required this.exchange});
  final Exchange exchange;

  AgentConnection get conn => exchange.conn;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    final clipOk = conn.features.contains('clipboard');
    final filesOk = conn.features.contains('files');
    final clipWhy = !clipOk
        ? conn.outdatedComputerMessage()
        : !conn.allowed.clipboard
        ? 'Turned off in PairDesk settings on the computer.'
        : null;
    final filesWhy = !filesOk
        ? conn.outdatedComputerMessage()
        : !conn.allowed.files
        ? 'Turned off in PairDesk settings on the computer.'
        : null;
    final where = conn.agentOs == 'windows' ? 'Downloads\\PairDesk' : 'Downloads/PairDesk';

    Widget note(String text) => PdRow(icon: Icons.block_rounded, title: text);

    return ListenableBuilder(
      listenable: conn.transfers,
      builder: (context, _) {
        final items = conn.transfers.items;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            if (filesWhy != null)
              PdCard(child: note(filesWhy))
            else
              _SendFiles(where: where, onTap: exchange.pickAndSend),
            const SizedBox(height: 12),
            PdCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 2),
                    child: Text('Clipboard', style: TextStyle(fontSize: 14, color: c.sub)),
                  ),
                  if (clipWhy != null)
                    note(clipWhy)
                  else ...[
                    PdRow(
                      icon: Icons.download_rounded,
                      title: 'Copy from computer',
                      subtitle: 'Its copied text, onto this phone',
                      onTap: exchange.copyFromComputer,
                    ),
                    const PdDivider(),
                    PdRow(
                      icon: Icons.upload_rounded,
                      title: 'Send to computer',
                      subtitle: 'This phone\'s copied text, onto the computer\'s clipboard',
                      onTap: exchange.sendPhoneClipboard,
                    ),
                    const PdDivider(),
                    PdRow(
                      icon: Icons.content_paste_go_rounded,
                      title: 'Paste on computer',
                      subtitle: 'Send it and paste it where the computer\'s cursor is',
                      onTap: () => exchange.sendPhoneClipboard(paste: true),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            PdCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 2),
                    child: Text('Transfers', style: TextStyle(fontSize: 14, color: c.sub)),
                  ),
                  if (items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        conn.agentOs == 'windows'
                            ? 'To send files to this phone, drop them on PairDesk\'s page on the computer, '
                                  'or right-click a file → Send to → PairDesk phone.'
                            : 'To send files to this phone, drop them on PairDesk\'s page on the computer, '
                                  'or use "Send to phone (PairDesk)" in the file manager\'s menu.',
                        style: TextStyle(fontSize: 14, color: c.sub, height: 1.4),
                      ),
                    ),
                  for (final (i, t) in items.indexed) ...[
                    if (i > 0) const PdDivider(),
                    _TransferRow(transfer: t, exchange: exchange),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SendFiles extends StatelessWidget {
  const _SendFiles({required this.where, required this.onTap});
  final String where;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return Semantics(
      button: true,
      label: 'Send files to computer',
      excludeSemantics: true,
      child: Pressable(
        scale: 0.97,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: c.accent,
            borderRadius: BorderRadius.circular(30),
            boxShadow: c.glow,
          ),
          child: Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: const BoxDecoration(color: PdColors.onAccent, shape: BoxShape.circle),
                child: const Icon(Icons.upload_file_rounded, color: PdColors.lime),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Send files to computer',
                      style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: PdColors.onAccent),
                    ),
                    Text(
                      'Saved in $where there',
                      style: const TextStyle(fontSize: 14, color: Color(0xFF2E3320)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({required this.transfer, required this.exchange});
  final Transfer transfer;
  final Exchange exchange;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    final t = transfer;
    final status = switch (t.state) {
      TransferState.waiting => 'Waiting…',
      TransferState.active => '${formatSize(t.done)} of ${formatSize(t.size)}',
      TransferState.done =>
        t.incoming ? 'Saved in ${t.savedWhere ?? 'Download/PairDesk'}' : 'Sent · ${formatSize(t.size)}',
      TransferState.failed => t.message ?? 'Failed',
    };
    final failed = t.state == TransferState.failed;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: t.finished
                ? Container(
                    decoration: BoxDecoration(color: c.s2, shape: BoxShape.circle),
                    child: Icon(
                      failed
                          ? Icons.error_outline_rounded
                          : t.incoming
                          ? Icons.check_rounded
                          : Icons.done_all_rounded,
                      size: 20,
                      color: failed ? Theme.of(context).colorScheme.error : c.ink,
                    ),
                  )
                : TweenAnimationBuilder<double>(
                    tween: Tween(end: t.fraction),
                    duration: PdMotion.fade,
                    builder: (_, v, _) => CustomPaint(
                      painter: _Ring(v, c.ink, c.s2),
                      child: Icon(
                        t.incoming ? Icons.south_rounded : Icons.north_rounded,
                        size: 16,
                        color: c.ink,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                Text(
                  status,
                  style: TextStyle(fontSize: 13, color: failed ? Theme.of(context).colorScheme.error : c.sub),
                ),
              ],
            ),
          ),
          if (!t.finished)
            RoundButton(
              icon: Icons.close_rounded,
              tooltip: 'Cancel',
              onPressed: () => exchange.conn.transfers.cancel(t.fid),
              background: c.s2,
              size: 38,
              iconSize: 18,
            )
          else if (t.incoming && t.state == TransferState.done)
            SecondaryButton(label: 'Open', height: 38, onPressed: () => exchange.open(t)),
        ],
      ),
    );
  }
}

class _Ring extends CustomPainter {
  _Ring(this.value, this.color, this.track);
  final double value;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(2, 2, size.width - 4, size.height - 4);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(r, 0, math.pi * 2, false, p..color = track);
    canvas.drawArc(r, -math.pi / 2, math.pi * 2 * value.clamp(0, 1), false, p..color = color);
  }

  @override
  bool shouldRepaint(_Ring old) => old.value != value || old.color != color;
}
