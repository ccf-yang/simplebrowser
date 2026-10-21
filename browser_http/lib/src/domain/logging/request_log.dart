import '../models/transport.dart';

/// Log severity. `debug` may contain fingerprint metadata and is only emitted
/// when explicitly enabled.
enum RequestLogLevel { debug, info, warn, error }

/// Phases emitted for every request.
enum RequestLogPhase {
  start,
  response,
  redirect,
  challengeDetected,
  challengeResolved,
  retry,
  error,
  cancelled,
}

/// Immutable, serializable request log record.
///
/// Headers stored here must already be redacted by [LogRedactor].
final class RequestLogEvent {
  const RequestLogEvent({
    required this.id,
    required this.phase,
    required this.timestamp,
    this.level = RequestLogLevel.info,
    this.method,
    this.uri,
    this.statusCode,
    this.elapsed,
    this.profileId,
    this.headers,
    this.errorCode,
    this.message,
    this.fingerprint,
  });

  /// Correlates every event belonging to one logical request.
  final String id;

  final RequestLogPhase phase;
  final DateTime timestamp;
  final RequestLogLevel level;
  final String? method;
  final Uri? uri;
  final int? statusCode;
  final Duration? elapsed;
  final String? profileId;
  final Map<String, String>? headers;
  final String? errorCode;
  final String? message;
  final FingerprintInfo? fingerprint;

  Map<String, Object?> toJson() => <String, Object?>{
        'ts': timestamp.toUtc().toIso8601String(),
        'id': id,
        'phase': phase.name,
        'level': level.name,
        if (method != null) 'method': method,
        if (uri != null) 'uri': uri.toString(),
        if (statusCode != null) 'status': statusCode,
        if (elapsed != null) 'elapsed_ms': elapsed!.inMilliseconds,
        if (profileId != null) 'profile': profileId,
        if (headers != null) 'headers': headers,
        if (errorCode != null) 'err_code': errorCode,
        if (message != null) 'message': message,
        if (fingerprint != null) 'fingerprint': fingerprint!.toJson(),
      };

  @override
  String toString() => toJson().toString();
}
