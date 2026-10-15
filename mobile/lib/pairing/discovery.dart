// SPDX-License-Identifier: GPL-3.0-or-later
// Finding a paired computer on the local network after its address
// changed. Computers announce `_pairdesk._tcp` with `id=<short id>`.
// A found address is only a hint: the connection still checks the
// pinned certificate.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nsd/nsd.dart' as nsd;

abstract class LaptopFinder {
  /// IPv4 addresses announced by the computer with [shortId].
  Future<List<String>> find(String shortId, {Duration timeout});
}

class NsdLaptopFinder implements LaptopFinder {
  static const serviceType = '_pairdesk._tcp';

  @override
  Future<List<String>> find(String shortId, {Duration timeout = const Duration(seconds: 5)}) async {
    final found = Completer<List<String>>();
    nsd.Discovery? discovery;
    try {
      discovery = await nsd.startDiscovery(serviceType, ipLookupType: nsd.IpLookupType.v4);
      void check(nsd.Service s, nsd.ServiceStatus status) {
        if (status != nsd.ServiceStatus.found || found.isCompleted) return;
        final id = s.txt?['id'];
        if (id == null || utf8.decode(id, allowMalformed: true) != shortId) return;
        final addrs = [
          for (final a in s.addresses ?? const <InternetAddress>[])
            if (a.type == InternetAddressType.IPv4) a.address,
        ];
        if (addrs.isNotEmpty) found.complete(addrs);
      }

      discovery.addServiceListener(check);
      for (final s in discovery.services) {
        check(s, nsd.ServiceStatus.found);
      }
      return await found.future.timeout(timeout, onTimeout: () => const []);
    } catch (_) {
      return const [];
    } finally {
      if (discovery != null) {
        unawaited(nsd.stopDiscovery(discovery).catchError((_) {}));
      }
    }
  }
}
