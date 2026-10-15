// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/pairing/codec.dart';
import 'package:pairdesk/pairing/identity.dart';
import 'package:pairdesk/pairing/laptop.dart';
import 'package:pairdesk/pairing/pairing_link.dart';

List<int> fromHex(String h) => [
  for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16),
];

void main() {
  final fp = b64Encode(List.filled(32, 0xAB));
  String link({String v = '2', String fpv = '', String t = 'abcdefghijklmnopqrstuv', String p = '47800'}) =>
      'pairdesk://pair?v=$v&n=Sandun%27s%20laptop&fp=${fpv.isEmpty ? fp : fpv}&t=$t&p=$p&a=192.168.1.5,bogus,10.0.0.2';

  group('pairing link', () {
    test('parses what the agent produces', () {
      final info = parsePairingLink(link());
      expect(info.name, "Sandun's laptop");
      expect(info.fingerprint, List.filled(32, 0xAB));
      expect(info.token, 'abcdefghijklmnopqrstuv');
      expect(info.port, 47800);
      expect(info.addresses, ['192.168.1.5', '10.0.0.2']);
    });

    test('rejects other codes, damaged codes and version mismatches', () {
      Matcher fails(String text) =>
          throwsA(isA<PairingLinkException>().having((e) => e.message, 'message', contains(text)));
      expect(() => parsePairingLink('https://example.com'), fails('isn\'t a PairDesk code'));
      expect(() => parsePairingLink('hello'), fails('isn\'t a PairDesk code'));
      expect(() => parsePairingLink(link(fpv: 'short')), fails('damaged'));
      expect(() => parsePairingLink(link(t: 'x')), fails('damaged'));
      expect(() => parsePairingLink(link(p: '99999')), fails('damaged'));
      expect(() => parsePairingLink(link(v: '3')), fails('Update this app'));
      expect(() => parsePairingLink(link(v: '1')), fails('older PairDesk'));
    });
  });

  group('identity', () {
    test('matches the RFC 8032 Ed25519 test vector', () async {
      // RFC 8032 section 7.1, TEST 1 (empty message).
      final id = await PhoneIdentity.fromSeed(
        fromHex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'),
      );
      expect(hex(id.publicKey), 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a');
      final sig = await id.signRaw(const []);
      expect(
        hex(sig),
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      );
    });

    test('is created once and then reloaded', () async {
      final vault = MemoryKeyVault();
      final a = await PhoneIdentity.loadOrCreate(vault);
      final b = await PhoneIdentity.loadOrCreate(vault);
      expect(a.id, b.id);
      expect(a.publicKey.length, 32);
    });

    test('signs the agent\'s auth message layout', () async {
      final id = await PhoneIdentity.fromSeed(List.filled(32, 1));
      final msg = id.authMessage(List.filled(32, 2), List.filled(32, 3));
      expect(msg.length, 'pairdesk-auth-v2'.length + 1 + 96);
      expect(msg.sublist(16, 17), [0]);
      expect(msg.sublist(msg.length - 32), id.publicKey);
    });
  });

  test('laptop survives a save round trip and remembers addresses', () {
    final l = Laptop(
      fingerprint: Uint8List.fromList(List.filled(32, 9)),
      name: 'pc',
      port: 47800,
      addresses: ['10.0.0.1'],
      os: 'linux',
    );
    l.rememberAddress('10.0.0.7');
    l.rememberAddress('10.0.0.1');
    final copy = Laptop.fromJson(l.toJson())!;
    expect(copy.addresses, ['10.0.0.1', '10.0.0.7']);
    expect(copy.fingerprint, l.fingerprint);
    expect(copy.shortId, '0909090909090909');
    expect(copy.os, 'linux');
    expect(Laptop.fromJson({'fp': 'bad', 'port': 1}), isNull);
  });
}
