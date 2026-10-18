import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CredentialStore {
  final FlutterSecureStorage _storage = Platform.isMacOS
      ? const FlutterSecureStorage(
          mOptions: MacOsOptions(usesDataProtectionKeychain: false),
        )
      : const FlutterSecureStorage();

  Future<String?> read(String profileId) =>
      _storage.read(key: 'remina.password.$profileId');
  Future<void> write(String profileId, String password) =>
      _storage.write(key: 'remina.password.$profileId', value: password);
  Future<void> delete(String profileId) =>
      _storage.delete(key: 'remina.password.$profileId');
}
