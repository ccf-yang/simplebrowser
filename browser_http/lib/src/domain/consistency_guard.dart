import 'errors.dart';
import 'models/session_snapshot.dart';

/// Rejects reuse of a session whose identity silently changed.
///
/// Reusing a clearance cookie across a different UA, client-hint set, profile
/// family or egress IP is worse than not reusing it at all: it looks like a
/// hijacked session and permanently lowers the risk score of the device.
final class ConsistencyGuard {
  const ConsistencyGuard();

  void verify({
    required SessionSnapshot expected,
    required SessionSnapshot actual,
  }) {
    if (expected.isExpired) {
      throw ConsistencyException(
        code: BrowserErrorCodes.consistencyExpired,
        message: 'Session snapshot expired at ${expected.expiresAt}.',
      );
    }
    if (expected.profileId != actual.profileId) {
      throw ConsistencyException(
        code: BrowserErrorCodes.consistencyProfileMismatch,
        message: 'Profile mismatch: '
            'expected ${expected.profileId}, got ${actual.profileId}.',
      );
    }
    if (expected.userAgent != actual.userAgent) {
      throw const ConsistencyException(
        code: BrowserErrorCodes.consistencyUserAgentMismatch,
        message: 'User agent mismatch; the clearance cookie would be rejected.',
      );
    }
    if (!_sameHints(expected.clientHints, actual.clientHints)) {
      throw const ConsistencyException(
        code: BrowserErrorCodes.consistencyClientHintsMismatch,
        message: 'Client hints mismatch; the clearance cookie would be rejected.',
      );
    }
    if (expected.egressIpHash != null &&
        actual.egressIpHash != null &&
        expected.egressIpHash != actual.egressIpHash) {
      throw const ConsistencyException(
        code: BrowserErrorCodes.consistencyEgressMismatch,
        message: 'Egress IP changed; clearance is no longer valid.',
      );
    }
  }

  bool _sameHints(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
