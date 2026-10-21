/// Removes credentials from anything that may reach a log sink.
///
/// This is enforced in the domain layer, before any adapter sees the data, so
/// a custom sink cannot accidentally leak secrets.
final class LogRedactor {
  const LogRedactor({
    Set<String>? sensitiveHeaders,
    Set<String>? sensitiveQueryParameters,
    this.mask = '<redacted>',
  })  : sensitiveHeaders = sensitiveHeaders ?? defaultSensitiveHeaders,
        sensitiveQueryParameters =
            sensitiveQueryParameters ?? defaultSensitiveQueryParameters;

  /// Matched case-insensitively.
  static const Set<String> defaultSensitiveHeaders = <String>{
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
    'x-api-key',
    'x-auth-token',
  };

  /// Query parameters that routinely carry credentials. Matched
  /// case-insensitively.
  static const Set<String> defaultSensitiveQueryParameters = <String>{
    'token',
    'access_token',
    'refresh_token',
    'id_token',
    'api_key',
    'apikey',
    'signature',
    'sig',
    'password',
    'passwd',
    'secret',
    'session',
    'sid',
  };

  final Set<String> sensitiveHeaders;
  final Set<String> sensitiveQueryParameters;
  final String mask;

  Map<String, String> headers(Map<String, String> input) => <String, String>{
        for (final entry in input.entries)
          entry.key: _isSensitive(entry.key) ? mask : entry.value,
      };

  /// Masks sensitive query parameters in place and drops the fragment.
  Uri uri(Uri input) {
    if (input.queryParameters.isEmpty) return input.replace(fragment: '');
    final masked = <String, String>{
      for (final entry in input.queryParameters.entries)
        entry.key: sensitiveQueryParameters.contains(entry.key.toLowerCase())
            ? mask
            : entry.value,
    };
    return input.replace(queryParameters: masked, fragment: '');
  }

  bool _isSensitive(String name) =>
      sensitiveHeaders.contains(name.toLowerCase());
}
