// SPDX-License-Identifier: GPL-3.0-or-later
// This phone's identity: an Ed25519 key pair created on first launch.
// The private key never leaves the phone; it's kept in Android's
// encrypted storage (backed by the Android Keystore).

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'codec.dart';

/// Somewhere to keep the private key.
abstract class KeyVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SecureKeyVault implements KeyVault {
  static const _storage = FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
}

/// For tests.
class MemoryKeyVault implements KeyVault {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class PhoneIdentity {
  PhoneIdentity._(this._keyPair, this.publicKey);

  static const _vaultKey = 'pairdesk.identity.ed25519.seed.v1';
  static final _algorithm = Ed25519();
  static const _context = 'pairdesk-auth-v2';

  final SimpleKeyPair _keyPair;
  final Uint8List publicKey;

  /// The ID the computer stores for this phone.
  String get id => b64Encode(publicKey);

  static Future<PhoneIdentity> loadOrCreate(KeyVault vault) async {
    var seed = b64Decode(await vault.read(_vaultKey) ?? '');
    if (seed == null || seed.length != 32) {
      final rng = Random.secure();
      seed = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
      await vault.write(_vaultKey, b64Encode(seed));
    }
    return fromSeed(seed);
  }

  static Future<PhoneIdentity> fromSeed(List<int> seed) async {
    final keyPair = await _algorithm.newKeyPairFromSeed(seed);
    final pub = await keyPair.extractPublicKey();
    return PhoneIdentity._(keyPair, Uint8List.fromList(pub.bytes));
  }

  /// Bytes signed to answer the computer's challenge (docs/PROTOCOL.md).
  Uint8List authMessage(List<int> fingerprint, List<int> nonce) =>
      Uint8List.fromList([...utf8.encode(_context), 0, ...fingerprint, ...nonce, ...publicKey]);

  /// Signs the challenge; returns base64url.
  Future<String> signChallenge(List<int> fingerprint, List<int> nonce) async {
    final sig = await _algorithm.sign(authMessage(fingerprint, nonce), keyPair: _keyPair);
    return b64Encode(sig.bytes);
  }

  Future<List<int>> signRaw(List<int> message) async =>
      (await _algorithm.sign(message, keyPair: _keyPair)).bytes;
}
