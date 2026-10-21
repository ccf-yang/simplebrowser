import 'dart:async';

import 'package:browser_http/browser_http.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const ExampleApp());
}

/// Small usage example.
///
/// For a full browsing UI (URL bar, back/forward, WebView + native capture
/// panels), see the `simplebr` app: `BrowserController` + `BrowserView`.
class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  final BrowserSession _session = BrowserHttp.session(
    logSink: MemoryLogSink(),
  );

  String _output = 'Idle';

  Future<void> _run() async {
    setState(() => _output = 'Requesting...');
    try {
      final response = await _session.get(
        Uri.parse('https://example.com'),
      );
      setState(() => _output = 'HTTP ${response.statusCode}');
    } on BrowserHttpException catch (error) {
      setState(() => _output = '${error.code}: ${error.message}');
    }
  }

  /// Shows the ordered headers the native engine used, including the cookie
  /// jar's `Cookie` header.
  Future<void> _capture() async {
    try {
      final captured = await _session.capture(
        Uri.parse('https://example.com'),
      );
      setState(() {
        _output = 'HTTP ${captured.response.statusCode} in '
            '${captured.elapsed.inMilliseconds} ms\n'
            '${captured.requestHeaders.map((h) => h.toString()).join('\n')}';
      });
    } on BrowserHttpException catch (error) {
      setState(() => _output = '${error.code}: ${error.message}');
    }
  }

  Future<void> _challenge() async {
    final result = await _session.challenge.ensureClearance(
      Uri.parse('https://example.com'),
      mode: ChallengeMode.auto,
    );
    setState(() => _output = 'Challenge: ${result.outcome.name}');
  }

  @override
  void dispose() {
    unawaited(_session.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('browser_http example')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SelectableText(_output),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _run, child: const Text('Send request')),
              ElevatedButton(
                onPressed: _capture,
                child: const Text('Capture with headers'),
              ),
              ElevatedButton(
                onPressed: _challenge,
                child: const Text('Try challenge'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
