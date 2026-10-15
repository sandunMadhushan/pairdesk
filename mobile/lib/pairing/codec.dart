// SPDX-License-Identifier: GPL-3.0-or-later
// Base64url (no padding) and hex helpers matching the agent.

import 'dart:convert';
import 'dart:typed_data';

String b64Encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List? b64Decode(String text) {
  var s = text.trim().replaceAll('=', '');
  if (s.isEmpty) return null;
  s = s.padRight((s.length + 3) ~/ 4 * 4, '=');
  try {
    return base64Url.decode(s);
  } on FormatException {
    return null;
  }
}

String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Compares two byte lists without stopping at the first difference.
bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
