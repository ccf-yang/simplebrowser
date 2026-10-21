/// Stable error codes shared by Dart, Rust and Swift.
abstract final class BrowserErrorCodes {
  static const String transportDns = 'transport.dns';
  static const String transportConnect = 'transport.connect';
  static const String transportTls = 'transport.tls';
  static const String transportTimeout = 'transport.timeout';
  static const String transportProxy = 'transport.proxy';
  static const String transportProtocol = 'transport.protocol';

  static const String fingerprintUnsupportedProfile =
      'fingerprint.unsupported_profile';
  static const String fingerprintMismatch = 'fingerprint.mismatch';

  static const String challengeRequired = 'challenge.required';
  static const String challengeTimeout = 'challenge.timeout';
  static const String challengeRejected = 'challenge.rejected';

  static const String consistencyProfileMismatch =
      'consistency.profile_mismatch';
  static const String consistencyUserAgentMismatch =
      'consistency.user_agent_mismatch';
  static const String consistencyClientHintsMismatch =
      'consistency.client_hints_mismatch';
  static const String consistencyEgressMismatch = 'consistency.egress_mismatch';
  static const String consistencyExpired = 'consistency.expired';

  static const String vaultRead = 'vault.read';
  static const String vaultWrite = 'vault.write';
  static const String vaultCorrupt = 'vault.corrupt';

  static const String webViewUnavailable = 'webview.unavailable';
  static const String webViewLoad = 'webview.load';
  static const String webViewScript = 'webview.script';

  static const String cancelled = 'cancelled';
  static const String invalidArgument = 'invalid_argument';
  static const String unimplemented = 'unimplemented';
}

/// Base type for every error surfaced by this package.
sealed class BrowserHttpException implements Exception {
  const BrowserHttpException({
    required this.code,
    required this.message,
    this.cause,
    this.stackTrace,
  });

  /// Stable, machine-readable code. See [BrowserErrorCodes].
  final String code;

  /// Human-readable message. Never contains secrets.
  final String message;

  /// Original error, if any.
  final Object? cause;

  /// Original stack trace, if any.
  final StackTrace? stackTrace;

  @override
  String toString() => 'BrowserHttpException($code): $message';
}

/// Network-level failure.
final class TransportException extends BrowserHttpException {
  const TransportException({
    required super.code,
    required super.message,
    super.cause,
    super.stackTrace,
  });
}

/// The requested fingerprint profile does not exist or cannot be emulated.
final class FingerprintException extends BrowserHttpException {
  const FingerprintException({
    required super.code,
    required super.message,
    super.cause,
    super.stackTrace,
  });
}

/// The target answered with a challenge that has not been resolved yet.
final class ChallengeRequiredException extends BrowserHttpException {
  const ChallengeRequiredException({
    required super.message,
    super.cause,
    super.stackTrace,
  }) : super(code: BrowserErrorCodes.challengeRequired);
}

/// The session identity is internally inconsistent. Never retry blindly.
final class ConsistencyException extends BrowserHttpException {
  const ConsistencyException({
    required super.code,
    required super.message,
    super.cause,
    super.stackTrace,
  });
}

/// Persisting or restoring a [SessionSnapshot] failed.
final class VaultException extends BrowserHttpException {
  const VaultException({
    required super.code,
    required super.message,
    super.cause,
    super.stackTrace,
  });
}

/// WKWebView failed to load, execute a script, or export state.
final class WebViewException extends BrowserHttpException {
  const WebViewException({
    required super.code,
    required super.message,
    super.cause,
    super.stackTrace,
  });
}

/// The request was cancelled by the caller.
final class CancelledException extends BrowserHttpException {
  const CancelledException()
      : super(code: BrowserErrorCodes.cancelled, message: 'Request cancelled.');
}

/// Invalid arguments supplied by the caller.
final class InvalidArgumentException extends BrowserHttpException {
  const InvalidArgumentException(String message)
      : super(code: BrowserErrorCodes.invalidArgument, message: message);
}

/// A feature that is not available on this platform or build.
final class UnimplementedException extends BrowserHttpException {
  const UnimplementedException(String message)
      : super(code: BrowserErrorCodes.unimplemented, message: message);
}
