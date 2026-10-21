import '../models/browser_cookie.dart';

/// Parses one `Set-Cookie` header value into a [BrowserCookie].
///
/// Implements the RFC 6265bis subset that browsers actually emit on the wire:
/// `Expires`, `Max-Age`, `Domain`, `Path`, `Secure`, `HttpOnly` and `SameSite`.
/// Returns `null` for malformed headers rather than throwing: a hostile server
/// must not be able to break a request.
BrowserCookie? parseSetCookie(String header, Uri origin) {
  final parts = header.split(';');
  if (parts.isEmpty) return null;

  final pair = parts.first;
  final equals = pair.indexOf('=');
  if (equals <= 0) return null;

  final name = pair.substring(0, equals).trim();
  final value = pair.substring(equals + 1).trim();
  if (name.isEmpty || !_isValidName(name)) return null;

  String? domain;
  var path = _defaultPath(origin);
  DateTime? expires;
  var secure = false;
  var httpOnly = false;
  String? sameSite;

  for (final rawAttribute in parts.skip(1)) {
    final attribute = rawAttribute.trim();
    if (attribute.isEmpty) continue;
    final separator = attribute.indexOf('=');
    final key = (separator < 0 ? attribute : attribute.substring(0, separator))
        .trim()
        .toLowerCase();
    final rawValue =
        separator < 0 ? '' : attribute.substring(separator + 1).trim();

    switch (key) {
      case 'expires':
        expires = _parseHttpDate(rawValue);
      case 'max-age':
        final seconds = int.tryParse(rawValue);
        if (seconds != null) {
          // Max-Age wins over Expires, per RFC 6265 section 5.3.
          expires = DateTime.now()
              .toUtc()
              .add(Duration(seconds: seconds));
        }
      case 'domain':
        if (rawValue.isNotEmpty) {
          domain = rawValue.toLowerCase();
        }
      case 'path':
        if (rawValue.startsWith('/')) {
          path = rawValue;
        }
      case 'secure':
        secure = true;
      case 'httponly':
        httpOnly = true;
      case 'samesite':
        final normalized = rawValue.toLowerCase();
        if (normalized == 'strict' ||
            normalized == 'lax' ||
            normalized == 'none') {
          sameSite = '${normalized[0].toUpperCase()}${normalized.substring(1)}';
        }
    }
  }

  return BrowserCookie(
    name: name,
    value: value,
    domain: domain,
    path: path,
    expires: expires,
    secure: secure,
    httpOnly: httpOnly,
    sameSite: sameSite,
  );
}

/// RFC 6265 default-path: the request path up to (excluding) the last `/`.
String _defaultPath(Uri origin) {
  final path = origin.path;
  if (path.isEmpty || !path.startsWith('/')) return '/';
  final lastSlash = path.lastIndexOf('/');
  return lastSlash <= 0 ? '/' : path.substring(0, lastSlash);
}

/// Cookie names are tokens; a `=` or whitespace inside the name is invalid.
bool _isValidName(String name) {
  for (final unit in name.codeUnits) {
    if (unit <= 0x20 || unit >= 0x7f) return false;
    const separators = '()<>@,;:\\"/[]?={}';
    if (separators.codeUnits.contains(unit)) return false;
  }
  return true;
}

/// Accepts the three HTTP-date formats a server may send.
DateTime? _parseHttpDate(String input) {
  final value = input.trim();
  if (value.isEmpty) return null;

  // IMF-fixdate, e.g. `Wed, 21 Oct 2015 07:28:00 GMT`.
  final rfc1123 =
      RegExp(r'^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$');
  final match = rfc1123.firstMatch(value);
  if (match != null) {
    return _utc(
      int.parse(match.group(3)!),
      match.group(2)!,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }

  // RFC 850, e.g. `Wednesday, 21-Oct-15 07:28:00 GMT`.
  final rfc850 = RegExp(
    r'^\w+, (\d{2})-(\w{3})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) GMT$',
  );
  final match850 = rfc850.firstMatch(value);
  if (match850 != null) {
    final twoDigitYear = int.parse(match850.group(3)!);
    // RFC 6265: a 2-digit year more than 50 years in the future is in the past.
    final fullYear = 2000 + twoDigitYear;
    return _utc(
      fullYear,
      match850.group(2)!,
      int.parse(match850.group(1)!),
      int.parse(match850.group(4)!),
      int.parse(match850.group(5)!),
      int.parse(match850.group(6)!),
    );
  }

  // asctime, e.g. `Wed Oct 21 07:28:00 2015`.
  final asctime = RegExp(
    r'^\w{3} (\w{3}) (\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})$',
  );
  final matchAsctime = asctime.firstMatch(value);
  if (matchAsctime != null) {
    return _utc(
      int.parse(matchAsctime.group(6)!),
      matchAsctime.group(1)!,
      int.parse(matchAsctime.group(2)!),
      int.parse(matchAsctime.group(3)!),
      int.parse(matchAsctime.group(4)!),
      int.parse(matchAsctime.group(5)!),
    );
  }

  return null;
}

DateTime? _utc(
  int year,
  String monthName,
  int day,
  int hour,
  int minute,
  int second,
) {
  const months = <String>[
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];
  final month = months.indexOf(monthName.toLowerCase());
  if (month < 0) return null;
  if (hour > 23 || minute > 59 || second > 60) return null;
  return DateTime.utc(year, month + 1, day, hour, minute, second);
}
