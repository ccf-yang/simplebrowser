/// Browser-faithful HTTP client for Flutter on iOS.
///
/// This is the only public entry point. Only `api/`, `domain/models/` and
/// `domain/errors.dart` are exported; adapters and FFI stay private.
library;

export 'src/api/browser_challenge_view.dart';
export 'src/api/browser_client.dart';
export 'src/api/browser_profile.dart';
export 'src/api/browser_session.dart';
export 'src/api/browser_view.dart';
export 'src/api/challenge_controller.dart';
export 'src/api/sse_client.dart';
export 'src/composition/browser_http.dart';
export 'src/domain/consistency_guard.dart';
export 'src/domain/errors.dart';
export 'src/domain/logging/file_log_sink.dart';
export 'src/domain/logging/log_redactor.dart';
export 'src/domain/logging/request_log.dart';
export 'src/domain/models/browser_cookie.dart';
export 'src/domain/models/captured_exchange.dart';
export 'src/domain/models/page_network_event.dart';
export 'src/domain/models/session_snapshot.dart';
export 'src/domain/models/transport.dart';
export 'src/domain/models/webview_link_press.dart';
export 'src/domain/models/webview_navigation_event.dart';
export 'src/ports/cookie_port.dart';
export 'src/ports/log_sink.dart';
export 'src/ports/transport_port.dart';
export 'src/ports/vault_port.dart';
export 'src/ports/webview_port.dart';
