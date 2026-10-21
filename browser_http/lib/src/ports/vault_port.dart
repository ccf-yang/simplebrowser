import '../domain/models/session_snapshot.dart';

/// Encrypted-at-rest storage for [SessionSnapshot]s.
///
/// The iOS implementation uses the Keychain with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
abstract interface class VaultPort {
  Future<SessionSnapshot?> read(String key);

  Future<void> write(String key, SessionSnapshot snapshot);

  Future<void> delete(String key);
}
