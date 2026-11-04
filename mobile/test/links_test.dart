// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/files/share_inbox.dart';
import 'package:pairdesk/files/native_files.dart';
import 'package:pairdesk/pairing/host.dart';
import 'package:pairdesk/pairing/pairing_link.dart';
import 'package:pairdesk/pairing/relay_route.dart';

void main() {
  const fp = 'q6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s';
  const query = 'v=2&n=Office%20PC&fp=$fp&t=TOKEN-0123456789ab&p=47800&a=192.168.1.5';
  final id = 'ab' * 16;

  test('a shared https link reads like the QR code', () {
    final qr = parsePairingLink('pairdesk://pair?$query');
    final shared = parsePairingLink('https://pairdesk.madhushan.me/p#$query');
    expect(shared.name, 'Office PC');
    expect(shared.token, qr.token);
    expect(shared.addresses, qr.addresses);
    expect(shared.help, isFalse);
  });

  test('relay and help', () {
    final info = parsePairingLink(
      'https://pairdesk.madhushan.me/p#$query&r=relay.example.org%3A443%2F$id&h=1',
    );
    expect(info.help, isTrue);
    expect(info.addresses, ['192.168.1.5', 'relay:relay.example.org:443/$id']);
    expect(isUsableHost(info.addresses.last), isTrue);
  });

  test('what a computer or a link may tell the phone to dial', () {
    for (final a in ['192.168.1.5', '100.101.102.103', 'pc.tail1234.ts.net', '203.0.113.9:8443']) {
      expect(isUsableHost(a), isTrue, reason: a);
    }
    // Narrow on purpose: a link can come from someone else.
    for (final a in [
      '',
      '127.0.0.1',
      'localhost',
      'bogus',
      'home.example.org',
      'evil.example.com',
      '::1',
      '2001:db8::1',
      'has space.ts.net',
      'home.example.org:0',
    ]) {
      expect(isUsableHost(a), isFalse, reason: a.isEmpty ? '(empty)' : a);
    }
  });

  test('what the owner may type in, which is wider', () {
    // A name of your own, for a router that forwards the port.
    for (final a in [
      'home.example.org',
      'home.example.org:47800',
      'my-pc.duckdns.org',
      '192.168.1.5',
      'pc.tail1234.ts.net',
    ]) {
      expect(isTypedHost(a), isTrue, reason: a);
    }
    for (final a in ['', 'bogus', 'localhost', 'pairdesk.localhost', '127.0.0.1', '-bad.example.org']) {
      expect(isTypedHost(a), isFalse, reason: a.isEmpty ? '(empty)' : a);
    }
  });

  test('an address can carry its own port, for a router that forwards another', () {
    expect(splitHostPort('home.example.org:47800'), (host: 'home.example.org', port: 47800));
    expect(splitHostPort('192.168.1.5'), (host: '192.168.1.5', port: null));
    // Not a port number: the whole thing stays the host.
    expect(splitHostPort('home.example.org:http'), (host: 'home.example.org:http', port: null));
    expect(isTailscaleAddress('pc.tail1234.ts.net:47800'), isTrue);
  });

  test('other https links are refused', () {
    expect(() => parsePairingLink('https://evil.example/p#$query'), throwsA(isA<PairingLinkException>()));
    expect(
      () => parsePairingLink('https://pairdesk.madhushan.me/other#$query'),
      throwsA(isA<PairingLinkException>()),
    );
  });

  test('relay routes', () {
    final r = RelayRoute.tryParse('relay:relay.example.org:443/$id')!;
    expect((r.host, r.port, r.id), ('relay.example.org', 443, id));
    expect(r.toString(), 'relay:relay.example.org:443/$id');
    expect(RelayRoute.tryParse('relay:host:443/short'), isNull);
    expect(RelayRoute.tryParse('relay:host:99999/$id'), isNull);
    expect(RelayRoute.tryParse('relay:bad host:443/$id'), isNull);
    expect(isUsableHost('relay:host:443/nothex'), isFalse);
  });

  test('a link opened or shared into the app waits to be used, apart from files', () async {
    var next = SharedItems(link: 'https://pairdesk.madhushan.me/p#$query');
    final inbox = ShareInbox(take: () async => next);
    await inbox.check();
    expect(inbox.link, startsWith('https://'));
    expect(inbox.pending, isNull);
    expect(inbox.takeLink(), isNotNull);
    expect(inbox.link, isNull);
    // Shared as text (e.g. from a chat app's share button) counts too.
    next = SharedItems(text: '  pairdesk://pair?$query ');
    await inbox.check();
    expect(inbox.link, 'pairdesk://pair?$query');
    expect(inbox.pending, isNull);
  });
}
