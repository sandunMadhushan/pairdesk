// SPDX-License-Identifier: GPL-3.0-or-later
// "Clipboard and files": copy and paste between phone and computer, send
// files, and see transfers in both directions.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent_connection.dart';
import '../files/native_files.dart';
import '../files/transfers.dart';

/// Shows a message on the control screen's scaffold.
typedef Say = void Function(String text, {SnackBarAction? action});

String formatSize(int n) {
  if (n < 1024) return '$n B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = n / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
}

/// Clipboard actions, shared by the sheet and "Share → PairDesk".
class Exchange {
  Exchange(this.conn, this.say, {this.nativeFiles});
  final AgentConnection conn;
  final Say say;

  /// Default: the Android side.
  final NativeFiles? nativeFiles;
  NativeFiles get files => nativeFiles ?? NativeFiles.instance;

  String _preview(String t) {
    final one = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 40 ? '${one.substring(0, 40)}…' : one;
  }

  Future<void> copyFromComputer() async {
    try {
      final text = await conn.clipboardGet();
      if (text.isEmpty) {
        say('The computer\'s clipboard has no text.');
        return;
      }
      await Clipboard.setData(ClipboardData(text: text));
      say('Copied from the computer: "${_preview(text)}"');
    } on RequestException catch (e) {
      say(e.message);
    }
  }

  Future<void> sendText(String text, {bool paste = false}) async {
    if (text.isEmpty) {
      say('Nothing to send: the phone\'s clipboard is empty.');
      return;
    }
    try {
      await conn.clipboardSet(text, paste: paste);
      say(paste ? 'Pasted on the computer.' : 'On the computer\'s clipboard. Paste it there with Ctrl+V.');
    } on RequestException catch (e) {
      say(e.message);
    }
  }

  Future<void> sendPhoneClipboard({bool paste = false}) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    await sendText(data?.text ?? '', paste: paste);
  }

  /// Sends files (copies in the cache, deleted afterwards).
  Future<void> sendFiles(List<PickedFile> picked) async {
    if (picked.isEmpty) return;
    var ok = 0;
    String? lastError;
    for (final p in picked) {
      final f = File(p.path);
      try {
        await conn.sendFile(f, name: p.name);
        ok++;
      } on RequestException catch (e) {
        lastError = '${p.name}: ${e.message}';
      } finally {
        try {
          await f.parent.delete(recursive: true);
        } catch (_) {}
      }
    }
    final where = conn.agentOs == 'windows' ? 'Downloads\\PairDesk' : 'Downloads/PairDesk';
    if (lastError != null) {
      say(ok == 0 ? lastError : '$ok of ${picked.length} files sent. $lastError');
    } else {
      say(ok == 1 ? 'Sent. It\'s in $where on the computer.' : '$ok files sent to $where on the computer.');
    }
  }

  Future<void> pickAndSend() async {
    try {
      await sendFiles(await files.pickFiles());
    } catch (e) {
      say('Couldn\'t open the file picker: $e');
    }
  }

  Future<void> open(Transfer t) async {
    final uri = t.openUri;
    if (uri == null || !await files.open(uri, t.name)) {
      say('No app on this phone opens that file. It\'s in ${t.savedWhere ?? 'Download/PairDesk'}.');
    }
  }
}

class ExchangeSheet extends StatelessWidget {
  const ExchangeSheet({super.key, required this.exchange});
  final Exchange exchange;

  AgentConnection get conn => exchange.conn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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

    void run(Future<void> Function() action) {
      Navigator.of(context).pop();
      action();
    }

    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );

    return SafeArea(
      child: ListenableBuilder(
        listenable: conn.transfers,
        builder: (context, _) {
          final items = conn.transfers.items;
          return ListView(
            shrinkWrap: true,
            children: [
              header('Clipboard'),
              if (clipWhy != null)
                ListTile(leading: const Icon(Icons.block), title: Text(clipWhy))
              else ...[
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('Copy from computer'),
                  subtitle: const Text('The computer\'s clipboard text, onto this phone'),
                  onTap: () => run(exchange.copyFromComputer),
                ),
                ListTile(
                  leading: const Icon(Icons.upload_outlined),
                  title: const Text('Send to computer'),
                  subtitle: const Text('This phone\'s clipboard, onto the computer\'s'),
                  onTap: () => run(exchange.sendPhoneClipboard),
                ),
                ListTile(
                  leading: const Icon(Icons.content_paste_go),
                  title: const Text('Paste on computer'),
                  subtitle: const Text('Send it and paste it where the computer\'s cursor is'),
                  onTap: () => run(() => exchange.sendPhoneClipboard(paste: true)),
                ),
              ],
              header('Files'),
              if (filesWhy != null)
                ListTile(leading: const Icon(Icons.block), title: Text(filesWhy))
              else
                ListTile(
                  leading: const Icon(Icons.upload_file),
                  title: const Text('Send files to computer'),
                  subtitle: Text(
                    'Saved in ${conn.agentOs == 'windows' ? 'Downloads\\PairDesk' : 'Downloads/PairDesk'} there',
                  ),
                  onTap: () => run(exchange.pickAndSend),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  conn.agentOs == 'windows'
                      ? 'To send files to this phone, drop them on PairDesk\'s page on the computer, '
                            'or right-click a file → Send to → PairDesk phone.'
                      : 'To send files to this phone, drop them on PairDesk\'s page on the computer, '
                            'or use "Send to phone (PairDesk)" in the file manager\'s menu.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (items.isNotEmpty) header('Transfers'),
              for (final t in items) _TransferTile(transfer: t, exchange: exchange),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({required this.transfer, required this.exchange});
  final Transfer transfer;
  final Exchange exchange;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final theme = Theme.of(context);
    final status = switch (t.state) {
      TransferState.waiting => 'Waiting…',
      TransferState.active => '${formatSize(t.done)} of ${formatSize(t.size)}',
      TransferState.done =>
        t.incoming ? 'Saved in ${t.savedWhere ?? 'Download/PairDesk'}' : 'Sent · ${formatSize(t.size)}',
      TransferState.failed => t.message ?? 'Failed',
    };
    return ListTile(
      leading: Icon(t.incoming ? Icons.south : Icons.north),
      title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            status,
            style: t.state == TransferState.failed ? TextStyle(color: theme.colorScheme.error) : null,
          ),
          if (!t.finished)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(value: t.fraction),
            ),
        ],
      ),
      trailing: !t.finished
          ? IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.close),
              onPressed: () => exchange.conn.transfers.cancel(t.fid),
            )
          : t.incoming && t.state == TransferState.done
          ? TextButton(onPressed: () => exchange.open(t), child: const Text('Open'))
          : null,
    );
  }
}
