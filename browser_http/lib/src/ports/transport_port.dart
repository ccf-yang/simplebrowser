import '../domain/models/transport.dart';

/// Cancellation handle passed down to the native layer.
///
/// Native implementations must abort the underlying socket when [cancel] is
/// called and surface a `cancelled` error.
final class CancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  /// Registers a callback fired on cancellation. If already cancelled, it is
  /// invoked immediately.
  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }
}

/// The only way the domain layer performs network I/O.
///
/// The production adapter is Rust (wreq/BoringSSL). Tests use an in-memory
/// fake, which is why this interface exists.
abstract interface class TransportPort {
  /// Sends a request and buffers the whole body.
  Future<TransportResponse> send(
    TransportRequest request, {
    CancelToken? cancelToken,
  });

  /// Sends a request and returns the body as it arrives.
  ///
  /// Completes once the response headers are available; the body stream then
  /// yields chunks until the server closes the connection.
  Future<TransportStream> openStream(
    TransportRequest request, {
    CancelToken? cancelToken,
  });

  /// Returns the UA/client-hint identity of a native profile. Used to keep the
  /// native transport and WKWebView consistent.
  Future<ProfileInfo> profileInfo(String profileId);

  /// Lists the profiles compiled into the native core.
  Future<List<ProfileDescriptor>> listProfiles();

  Future<void> close();
}
