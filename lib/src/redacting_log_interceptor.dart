import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'hashing.dart';

/// Receives one formatted log record (possibly several lines).
typedef LogSink = void Function(String record);

/// A compact request/response logger that redacts secrets.
///
/// Each request produces one record when it is sent and one when it
/// completes or fails, correlated by an id (`#3`):
///
/// ```text
/// --> POST https://api.example.com/login?next=%2F #3
///     headers: content-type: application/json
///     body: {"username":"amina","password":"[REDACTED]"}
/// <-- 200 POST https://api.example.com/login?next=%2F #3 84ms
///     body: {"access":"[REDACTED jwt#4f1c2a]","user":{"id":7}}
/// ```
///
/// **What is redacted.**
///
/// * Values of headers, query parameters, form fields and JSON keys (at any
///   depth, in maps and lists) whose name matches [redactKeys] exactly or
///   contains one of [redactKeyFragments]. Names are compared ignoring case
///   and the separators `-`, `_`, `.` and spaces, so `X-API-KEY`, `apiKey`
///   and `api_key` all match `api_key`.
/// * Any JWT-shaped string anywhere in the record, replaced with a short
///   fingerprint such as `jwt#a1b2c3` so you can still tell tokens apart.
/// * `Bearer`/`Basic` credentials and `name=value` or `"name":"value"` pairs
///   with a secret name in free text.
/// * URL user-info (`user:password@`).
///
/// **The error path.** Error records never print a stack trace. The error's
/// message and `toString()` are scrubbed with the rules above, and every
/// value the logger redacted from that request's headers, query or body is
/// also removed from them verbatim. If formatting fails, or the [sink]
/// throws, the request continues unaffected and nothing unredacted is
/// printed.
///
/// Bodies longer than [maxBodyChars] are truncated after redaction. An HTML
/// response to a request that expected JSON is flagged, which usually means
/// the request hit a web server or login page instead of the API.
///
/// The logger never modifies what is sent or received.
class RedactingLogInterceptor extends Interceptor {
  /// Creates the logger. [sink] defaults to [print].
  RedactingLogInterceptor({
    LogSink? sink,
    Set<String> redactKeys = defaultRedactKeys,
    Set<String> redactKeyFragments = defaultRedactKeyFragments,
    this.maxBodyChars = 2000,
    this.logHeaders = true,
    this.logRequestBody = true,
    this.logResponseBody = true,
    DateTime Function()? clock,
  })  : sink = sink ?? print,
        redactKeys = redactKeys.map(_normalize).toSet(),
        redactKeyFragments = redactKeyFragments.map(_normalize).toSet(),
        _clock = clock ?? DateTime.now;

  /// Names whose values are always redacted (exact match after normalising).
  static const Set<String> defaultRedactKeys = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
    'access',
    'refresh',
    'otp',
    'pin',
    'cvv',
    'cvc',
  };

  /// Name fragments whose values are redacted wherever they appear in a name,
  /// e.g. `token` matches `access_token`, `X-Auth-Token` and `tokenType`.
  static const Set<String> defaultRedactKeyFragments = {
    'password',
    'passwd',
    'secret',
    'token',
    'api_key',
    'private_key',
    'session',
    'credential',
  };

  /// The text that replaces a redacted value.
  static const String redacted = '[REDACTED]';

  static const String _idKey = 'dio_essentials.log.id';
  static const String _startKey = 'dio_essentials.log.start';

  static final RegExp _jwt = RegExp(
    r'eyJ[A-Za-z0-9_-]{2,}\.[A-Za-z0-9_-]{2,}\.[A-Za-z0-9_-]*',
  );
  static final RegExp _authScheme = RegExp(
    r'\b(Bearer|Basic|Token)\s+([A-Za-z0-9._~+/=\-]+)',
    caseSensitive: false,
  );
  static final RegExp _pair = RegExp(r'([A-Za-z0-9_.\-]+)=([^&\s;,"]+)');
  static final RegExp _jsonPair =
      RegExp(r'"([^"\\]+)"\s*:\s*"((?:[^"\\]|\\.)*)"');
  static final RegExp _formBody =
      RegExp(r'^[^=&\s]+=[^&\s]*(&[^=&\s]+=[^&\s]*)*$');

  /// Where records go.
  final LogSink sink;

  /// Normalised names redacted on exact match.
  final Set<String> redactKeys;

  /// Normalised name fragments redacted on substring match.
  final Set<String> redactKeyFragments;

  /// Bodies longer than this many characters are truncated.
  final int maxBodyChars;

  /// Whether request and response headers are logged.
  final bool logHeaders;

  /// Whether request bodies are logged.
  final bool logRequestBody;

  /// Whether response bodies (including error responses) are logged.
  final bool logResponseBody;

  final DateTime Function() _clock;
  final Expando<Set<String>> _secrets = Expando('redacted values');
  int _nextId = 0;

  /// The fingerprint that replaces [jwt] in logs: `jwt#` plus six hex digits
  /// of a non-cryptographic hash. It identifies a token without revealing it.
  static String jwtFingerprint(String jwt) =>
      'jwt#${(fnv1a32(jwt) % 0x1000000).toRadixString(16).padLeft(6, '0')}';

  /// Returns a deep copy of a JSON-like [value] with secret keys redacted.
  /// The input is not modified.
  Object? redactJson(Object? value) => _redactJson(value, <String>{});

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final id = ++_nextId;
    try {
      options.extra[_idKey] = id;
      options.extra[_startKey] = _clock();
      final secrets = _secrets[options] = <String>{};
      final b = StringBuffer(
        '--> ${options.method.toUpperCase()} ${_url(options.uri, secrets)} #$id',
      );
      if (logHeaders && options.headers.isNotEmpty) {
        b.write('\n    headers: ${_headers(options.headers, secrets)}');
      }
      if (logRequestBody) {
        final body = _body(options.data, options.contentType, secrets);
        if (body != null) b.write('\n    body: $body');
      }
      _emit(b.toString(), secrets);
    } catch (e) {
      _emitSafe('--> #$id (log formatting failed: ${e.runtimeType})');
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    try {
      final options = response.requestOptions;
      final secrets = _secrets[options] ??= <String>{};
      final b = StringBuffer('<-- ${response.statusCode} ')
        ..write(_summary(options, secrets));
      _describeResponse(b, response, secrets);
      _emit(b.toString(), secrets);
    } catch (e) {
      _emitSafe('<-- #${response.requestOptions.extra[_idKey]} '
          '(log formatting failed: ${e.runtimeType})');
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    try {
      final options = err.requestOptions;
      final secrets = _secrets[options] ??= <String>{};
      // Make sure the request's own secrets are known even if onRequest never
      // ran for this RequestOptions (e.g. the error came from an earlier
      // interceptor).
      _url(options.uri, secrets);
      _headers(options.headers, secrets);
      _body(options.data, options.contentType, secrets);

      final response = err.response;
      final b = StringBuffer('<-x ')
        ..write(response?.statusCode ?? err.type.name)
        ..write(' ')
        ..write(_summary(options, secrets));
      if (response != null) {
        b.write(' ${err.type.name}');
        _describeResponse(b, response, secrets);
      }
      if (err.type != DioExceptionType.badResponse) {
        final message = err.message;
        if (message != null && message.isNotEmpty) {
          b.write('\n    message: ${_scrub(message, secrets)}');
        }
        final cause = err.error;
        if (cause != null) {
          b.write('\n    error: ${cause.runtimeType}: '
              '${_scrub(cause.toString(), secrets)}');
        }
      }
      _emit(b.toString(), secrets);
    } catch (e) {
      _emitSafe('<-x #${err.requestOptions.extra[_idKey]} ${err.type.name} '
          '(log formatting failed: ${e.runtimeType})');
    }
    handler.next(err);
  }

  // ---------------------------------------------------------------- records

  String _summary(RequestOptions options, Set<String> secrets) {
    final b = StringBuffer()
      ..write(options.method.toUpperCase())
      ..write(' ')
      ..write(_url(options.uri, secrets));
    final id = options.extra[_idKey];
    if (id != null) b.write(' #$id');
    final start = options.extra[_startKey];
    if (start is DateTime) {
      b.write(' ${_clock().difference(start).inMilliseconds}ms');
    }
    return b.toString();
  }

  void _describeResponse(
    StringBuffer b,
    Response<dynamic> response,
    Set<String> secrets,
  ) {
    final contentType = response.headers.value(Headers.contentTypeHeader);
    if (_isHtml(contentType, response.data) &&
        _expectsJson(response.requestOptions)) {
      b.write('\n    ! HTML response to a JSON endpoint '
          '(content-type: ${contentType ?? 'none'})');
    }
    if (logHeaders && response.headers.map.isNotEmpty) {
      final flat = {
        for (final e in response.headers.map.entries) e.key: e.value.join(', '),
      };
      b.write('\n    headers: ${_headers(flat, secrets)}');
    }
    if (logResponseBody) {
      final body = _body(response.data, contentType, secrets);
      if (body != null) b.write('\n    body: $body');
    }
  }

  bool _isHtml(String? contentType, Object? data) {
    if (contentType != null && contentType.toLowerCase().contains('html')) {
      return true;
    }
    if (data is String) {
      final head = data.trimLeft().toLowerCase();
      return head.startsWith('<!doctype html') || head.startsWith('<html');
    }
    return false;
  }

  bool _expectsJson(RequestOptions options) {
    if (options.responseType == ResponseType.json) return true;
    for (final e in options.headers.entries) {
      if (e.key.toLowerCase() == 'accept' &&
          '${e.value}'.toLowerCase().contains('json')) {
        return true;
      }
    }
    return false;
  }

  // ------------------------------------------------------------- redaction

  static String _normalize(String name) =>
      name.toLowerCase().replaceAll(RegExp(r'[-_.\s]'), '');

  bool _isSecretKey(Object? name) {
    final n = _normalize('$name');
    if (n.isEmpty) return false;
    if (redactKeys.contains(n)) return true;
    for (final fragment in redactKeyFragments) {
      if (n.contains(fragment)) return true;
    }
    return false;
  }

  /// Replacement for a secret [value], remembering it for free-text scrubbing.
  String _mask(Object? value, Set<String> secrets) {
    _remember(value, secrets);
    if (value is String) {
      final jwt = _jwt.firstMatch(value);
      if (jwt != null) return '[REDACTED ${jwtFingerprint(jwt[0]!)}]';
    }
    return redacted;
  }

  void _remember(Object? value, Set<String> secrets) {
    if (value is String) {
      final v = value.trim();
      if (v.length >= 4) secrets.add(v);
      // "Bearer abc" -> also remember "abc".
      final space = v.lastIndexOf(' ');
      if (space > 0 && v.length - space > 4) {
        secrets.add(v.substring(space + 1));
      }
    } else if (value is Map) {
      for (final v in value.values) {
        _remember(v, secrets);
      }
    } else if (value is Iterable) {
      for (final v in value) {
        _remember(v, secrets);
      }
    } else if (value is num) {
      _remember('$value', secrets);
    }
  }

  Object? _redactJson(Object? value, Set<String> secrets) {
    if (value is Map) {
      return <String, Object?>{
        for (final e in value.entries)
          '${e.key}': _isSecretKey(e.key)
              ? _mask(e.value, secrets)
              : _redactJson(e.value, secrets),
      };
    }
    if (value is List) {
      return [for (final v in value) _redactJson(v, secrets)];
    }
    return value;
  }

  String _headers(Map<String, dynamic> headers, Set<String> secrets) {
    return headers.entries.map((e) {
      final value = e.value is List ? (e.value as List).join(', ') : e.value;
      return '${e.key}: ${_isSecretKey(e.key) ? _mask('$value', secrets) : value}';
    }).join(', ');
  }

  String _url(Uri uri, Set<String> secrets) {
    final b = StringBuffer();
    if (uri.hasScheme) b.write('${uri.scheme}:');
    if (uri.hasAuthority) {
      b.write('//');
      if (uri.userInfo.isNotEmpty) {
        _remember(uri.userInfo, secrets);
        for (final part in uri.userInfo.split(':')) {
          _remember(part, secrets);
        }
        b.write('$redacted@');
      }
      b.write(uri.host);
      if (uri.hasPort) b.write(':${uri.port}');
    }
    b.write(uri.path);
    if (uri.hasQuery) {
      final parts = <String>[];
      uri.queryParametersAll.forEach((key, values) {
        for (final v in values) {
          parts.add(_isSecretKey(key)
              ? '${Uri.encodeQueryComponent(key)}=${_mask(v, secrets)}'
              : '${Uri.encodeQueryComponent(key)}='
                  '${Uri.encodeQueryComponent(v)}');
        }
      });
      b.write('?${parts.join('&')}');
    }
    return b.toString();
  }

  /// Describes a body, redacted and truncated, or `null` when there is none.
  String? _body(Object? data, String? contentType, Set<String> secrets) {
    if (data == null) return null;
    final String text;
    if (data is FormData) {
      final fields = [
        for (final f in data.fields)
          '${f.key}: ${_isSecretKey(f.key) ? _mask(f.value, secrets) : f.value}',
        for (final f in data.files)
          '${f.key}: <file ${f.value.filename ?? ''} (${f.value.length} bytes)>',
      ];
      text = 'form-data {${fields.join(', ')}}';
    } else if (data is Uint8List || data is List<int>) {
      text = '<${(data as List<int>).length} bytes>';
    } else if (data is Stream || data is ResponseBody) {
      text = '<stream>';
    } else if (data is String) {
      text = _stringBody(data, contentType, secrets);
    } else if (data is Map || data is List) {
      text = _encode(_redactJson(data, secrets));
    } else {
      // An object with toJson(); anything else is shown by type only, since
      // an arbitrary toString() cannot be redacted structurally.
      try {
        text = _encode(_redactJson(jsonDecode(jsonEncode(data)), secrets));
      } catch (_) {
        return '<${data.runtimeType}>';
      }
    }
    return _truncate(_scrub(text, secrets));
  }

  String _stringBody(String data, String? contentType, Set<String> secrets) {
    final trimmed = data.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return _encode(_redactJson(jsonDecode(trimmed), secrets));
      } on FormatException {
        // Not JSON after all; fall through to text handling.
      }
    }
    final isForm = (contentType ?? '').contains('x-www-form-urlencoded') ||
        _formBody.hasMatch(trimmed);
    if (isForm && trimmed.contains('=')) {
      return trimmed.split('&').map((pair) {
        final eq = pair.indexOf('=');
        if (eq < 0) return pair;
        final key = pair.substring(0, eq);
        final value = pair.substring(eq + 1);
        if (!_isSecretKey(Uri.decodeQueryComponent(key))) return pair;
        _remember(Uri.decodeQueryComponent(value), secrets);
        return '$key=${_mask(value, secrets)}';
      }).join('&');
    }
    return data;
  }

  static String _encode(Object? json) =>
      jsonEncode(json, toEncodable: (o) => '<${o.runtimeType}>');

  String _truncate(String text) {
    if (text.length <= maxBodyChars) return text;
    return '${text.substring(0, maxBodyChars)}... '
        '[truncated ${text.length - maxBodyChars} chars]';
  }

  /// Removes secrets from free text: JWTs, auth-scheme credentials, secret
  /// `name=value` and `"name":"value"` pairs, and every value already
  /// redacted for this request.
  String _scrub(String text, Set<String> secrets) {
    // JWTs first, so a known token still shows up as its fingerprint.
    var out = text.replaceAllMapped(_jwt, (m) => jwtFingerprint(m[0]!));
    // Longest first, so a value that contains another is removed whole.
    final known = secrets.toList()..sort((a, b) => b.length - a.length);
    for (final s in known) {
      if (s == redacted) continue;
      out = out.replaceAll(s, redacted);
    }
    out = out.replaceAllMapped(_authScheme, (m) {
      if (m[2]!.startsWith('[')) return m[0]!;
      return '${m[1]} $redacted';
    });
    out = out.replaceAllMapped(_pair, (m) {
      if (!_isSecretKey(m[1]) || m[2]!.startsWith('[')) return m[0]!;
      return '${m[1]}=$redacted';
    });
    out = out.replaceAllMapped(_jsonPair, (m) {
      if (!_isSecretKey(m[1]) || m[2]!.startsWith('[')) return m[0]!;
      return '"${m[1]}":"$redacted"';
    });
    return out;
  }

  void _emit(String record, Set<String> secrets) {
    _emitSafe(_scrub(record, secrets));
  }

  void _emitSafe(String record) {
    try {
      sink(record);
    } catch (_) {
      // Logging must never break the request.
    }
  }
}
