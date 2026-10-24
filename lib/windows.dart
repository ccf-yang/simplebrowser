import 'dart:async';

import 'package:browser_http/browser_http.dart';
import 'package:flutter/foundation.dart';

/// One browsing window: a live WKWebView, its own event subscriptions, and the
/// few facts the task view draws for it.
///
/// Only the current window is attached to the widget tree. The others stay
/// alive on the native side — its session table is keyed by id, and a WebView
/// that is attached to nothing keeps its document, its scroll position and its
/// JavaScript — so coming back to a window is instant and costs no reload.
final class BrowseWindow {
  BrowseWindow._({
    required this.controller,
    required this.number,
    required this.openedAt,
  });

  final BrowserController controller;

  /// 1-based order the windows were opened in, shown as "窗口 3".
  final int number;
  final DateTime openedAt;

  /// Label and address, refreshed from [controller] whenever the page reports.
  String title = '';
  String url = '';

  /// PNG of the last rendered page, for the task view card. Null until the
  /// window has been away from the foreground once.
  Uint8List? thumbnail;

  StreamSubscription<WebViewNavigationEvent>? _navigationSubscription;
  StreamSubscription<PageNetworkEvent>? _pageSubscription;
  StreamSubscription<WebViewLinkPress>? _linkSubscription;
  StreamSubscription<WebViewVideoEvent>? _videoSubscription;
  VoidCallback? _listener;

  bool get isBlank => url.isEmpty || url == 'about:blank';

  String get host => Uri.tryParse(url)?.host ?? '';

  /// The letter drawn on a card that has no thumbnail yet. `www` would make
  /// every news site look like the same site.
  String get initial {
    final site = host.startsWith('www.') ? host.substring(4) : host;
    return site.isEmpty ? '？' : site[0].toUpperCase();
  }

  /// What the card and the switcher show: the page's title, its host, or the
  /// fact that nothing has been opened here yet.
  String get label {
    final text = title.trim();
    if (text.isNotEmpty) return text;
    final site = host;
    if (site.isNotEmpty) return site;
    return '空白窗口';
  }

  /// The one-line subtitle under the label.
  String get detail {
    if (isBlank) return '还没有打开页面';
    final site = host;
    if (site.isEmpty) return url;
    var scheme = Uri.tryParse(url)?.scheme ?? '';
    if (scheme.isEmpty) scheme = 'https';
    return '$scheme://$site';
  }

  void refreshLabel() {
    title = controller.title?.trim() ?? title;
    url = controller.url ?? url;
  }

  void _dispose() {
    final listener = _listener;
    if (listener != null) controller.removeListener(listener);
    _listener = null;
    unawaited(_navigationSubscription?.cancel());
    unawaited(_pageSubscription?.cancel());
    unawaited(_linkSubscription?.cancel());
    unawaited(_videoSubscription?.cancel());
    _navigationSubscription = null;
    _pageSubscription = null;
    _linkSubscription = null;
    _videoSubscription = null;
    controller.dispose();
  }
}

/// The list of windows and which one the user is looking at.
///
/// Deliberately not a `ChangeNotifier`: the host page already rebuilds on its
/// own, and window events arrive on a per-window callback anyway.
final class WindowStore {
  WindowStore({
    required this.session,
    required this.onChanged,
    required this.onNavigation,
    required this.onPageEvent,
    required this.onLinkPress,
    required this.onVideoState,
    required this.onRedraw,
  });

  /// Windows held at once. Each one is a real WKWebView with its own WebKit
  /// process pool, so the ceiling is memory, not the interface.
  static const int max = 8;

  /// Thumbnail width. Two digits of megabytes of PNG per window buys nothing a
  /// 320 px card cannot show.
  static const int thumbnailWidth = 320;

  final BrowserSession session;

  /// The window's page state changed (title, url, loading, history).
  final void Function(BrowseWindow window) onChanged;

  /// A page jump this window decided about — including the ones it blocked.
  final void Function(BrowseWindow window, WebViewNavigationEvent event)
      onNavigation;

  /// fetch/XHR observations, shared by every window: the sniffer and the
  /// console are the app's, not one page's.
  final void Function(PageNetworkEvent event) onPageEvent;

  /// The user pressed and held a link in this window.
  final void Function(BrowseWindow window, WebViewLinkPress press) onLinkPress;

  /// The player window of this page opened, closed, or reported playback.
  final void Function(BrowseWindow window, WebViewVideoEvent event) onVideoState;

  /// Something worth repainting (a thumbnail landed).
  final VoidCallback onRedraw;

  final List<BrowseWindow> _list = <BrowseWindow>[];
  int _active = 0;
  int _serial = 0;

  List<BrowseWindow> get windows => List<BrowseWindow>.unmodifiable(_list);
  BrowseWindow get current => _list[_active];
  int get count => _list.length;
  bool get isEmpty => _list.isEmpty;
  bool get hasMultiple => _list.length > 1;

  /// Creates a window and makes it current.
  ///
  /// It opens blank: which document it loads, with which user agent and rules,
  /// is the host's decision, not the list's.
  BrowseWindow? open() {
    if (_list.length >= max) return null;
    final controller = BrowserController(session: session);
    final window = BrowseWindow._(
      controller: controller,
      number: ++_serial,
      openedAt: DateTime.now(),
    );

    void listener() => onChanged(window);
    window._listener = listener;
    controller.addListener(listener);
    window._navigationSubscription =
        controller.navigationEvents.listen((event) {
      onNavigation(window, event);
    });
    window._pageSubscription = controller.networkEvents.listen(onPageEvent);
    window._linkSubscription = controller.linkPresses.listen((press) {
      onLinkPress(window, press);
    });
    window._videoSubscription = controller.videoEvents.listen((event) {
      onVideoState(window, event);
    });

    _list.add(window);
    _active = _list.length - 1;
    return window;
  }

  /// Makes [window] the one the user sees. Returns false when it already was.
  ///
  /// The host takes the picture of the window being left *before* it calls
  /// this: a WebView that has already been swapped out of the view hierarchy has
  /// nothing reliable left to render.
  bool select(BrowseWindow window) {
    final index = _list.indexOf(window);
    if (index < 0 || index == _active) return false;
    _active = index;
    return true;
  }

  /// Drops a window and its WebView. When the current one goes, the neighbour
  /// that takes its place is returned so the host can rebind its chrome.
  BrowseWindow? close(BrowseWindow window) {
    final index = _list.indexOf(window);
    if (index < 0) return null;
    final wasCurrent = index == _active;
    _list.removeAt(index);
    window._dispose();
    if (_list.isEmpty) {
      _active = 0;
      return null;
    }
    _active = _active.clamp(0, _list.length - 1);
    return wasCurrent ? _list[_active] : null;
  }

  /// Renders [window] into its card thumbnail.
  ///
  /// Only meaningful for a window that is still on screen, which is why the host
  /// calls it at the two moments a window is about to be left: switching and
  /// opening.
  Future<void> capture(BrowseWindow window) async {
    final png = await window.controller.snapshot(maxWidth: thumbnailWidth);
    if (png == null || png.lengthInBytes < 512) return;
    window.thumbnail = png;
    onRedraw();
  }

  void dispose() {
    for (final window in _list) {
      window._dispose();
    }
    _list.clear();
  }
}
