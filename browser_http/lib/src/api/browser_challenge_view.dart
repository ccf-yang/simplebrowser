import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ports/webview_port.dart';
import 'browser_session.dart';
import 'challenge_controller.dart';

/// Visible surface for interactive challenges.
///
/// The user must complete the widget's verification themselves; this package
/// never synthesizes clicks (doing so is both unreliable and detectable).
///
/// The widget attaches the same persistent `WKWebsiteDataStore`-backed
/// WKWebView that [ChallengeController] exports cookies from, so a clearance
/// obtained here is immediately usable by native requests.
final class BrowserChallengeView extends StatefulWidget {
  const BrowserChallengeView({
    super.key,
    required this.session,
    required this.uri,
    this.onResolved,
    this.onCancelled,
  });

  final BrowserSession session;
  final Uri uri;
  final ValueChanged<ChallengeResult>? onResolved;
  final VoidCallback? onCancelled;

  @override
  State<BrowserChallengeView> createState() => _BrowserChallengeViewState();
}

class _BrowserChallengeViewState extends State<BrowserChallengeView> {
  WebViewSession? _webView;
  Object? _error;
  String? _hint;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final info = await widget.session.profileInfo();
      final session = await widget.session.webView.create(
        userAgent: info.userAgent,
        headless: false,
      );
      if (!mounted) {
        await session.dispose();
        return;
      }
      setState(() => _webView = session);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _complete() async {
    final webView = _webView;
    if (webView == null || _busy) return;

    setState(() {
      _busy = true;
      _hint = null;
    });
    try {
      final result = await widget.session.challenge
          .resolveFromVisibleSession(webView, widget.uri);
      if (!mounted) return;
      if (result.resolved) {
        widget.onResolved?.call(result);
      } else {
        setState(() => _hint = result.reason ?? 'Verification is not complete.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    final webView = _webView;
    _webView = null;
    if (webView != null) {
      // Fire-and-forget: the widget tree is already torn down.
      unawaited(webView.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return const Center(
        child: Text('The challenge WebView is only available on iOS.'),
      );
    }

    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Could not open the verification page: $error'),
        ),
      );
    }

    final webView = _webView;
    if (webView == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: <Widget>[
        Expanded(
          child: UiKitView(
            viewType: 'browser_http/challenge_view',
            creationParams: <String, Object?>{
              'id': webView.id,
              'url': widget.uri.toString(),
            },
            creationParamsCodec: const StandardMessageCodec(),
          ),
        ),
        if (_hint != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_hint!),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            TextButton(
              onPressed: _busy ? null : widget.onCancelled,
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: _busy ? null : _complete,
              child: const Text('I have completed the check'),
            ),
          ],
        ),
      ],
    );
  }
}
