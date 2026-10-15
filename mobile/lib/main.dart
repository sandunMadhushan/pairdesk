// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import 'agent_connection.dart';
import 'screens/connect_screen.dart';

void main() {
  runApp(const PairDeskApp());
}

class PairDeskApp extends StatefulWidget {
  const PairDeskApp({super.key});

  @override
  State<PairDeskApp> createState() => _PairDeskAppState();
}

class _PairDeskAppState extends State<PairDeskApp> {
  final AgentConnection _connection = AgentConnection();

  @override
  void dispose() {
    _connection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2F6FED);
    return MaterialApp(
      title: 'PairDesk',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed)),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
      ),
      home: ConnectScreen(connection: _connection),
    );
  }
}
