// SPDX-License-Identifier: GPL-3.0-or-later
// Wake-on-LAN from the phone: the "magic packet" a sleeping computer's network
// card waits for. Works when the phone is on the same network as the
// computer; from anywhere else another PairDesk computer on that network
// sends it (see AppModel.wake).

import 'dart:io';
import 'dart:typed_data';

final _macPattern = RegExp(r'^[0-9a-fA-F]{2}([:-][0-9a-fA-F]{2}){5}$');

/// "aa:bb:cc:dd:ee:ff" or with dashes; not all zeros or all ones.
bool isMacAddress(String s) {
  if (!_macPattern.hasMatch(s)) return false;
  final bytes = macBytes(s);
  return bytes != null && !bytes.every((b) => b == 0) && !bytes.every((b) => b == 255);
}

Uint8List? macBytes(String s) {
  if (!_macPattern.hasMatch(s)) return null;
  return Uint8List.fromList([for (final p in s.split(RegExp(r'[:-]'))) int.parse(p, radix: 16)]);
}

/// Six 0xFF bytes, then the address sixteen times.
Uint8List magicPacket(String mac) {
  final m = macBytes(mac);
  if (m == null) throw ArgumentError('not a network address: $mac');
  final p = Uint8List(102)..fillRange(0, 6, 255);
  for (var i = 0; i < 16; i++) {
    p.setRange(6 + i * 6, 12 + i * 6, m);
  }
  return p;
}

/// Where to send on the phone's networks: the global broadcast and the /24
/// broadcast of each IPv4 address the phone has, ports 9 and 7.
Future<List<InternetAddress>> broadcastTargets() async {
  final out = <String>{'255.255.255.255'};
  try {
    for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in nic.addresses) {
        if (a.isLoopback || a.isLinkLocal) continue;
        final o = a.rawAddress;
        out.add('${o[0]}.${o[1]}.${o[2]}.255');
      }
    }
  } catch (_) {}
  return [for (final a in out) InternetAddress(a)];
}

/// Sends the packet for each address on this network. Returns how many went out.
Future<int> wakeOnThisNetwork(List<String> macs, {List<InternetAddress>? targets}) async {
  final dests = targets ?? await broadcastTargets();
  RawDatagramSocket? sock;
  var sent = 0;
  try {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.broadcastEnabled = true;
    for (final mac in macs.take(4)) {
      if (!isMacAddress(mac)) continue;
      final packet = magicPacket(mac);
      for (final d in dests) {
        for (final port in targets == null ? const [9, 7] : const [9]) {
          if (sock.send(packet, d, port) > 0) sent++;
        }
      }
    }
  } catch (_) {
    // No network or no permission: report what went out.
  } finally {
    sock?.close();
  }
  return sent;
}
