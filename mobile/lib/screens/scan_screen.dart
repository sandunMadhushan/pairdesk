// SPDX-License-Identifier: GPL-3.0-or-later
// Scans the pairing QR code shown on the computer. Returns the link text.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with WidgetsBindingObserver {
  final _qrKey = GlobalKey(debugLabel: 'pairdesk-qr');
  QRViewController? _controller;
  StreamSubscription<Barcode>? _sub;
  bool _done = false;
  bool _warnedOtherCode = false;
  bool? _permission;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _controller?.resumeCamera();
  }

  void _onCreated(QRViewController controller) {
    _controller = controller;
    _sub = controller.scannedDataStream.listen((barcode) {
      final code = barcode.code;
      if (_done || code == null) return;
      if (code.startsWith('pairdesk://')) {
        _finish(code);
      } else if (!_warnedOtherCode && mounted) {
        _warnedOtherCode = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That\'s not a PairDesk code. Scan the code on your computer.')),
        );
      }
    });
  }

  void _finish(String link) {
    if (_done) return;
    _done = true;
    HapticFeedback.mediumImpact();
    _controller?.pauseCamera();
    Navigator.of(context).pop(link);
  }

  Future<void> _pasteLink() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final controller = TextEditingController(
      text: (clip?.text ?? '').startsWith('pairdesk://') ? clip!.text : '',
    );
    final link = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste pairing link'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'pairdesk://pair?…',
            helperText: 'Shown under the QR code when you run\npairdesk-agent --pair',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Pair'),
          ),
        ],
      ),
    );
    if (link != null && link.isNotEmpty) _finish(link);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final cutOut = (size.shortestSide * 0.7).clamp(200.0, 320.0);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan pairing code'),
        actions: [
          IconButton(
            tooltip: 'Paste link instead',
            icon: const Icon(Icons.content_paste),
            onPressed: _pasteLink,
          ),
        ],
      ),
      body: Stack(
        children: [
          QRView(
            key: _qrKey,
            onQRViewCreated: _onCreated,
            formatsAllowed: const [BarcodeFormat.qrcode],
            onPermissionSet: (_, granted) => setState(() => _permission = granted),
            overlay: QrScannerOverlayShape(
              borderColor: scheme.primary,
              borderRadius: 12,
              borderLength: 32,
              borderWidth: 8,
              cutOutSize: cutOut,
            ),
          ),
          if (_permission == false)
            Container(
              color: scheme.surface,
              padding: const EdgeInsets.all(24),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.no_photography_outlined, size: 48, color: scheme.onSurfaceVariant),
                  const SizedBox(height: 16),
                  const Text(
                    'PairDesk needs the camera to scan the code on your computer. '
                    'Allow camera access in Android settings, or paste the link instead.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _pasteLink,
                    icon: const Icon(Icons.content_paste),
                    label: const Text('Paste link'),
                  ),
                ],
              ),
            )
          else
            Positioned(
              left: 24,
              right: 24,
              bottom: 32,
              child: Text(
                'On your computer, open PairDesk and choose "Pair a phone".',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(color: Colors.white, shadows: const [Shadow(blurRadius: 6)]),
              ),
            ),
        ],
      ),
    );
  }
}
