// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agent_connection.dart';
import 'control_screen.dart';

const _prefHost = 'last_host';
const _prefPort = 'last_port';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.connection});

  final AgentConnection connection;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '$defaultAgentPort');
  final _formKey = GlobalKey<FormState>();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadLast();
  }

  Future<void> _loadLast() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _host.text = prefs.getString(_prefHost) ?? '';
      _port.text = '${prefs.getInt(_prefPort) ?? defaultAgentPort}';
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  /// Accepts "192.168.1.5" or "192.168.1.5:47800" in the address field.
  (String, int) _target() {
    var host = _host.text.trim();
    var port = int.tryParse(_port.text.trim()) ?? defaultAgentPort;
    final colon = host.lastIndexOf(':');
    if (colon > 0 && !host.contains(']')) {
      final p = int.tryParse(host.substring(colon + 1));
      if (p != null) {
        port = p;
        host = host.substring(0, colon);
        _port.text = '$port';
        _host.text = host;
      }
    }
    return (host, port);
  }

  Future<void> _connect() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final (host, port) = _target();
    setState(() => _busy = true);
    try {
      await widget.connection.connect(host, port);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefHost, host);
      await prefs.setInt(_prefPort, port);
      if (!mounted) return;
      await Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => ControlScreen(connection: widget.connection)));
      // Back from the control screen: explain why, if it was a drop.
      final err = widget.connection.lastError;
      if (mounted && err != null) _toast(err);
    } catch (e) {
      if (mounted) _toast(widget.connection.lastError ?? '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.desktop_windows_outlined, size: 56, color: theme.colorScheme.primary),
                    const SizedBox(height: 16),
                    Text('PairDesk', textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
                    const SizedBox(height: 8),
                    Text(
                      'Start the PairDesk agent on your laptop, then enter the address it shows.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 32),
                    TextFormField(
                      controller: _host,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Laptop address',
                        hintText: '192.168.1.5',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Enter the address shown by the agent' : null,
                      onFieldSubmitted: (_) => _connect(),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _port,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Port', border: OutlineInputBorder()),
                      validator: (v) {
                        final p = int.tryParse(v?.trim() ?? '');
                        return (p == null || p < 1 || p > 65535) ? 'Port must be 1–65535' : null;
                      },
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _busy ? null : _connect,
                      icon: _busy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.link),
                      label: Text(_busy ? 'Connecting…' : 'Connect'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Phase 0 preview: no pairing yet. Use only on your own Wi-Fi.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
