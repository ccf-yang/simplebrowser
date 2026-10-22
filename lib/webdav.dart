import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// WebDAV 配置（设置 → WebDAV 存储里填，落在 browser_prefs.json）。
///
/// 目标场景是自己局域网里的盒子（OpenList / Alist 的 WebDAV 挂在 `/dav`），
/// 所以字段保持最少：地址、账号、密码、存放目录，外加两个开关。
class WebDavConfig {
  const WebDavConfig({
    this.url = '',
    this.username = '',
    this.password = '',
    this.savePath = '',
    this.ignoreTls = false,
    this.alsoPhotos = false,
  });

  /// 形如 `http://192.168.1.17:5244/dav`
  final String url;
  final String username;
  final String password;

  /// 远端存放目录，相对 WebDAV 根；空就用根目录
  final String savePath;

  /// 自签或过期证书也照传
  final bool ignoreTls;

  /// 传完顺手存一份到相册（默认只留盒子那一份）
  final bool alsoPhotos;

  bool get ready => url.trim().isNotEmpty;

  static const kUrl = 'webdavUrl';
  static const kUser = 'webdavUser';
  static const kPass = 'webdavPass';
  static const kPath = 'webdavPath';
  static const kIgnoreTls = 'webdavIgnoreTls';
  static const kAlsoPhotos = 'webdavAlsoPhotos';

  factory WebDavConfig.fromPrefs(Map<String, Object?> prefs) => WebDavConfig(
    url: '${prefs[kUrl] ?? ''}',
    username: '${prefs[kUser] ?? ''}',
    password: '${prefs[kPass] ?? ''}',
    savePath: '${prefs[kPath] ?? ''}',
    ignoreTls: prefs[kIgnoreTls] == true,
    alsoPhotos: prefs[kAlsoPhotos] == true,
  );

  /// 写进 prefs 的键值；清空即删键
  Map<String, Object?> toPrefs() => <String, Object?>{
    kUrl: url.trim(),
    kUser: username.trim(),
    kPass: password,
    kPath: savePath.trim(),
    kIgnoreTls: ignoreTls,
    kAlsoPhotos: alsoPhotos,
  };

  WebDavConfig copyWith({
    String? url,
    String? username,
    String? password,
    String? savePath,
    bool? ignoreTls,
    bool? alsoPhotos,
  }) => WebDavConfig(
    url: url ?? this.url,
    username: username ?? this.username,
    password: password ?? this.password,
    savePath: savePath ?? this.savePath,
    ignoreTls: ignoreTls ?? this.ignoreTls,
    alsoPhotos: alsoPhotos ?? this.alsoPhotos,
  );

  /// 列表页副标题用：不暴露密码，只说清往哪儿传
  String get summary {
    if (!ready) return '未配置';
    final host = Uri.tryParse(normalizedBase)?.host ?? url.trim();
    final target = savePath.trim().isEmpty ? '/' : normalizeRemotePath(savePath);
    return '$host · $target';
  }

  String get normalizedBase {
    try {
      return normalizeWebDavBase(url);
    } on WebDavException {
      return url.trim();
    }
  }
}

class WebDavErrorKind {
  static const badConfig = 'badConfig';
  static const unauthorized = 'unauthorized';
  static const forbidden = 'forbidden';
  static const notFound = 'notFound';
  static const conflict = 'conflict';
  static const insufficientStorage = 'insufficientStorage';
  static const timeout = 'timeout';
  static const tls = 'tls';
  static const notWebDavRoot = 'notWebDavRoot';
  static const tooManyAttempts = 'tooManyAttempts';
  static const writeDisabled = 'writeDisabled';
  static const localNetworkBlocked = 'localNetworkBlocked';
  static const server = 'server';
  static const network = 'network';
}

/// 失败要说人话。这些文案来自 booktest 在家里盒子上的实测结论：OpenList 的
/// WebDAV 挂在 `/dav`、读写权限分两档、连错密码会按 IP 锁五分钟，而 iOS 14+
/// 没给「本地网络」权限时只会报一个普通 socket 失败。
class WebDavException implements Exception {
  WebDavException(this.kind, {this.statusCode, this.detail});

  final String kind;
  final int? statusCode;
  final String? detail;

  String get message => switch (kind) {
    WebDavErrorKind.badConfig =>
      '地址格式不对，请填写完整 URL，例如 http://192.168.1.17:5244/dav',
    WebDavErrorKind.unauthorized => '用户名或密码错误',
    WebDavErrorKind.forbidden =>
      '已登录，但这个账号没有读这里的权限（后台用户权限里勾上 WebDAV 读取）',
    WebDavErrorKind.notFound => '路径不存在，可能已被移动或重命名',
    WebDavErrorKind.conflict => '上级目录不存在或不可写',
    WebDavErrorKind.insufficientStorage => '服务器空间不足',
    WebDavErrorKind.timeout => '连接超时，检查服务器是否在运行',
    WebDavErrorKind.tls =>
      '证书不受信任（自签或已过期）。可以在这一页勾上「忽略证书校验」，'
          '如果服务器本来就是明文，地址请用 http:// 开头',
    WebDavErrorKind.notWebDavRoot =>
      '这个地址不是 WebDAV 入口。OpenList 要填到 /dav，'
          '例如 http://192.168.1.17:5244/dav',
    WebDavErrorKind.tooManyAttempts =>
      '连续失败次数太多，服务器把这个 IP 临时锁了 5 分钟，先等一会儿再试',
    WebDavErrorKind.writeDisabled =>
      '这个账号只能看不能传，请在后台的用户权限里勾上 WebDAV 写入',
    WebDavErrorKind.localNetworkBlocked =>
      'iPhone 不允许本 App 访问局域网。请到 设置 → 隐私与安全性 → 本地网络 '
          '里打开「So~」，然后彻底关掉 App 再试一次',
    WebDavErrorKind.server =>
      '服务器返回异常${statusCode == null ? _rawHint : ' (HTTP $statusCode)'}',
    _ => '无法连接服务器${statusCode == null ? _rawHint : ' (HTTP $statusCode)'}',
  };

  /// 没拿到状态码时带上系统报错的第一行，免得所有失败都糊成一句
  /// 「无法连接服务器」，看不出是断连还是被拒。
  String get _rawHint {
    final text = (detail ?? '').trim();
    if (text.isEmpty) return '';
    final line = text.split('\n').first;
    return '：${line.length > 140 ? '${line.substring(0, 140)}…' : line}';
  }

  @override
  String toString() => message;

  static WebDavException fromStatus(int code, {Object? body}) =>
      WebDavException(
        switch (code) {
          401 => WebDavErrorKind.unauthorized,
          403 => WebDavErrorKind.forbidden,
          404 => WebDavErrorKind.notFound,
          405 || 409 => WebDavErrorKind.conflict,
          429 => WebDavErrorKind.tooManyAttempts,
          507 => WebDavErrorKind.insufficientStorage,
          >= 500 => WebDavErrorKind.server,
          // 有状态码就说明连上了服务器。PUT 常见的 400/412 不能报成「无法连接」，
          // 否则一次被拒的上传会把人引去查 Wi-Fi。
          >= 400 => WebDavErrorKind.server,
          _ => WebDavErrorKind.network,
        },
        statusCode: code,
        detail: body?.toString(),
      );

  /// PUT / MKCOL 撞到的 403 基本都是「没开 WebDAV 写入」，跟读不到混成一句
  /// 会让人反复改密码。
  static WebDavException forWrite(WebDavException error) =>
      error.kind == WebDavErrorKind.forbidden
      ? WebDavException(
          WebDavErrorKind.writeDisabled,
          statusCode: error.statusCode,
          detail: error.detail,
        )
      : error;
}

/// 远端一条目录项（测试连通时用得到）
class WebDavEntry {
  const WebDavEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.size = 0,
  });

  final String name;
  final String path;
  final bool isDir;
  final int size;
}

/// 把用户手打的地址变成真正能用的 WebDAV 根。两件必须替他做掉的事（漏了会一路
/// 405 / 握手失败，看上去跟密码错一样）：省略协议时内网地址走 http，其余走
/// https；去掉末尾多余的 `/`，拼路径才不会出 `//`。
String normalizeWebDavBase(String raw) {
  var value = raw.trim();
  if (value.isEmpty) throw WebDavException(WebDavErrorKind.badConfig);
  // 中间带空白的从来不是合法 URL，Uri.parse 却会把它编码后将就解析出来。
  if (value.contains(RegExp(r'\s'))) {
    throw WebDavException(WebDavErrorKind.badConfig);
  }
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://').hasMatch(value)) {
    value = '${looksLikeLan(value) ? 'http' : 'https'}://$value';
  }
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw WebDavException(WebDavErrorKind.badConfig);
  }
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return uri.replace(path: path).toString();
}

/// 目标是局域网地址吗：决定 socket 失败要不要报成「本地网络权限被拒」。
bool looksLikeLan(String url) {
  var authority = url
      .replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://'), '')
      .split('/')
      .first;
  if (authority.contains('@')) {
    authority = authority.substring(authority.lastIndexOf('@') + 1);
  }
  if (authority.startsWith('[')) return true; // IPv6 字面量
  final colon = authority.lastIndexOf(':');
  final hasPort =
      colon > 0 && int.tryParse(authority.substring(colon + 1)) != null;
  final host = hasPort ? authority.substring(0, colon) : authority;
  return RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host) ||
      host == 'localhost' ||
      host.endsWith('.local');
}

/// 远端路径归一：一律绝对形式，丢掉空段与 `.`/`..`（`..` 直接扔，绝不让它跑出根）。
String normalizeRemotePath(String raw) {
  final segments = raw
      .split('/')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty && part != '.' && part != '..')
      .toList();
  return segments.isEmpty ? '/' : '/${segments.join('/')}';
}

String joinRemote(String dir, String name) {
  final normalized = normalizeRemotePath(dir);
  final clean = name.replaceAll('/', '_').trim();
  if (clean.isEmpty) return normalized;
  return normalized == '/' ? '/$clean' : '$normalized/$clean';
}

/// 重名时在扩展名前追加 `_1`、`_2`
String nextUniqueName(String name, int index) {
  final dot = name.lastIndexOf('.');
  final stem = dot <= 0 ? name : name.substring(0, dot);
  final ext = dot <= 0 ? '' : name.substring(dot);
  return '${stem}_$index$ext';
}

const _mimeMap = <String, String>{
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.heic': 'image/heic',
  '.heif': 'image/heif',
  '.bmp': 'image/bmp',
  '.avif': 'image/avif',
  '.svg': 'image/svg+xml',
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.mov': 'video/quicktime',
  '.mkv': 'video/x-matroska',
  '.webm': 'video/webm',
  '.ts': 'video/mp2t',
  '.avi': 'video/x-msvideo',
  '.txt': 'text/plain; charset=utf-8',
};

String mimeTypeFor(String path) {
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot).toLowerCase();
  return _mimeMap[ext] ?? 'application/octet-stream';
}

/// 解析 207 Multi-Status。不引 xml 包（iOS 包体积 + 工程里没有），用容错正则
/// 按 response 块切，命名空间前缀（d: / DAV: / 无前缀）都认。
List<WebDavEntry> parseMultistatus(String body, {required String hostBase}) {
  if (body.trim().isEmpty) return const <WebDavEntry>[];
  final lower = body.toLowerCase();
  if (!lower.contains('<multistatus') &&
      !lower.contains(':multistatus') &&
      !lower.contains('"multistatus')) {
    // 登录页 / 站点首页 / OpenList 前端本身也可能是合法 HTML，能一路解出「空
    // 目录」，所以必须确认根节点真是 multistatus 才算连上了 WebDAV。
    throw WebDavException(
      WebDavErrorKind.notWebDavRoot,
      detail: 'PROPFIND 响应里没有 multistatus 节点',
    );
  }
  final entries = <WebDavEntry>[];
  for (final block in _responseBlocks(body)) {
    final href = _firstTag(block, 'href');
    if (href == null || href.trim().isEmpty) continue;
    final name = _firstTag(block, 'displayname') ?? '';
    final isDir = RegExp(
      '<[\\w.-]*:?resourcetype[^>]*>[\\s\\S]*?<[\\w.-]*:?collection',
      caseSensitive: false,
    ).hasMatch(block);
    final size =
        int.tryParse((_firstTag(block, 'getcontentlength') ?? '').trim()) ?? 0;
    var path = _hrefToPath(href, hostBase: hostBase);
    if (path == null) continue;
    path = normalizeRemotePath(path);
    if (path == '/' || path.isEmpty) continue; // 目录自身不算子项
    final base = name.trim().isEmpty || name.contains('/')
        ? _tail(path)
        : name.trim();
    if (base.startsWith('.')) continue;
    entries.add(
      WebDavEntry(
        name: base,
        path: path,
        isDir: isDir,
        size: isDir ? 0 : size,
      ),
    );
  }
  entries.sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return entries;
}

Iterable<String> _responseBlocks(String body) {
  final pattern = RegExp(
    r'<([\w.-]*:?)response\b[^>]*>([\s\S]*?)<\/\1response>',
    caseSensitive: false,
  );
  return pattern.allMatches(body).map((match) => match.group(2) ?? '');
}

String? _firstTag(String block, String local) {
  final pattern = RegExp(
    '<[\\w.-]*:?$local\\b[^>]*>([\\s\\S]*?)</[\\w.-]*:?$local>',
    caseSensitive: false,
  );
  final raw = pattern.firstMatch(block)?.group(1)?.trim();
  if (raw == null) return null;
  return raw
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}

String? _hrefToPath(String href, {required String hostBase}) {
  String value;
  try {
    // href 按 RFC 该是 percent-encoded，但部分 Alist/OpenList 版本直接吐未编码
    // 的 UTF-8，decodeFull 对后者会抛——原样返回更安全。
    value = href.codeUnits.every((unit) => unit < 0x80)
        ? _tryDecode(href)
        : href;
    if (value.contains('://')) value = Uri.parse(value).path;
  } on Object {
    return null;
  }
  if (hostBase.isNotEmpty && hostBase != '/') {
    final prefix = hostBase.endsWith('/') ? hostBase : '$hostBase/';
    if (value.startsWith(prefix)) {
      value = '/${value.substring(prefix.length)}';
    } else if (value == hostBase) {
      value = '/';
    }
  }
  return value;
}

String _tryDecode(String value) {
  try {
    return Uri.decodeFull(value);
  } on FormatException {
    return value;
  }
}

String _tail(String path) {
  final index = path.lastIndexOf('/');
  return index < 0 ? path : path.substring(index + 1);
}

/// 极简 WebDAV 客户端：只做「测连通 + 传文件」两件事，走 dart:io HttpClient，
/// 不给 iOS 包添新依赖，也不用浏览器那套 Rust 引擎——上传要的是把文件流直接
/// 灌进 PUT，而引擎的请求体只吃整块字节。
///
/// 认证头每次主动带上，不做 challenge 往返：OpenList / Alist 的 WebDAV 对 401
/// 重试的支持不稳定，PROPFIND 尤其明显。
class WebDavClient {
  WebDavClient(this.config, {Duration? connectTimeout})
    : base = Uri.parse(normalizeWebDavBase(config.url)) {
    _client = HttpClient()
      ..connectionTimeout = connectTimeout ?? const Duration(seconds: 15);
    if (config.ignoreTls) {
      // 家庭盒子的自签证书很常见；勾了「忽略证书校验」才放开。
      _client.badCertificateCallback = (_, __, ___) => true;
    }
  }

  final WebDavConfig config;
  final Uri base;
  late final HttpClient _client;

  /// Basic 认证头。RFC 7617 只规定 base64，字符集由服务器约定：统一按 UTF-8
  /// 编——纯 ASCII 时与 latin1 逐字节相同，密码里有中文时 latin1 会直接抛
  /// 「Contains invalid characters」把请求炸掉。
  String get authHeader =>
      'Basic ${base64Encode(utf8.encode('${config.username}:${config.password}'))}';

  /// 服务器前缀（例如 `/dav`），PROPFIND 返回的 href 要把它剥掉
  String get hostBasePath {
    final segments = base.pathSegments.where((s) => s.isNotEmpty);
    return segments.isEmpty ? '' : '/${segments.join('/')}';
  }

  bool get _lanTarget => looksLikeLan(config.url);

  Uri urlFor(String path) => base.replace(
    pathSegments: <String>[
      ...base.pathSegments.where((s) => s.isNotEmpty),
      ...normalizeRemotePath(path)
          .split('/')
          .where((s) => s.isNotEmpty),
    ],
  );

  /// 列一个目录（Depth 1）。测试连通就调它。
  Future<List<WebDavEntry>> list(String path) async {
    final target = normalizeRemotePath(path);
    HttpClientResponse response;
    try {
      final request = await _open('PROPFIND', urlFor(target));
      request.headers.set('Depth', '1');
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/xml; charset=utf-8',
      );
      request.write(_propfindBody);
      response = await _close(request);
    } on Object catch (error) {
      throw _mapError(error);
    }
    final status = response.statusCode;
    final body = await _readBody(response);
    if (status >= 300 && status < 400) {
      // OpenList 常把 /dav 跳成 /dav/，跟随后会打到前端页面解出「空目录」，
      // 所以这里不跟，直接把跳转说成「地址不是 WebDAV 入口」并带上 Location。
      throw WebDavException(
        WebDavErrorKind.notWebDavRoot,
        statusCode: status,
        detail: '服务器跳转到 ${response.headers.value(HttpHeaders.locationHeader)}',
      );
    }
    if (status != 207 && status != 200) {
      // 漏掉 /dav 时 PROPFIND 打到 OpenList 的 API 根，会被 gin 拒成
      // 405/404/400 —— 这是地址填错，不是「上级目录不可写」。
      if (target == '/' && (status == 400 || status == 404 || status == 405)) {
        throw WebDavException(
          WebDavErrorKind.notWebDavRoot,
          statusCode: status,
          detail: body,
        );
      }
      throw WebDavException.fromStatus(status, body: body);
    }
    return parseMultistatus(body, hostBase: hostBasePath);
  }

  static const _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>\n'
      '<d:propfind xmlns:d="DAV:"><d:prop><d:displayname/>'
      '<d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>';

  /// 逐级建目录：WebDAV 的 PUT 不会自动创建父目录，MKCOL 也只建一层。
  /// 段名保持原样传下去，URL 编码由 [urlFor] 的 pathSegments 统一做（在这里
  /// 提前 encodeComponent 会被再编一次，中文目录名就变成 %25E4…）。
  Future<void> ensureDir(String path) async {
    final segments = normalizeRemotePath(path)
        .split('/')
        .where((s) => s.isNotEmpty);
    var current = '';
    for (final segment in segments) {
      current = '$current/$segment';
      await _mkcol(current);
    }
  }

  Future<void> _mkcol(String path) async {
    try {
      final request = await _open('MKCOL', urlFor(path));
      final response = await _close(request);
      final code = response.statusCode;
      await response.drain<void>();
      // 目录已存在要当成功：405 是最常见的「已经有了」，200/204/201 都算过。
      if (code == 200 || code == 201 || code == 204 || code == 405) return;
      throw WebDavException.forWrite(WebDavException.fromStatus(code));
    } on WebDavException {
      rethrow;
    } on Object catch (error) {
      throw WebDavException.forWrite(_mapError(error));
    }
  }

  Future<bool> exists(String path) async => (await stat(path)) != null;

  /// HEAD 拿远端文件大小；不存在返回 null。
  /// 有了尺寸才能判断「同名但是另一个文件」，而不是见同名就跳过。
  Future<int?> stat(String path) async {
    try {
      final request = await _open('HEAD', urlFor(path));
      final response = await _close(request);
      await response.drain<void>();
      final code = response.statusCode;
      if (code == 404 || code == 405 || code == 403) return null;
      if (code >= 400) {
        throw WebDavException.fromStatus(code);
      }
      final length = response.contentLength;
      return length < 0 ? 0 : length;
    } on Object catch (error) {
      final mapped = error is WebDavException ? error : _mapError(error);
      if (mapped.statusCode == 404 ||
          mapped.statusCode == 405 ||
          mapped.kind == WebDavErrorKind.conflict) {
        return null;
      }
      throw mapped;
    }
  }

  /// 找一个不重名的落点（重名默认追加 _1、_2，不覆盖已有文件）
  Future<String> uniquePath(String dir, String fileName) async {
    var candidate = joinRemote(dir, fileName);
    if (!await exists(candidate)) return candidate;
    for (var i = 1; i < 200; i++) {
      candidate = joinRemote(dir, nextUniqueName(fileName, i));
      if (!await exists(candidate)) return candidate;
    }
    throw WebDavException(WebDavErrorKind.conflict, detail: '同名文件过多');
  }

  /// PUT 一个本地文件；传完由调用方删掉本机那份。
  Future<void> uploadFile(
    String localPath,
    String remotePath, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final file = File(localPath);
    final length = await file.length();
    try {
      final request = await _open('PUT', urlFor(remotePath));
      request.contentLength = length;
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        mimeTypeFor(remotePath),
      );
      await request.addStream(_counted(file.openRead(), length, onProgress));
      final response = await _close(request);
      final code = response.statusCode;
      final body = await _readBody(response);
      if (code == 200 || code == 201 || code == 204) return;
      throw WebDavException.forWrite(
        WebDavException.fromStatus(code, body: body),
      );
    } on WebDavException {
      rethrow;
    } on Object catch (error) {
      throw WebDavException.forWrite(_mapError(error));
    }
  }

  Stream<List<int>> _counted(
    Stream<List<int>> source,
    int total,
    void Function(int sent, int total)? onProgress,
  ) async* {
    var sent = 0;
    await for (final chunk in source) {
      sent += chunk.length;
      onProgress?.call(sent, total);
      yield chunk;
    }
  }

  Future<HttpClientRequest> _open(String method, Uri uri) async {
    final request = await _client.openUrl(method, uri);
    request.headers.set('Authorization', authHeader);
    // 跳转别自动跟：PROPFIND 被 301 到站点首页会解出「空目录」，把「地址没带
    // /dav」这种真问题糊成连通正常。
    request.followRedirects = false;
    return request;
  }

  Future<HttpClientResponse> _close(HttpClientRequest request) async {
    try {
      return await request.close().timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw WebDavException(WebDavErrorKind.timeout);
    }
  }

  Future<String> _readBody(HttpClientResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > 256 * 1024) break; // 列表再长也用不到更多
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 关掉连接池，别把 socket 悬在 App 里
  void close() => _client.close(force: true);

  WebDavException _mapError(Object error) {
    if (error is SocketException) {
      final text = error.toString();
      final denied =
          _lanTarget &&
          (text.contains('Network is down') ||
              text.contains('No route to host') ||
              text.contains('Operation not permitted'));
      return WebDavException(
        denied ? WebDavErrorKind.localNetworkBlocked : WebDavErrorKind.network,
        detail: text,
      );
    }
    if (error is HandshakeException) {
      final text = error.toString();
      final isCert =
          text.toLowerCase().contains('certificate') || text.contains('x509');
      // 不是证书问题却握手失败，基本都是拿 https 去连明文端口。
      return WebDavException(
        isCert && !config.ignoreTls ? WebDavErrorKind.tls : WebDavErrorKind.badConfig,
        detail: text,
      );
    }
    if (error is TimeoutException) return WebDavException(WebDavErrorKind.timeout);
    if (error is FormatException) {
      return WebDavException(WebDavErrorKind.badConfig, detail: '$error');
    }
    return WebDavException(WebDavErrorKind.network, detail: '$error');
  }
}
