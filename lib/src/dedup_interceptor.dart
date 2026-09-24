import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'hashing.dart';

/// Builds the identity of a request for [DedupInterceptor]. Two requests with
/// the same key are considered identical. Return `null` to exclude a request
/// from deduplication and caching.
typedef DedupKeyBuilder = String? Function(RequestOptions options);

/// Merges identical in-flight requests into one network call, and optionally
/// caches `GET`/`HEAD` responses for a short time.
///
/// **In-flight coalescing.** While a request is in flight, identical requests
/// wait for it instead of hitting the network. Every waiter receives its own
/// [Response] (bound to its own [RequestOptions], with a deep copy of
/// JSON-like data), or the same failure. By default only `GET` and `HEAD` are
/// coalesced; any other method can opt in per request with
/// `extra: {DedupInterceptor.extraKey: true}`, which is useful to collapse a
/// double-tapped "save" into one call. A request can opt out with `false`.
///
/// **Cancellation.** The shared call does not use any caller's
/// [CancelToken]. Cancelling one waiter only detaches that waiter; the shared
/// call is cancelled only when every waiter has cancelled.
///
/// **Short-lived cache.** With a non-zero [cacheTtl], successful (2xx) `GET`
/// and `HEAD` responses are replayed for that long. Writes are never cached
/// or replayed, and with [invalidateOnWrite] any other method clears the
/// cache. A cache hit does not extend the entry's lifetime.
///
/// **Identity.** See [defaultKey]. Requests whose body cannot be hashed
/// (`FormData`, streams, arbitrary objects) and requests expecting a
/// [ResponseType.stream] body are never coalesced or cached.
///
/// **Ordering.** The shared call is issued with [dio] and passes through the
/// whole interceptor chain again, so add this interceptor *first*: the
/// interceptors after it then see exactly one request per merged group.
class DedupInterceptor extends Interceptor {
  /// Creates a deduplicating interceptor that issues shared calls with [dio],
  /// the instance it is attached to.
  DedupInterceptor({
    required this.dio,
    this.cacheTtl = Duration.zero,
    this.coalescedMethods = const {'GET', 'HEAD'},
    this.keyHeaders = defaultKeyHeaders,
    DedupKeyBuilder? keyBuilder,
    this.invalidateOnWrite = true,
    this.maxCacheEntries = 256,
    DateTime Function()? clock,
  })  : _keyBuilder = keyBuilder,
        _clock = clock ?? DateTime.now;

  /// Header names (lower-case) that [defaultKey] includes in the key.
  static const List<String> defaultKeyHeaders = [
    'authorization',
    'cookie',
    'accept',
    'accept-language',
  ];

  /// `RequestOptions.extra` key: `true` coalesces this request even if its
  /// method is not in [coalescedMethods]; `false` bypasses the interceptor.
  static const String extraKey = 'dio_essentials.dedup';

  static const String _sharedKey = 'dio_essentials.dedup.shared';
  static const Set<String> _cacheableMethods = {'GET', 'HEAD'};

  /// The Dio instance this interceptor is attached to.
  final Dio dio;

  /// How long successful `GET`/`HEAD` responses are replayed.
  /// [Duration.zero] (the default) disables caching.
  final Duration cacheTtl;

  /// Methods coalesced without a per-request opt-in. Upper-case.
  final Set<String> coalescedMethods;

  /// Header names included in the key by the default key builder.
  final List<String> keyHeaders;

  /// Whether a request with a method other than `GET`/`HEAD` clears the cache.
  final bool invalidateOnWrite;

  /// Upper bound on cached responses; the oldest entry is evicted first.
  final int maxCacheEntries;

  final DedupKeyBuilder? _keyBuilder;
  final DateTime Function() _clock;

  final Map<String, _Flight> _flights = {};
  final LinkedHashMap<String, _CacheEntry> _cache = LinkedHashMap();
  int _generation = 0;

  /// Number of distinct requests currently in flight through the interceptor.
  int get inFlightCount => _flights.length;

  /// Drops every cached response. In-flight requests are unaffected, but
  /// their responses will not be cached.
  void clearCache() {
    _cache.clear();
    _generation++;
  }

  /// The default request identity: method, full URI (query parameters
  /// sorted), the values of [headers] (matched case-insensitively), and a
  /// fingerprint of the body.
  ///
  /// Returns `null` when the body is not hashable (`FormData`, a stream, or
  /// anything that is not JSON-encodable), so such requests are never merged.
  static String? defaultKey(
    RequestOptions options, [
    List<String> headers = defaultKeyHeaders,
  ]) {
    final body = _bodyFingerprint(options.data);
    if (body == null) return null;
    final buffer = StringBuffer()
      ..write(options.method.toUpperCase())
      ..write(' ')
      ..write(_canonicalUri(options.uri));
    final lower = <String, Object?>{
      for (final e in options.headers.entries) e.key.toLowerCase(): e.value,
    };
    for (final name in headers) {
      final value = lower[name.toLowerCase()];
      if (value != null) buffer.write('\n$name: ${fingerprint('$value')}');
    }
    buffer.write('\nbody: $body');
    return buffer.toString();
  }

  static String _canonicalUri(Uri uri) {
    if (!uri.hasQuery) return uri.toString();
    final params = uri.queryParametersAll.entries
        .expand((e) => e.value.map((v) => '${e.key}=$v'))
        .toList()
      ..sort();
    return '${uri.replace(query: '')}${params.join('&')}';
  }

  static String? _bodyFingerprint(Object? data) {
    if (data == null) return '-';
    if (data is String) return fingerprint(data);
    if (data is Map || data is List) {
      try {
        return fingerprint(jsonEncode(data));
      } on Object {
        return null;
      }
    }
    if (data is num || data is bool) return fingerprint('$data');
    return null;
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.extra[_sharedKey] == true) return handler.next(options);

    final method = options.method.toUpperCase();
    final optIn = options.extra[extraKey];
    if (!_cacheableMethods.contains(method) && invalidateOnWrite) {
      clearCache();
    }
    if (optIn == false || options.responseType == ResponseType.stream) {
      return handler.next(options);
    }
    if (optIn != true && !coalescedMethods.contains(method)) {
      return handler.next(options);
    }

    final key = _keyBuilder != null
        ? _keyBuilder(options)
        : defaultKey(options, keyHeaders);
    if (key == null) return handler.next(options);

    final cacheable =
        _cacheableMethods.contains(method) && cacheTtl > Duration.zero;
    if (cacheable) {
      final hit = _cache[key];
      if (hit != null) {
        if (_clock().isBefore(hit.expiresAt)) {
          return handler.resolve(_responseFor(hit.response, options));
        }
        _cache.remove(key);
      }
    }

    final flight = _flights[key] ?? _startFlight(key, options, cacheable);
    _join(flight, key, options, handler);
  }

  @override
  void onResponse(
      Response<dynamic> response, ResponseInterceptorHandler handler) {
    final method = response.requestOptions.method.toUpperCase();
    if (!_cacheableMethods.contains(method) && invalidateOnWrite) {
      clearCache();
    }
    handler.next(response);
  }

  _Flight _startFlight(String key, RequestOptions options, bool cacheable) {
    final flight = _Flight(CancelToken());
    _flights[key] = flight;
    final generation = _generation;
    final shared = options.copyWith(
      cancelToken: flight.cancelToken,
      extra: {...options.extra, _sharedKey: true},
    );
    flight.future = dio.fetch<dynamic>(shared).then((response) {
      final status = response.statusCode ?? 0;
      if (cacheable &&
          generation == _generation &&
          status >= 200 &&
          status < 300) {
        _store(key, response);
      }
      return response;
    }).whenComplete(() {
      if (identical(_flights[key], flight)) _flights.remove(key);
    });
    // Waiters may all have cancelled; the outcome must never go unhandled.
    flight.future.ignore();
    return flight;
  }

  void _join(
    _Flight flight,
    String key,
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    flight.waiters++;
    var settled = false;

    void leave() {
      if (settled) return;
      settled = true;
      flight.waiters--;
    }

    options.cancelToken?.whenCancel.then((_) {
      if (settled) return;
      leave();
      if (flight.waiters == 0) {
        if (identical(_flights[key], flight)) _flights.remove(key);
        flight.cancelToken.cancel('every deduplicated waiter cancelled');
      }
    });

    flight.future.then(
      (response) {
        if (settled) return;
        leave();
        handler.resolve(_responseFor(response, options));
      },
      onError: (Object error, StackTrace stack) {
        if (settled) return;
        leave();
        handler.reject(
          error is DioException
              ? error.copyWith(requestOptions: options)
              : DioException(
                  requestOptions: options,
                  error: error,
                  stackTrace: stack,
                ),
        );
      },
    );
  }

  void _store(String key, Response<dynamic> response) {
    final now = _clock();
    _cache.removeWhere((_, entry) => !now.isBefore(entry.expiresAt));
    _cache.remove(key);
    while (_cache.length >= maxCacheEntries && _cache.isNotEmpty) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = _CacheEntry(response, now.add(cacheTtl));
  }

  static Response<dynamic> _responseFor(
    Response<dynamic> source,
    RequestOptions options,
  ) {
    return Response<dynamic>(
      data: _copy(source.data),
      headers: source.headers,
      requestOptions: options,
      statusCode: source.statusCode,
      statusMessage: source.statusMessage,
      isRedirect: source.isRedirect,
      redirects: source.redirects,
      extra: Map.of(source.extra),
    );
  }

  /// Deep-copies JSON-like data so waiters and cache hits cannot see each
  /// other's mutations. Preserves the runtime types Dio produces.
  static Object? _copy(Object? value) {
    if (value is Map<String, dynamic>) {
      return <String, dynamic>{
        for (final e in value.entries) e.key: _copy(e.value),
      };
    }
    if (value is Map) {
      return {for (final e in value.entries) e.key: _copy(e.value)};
    }
    if (value is Uint8List) return Uint8List.fromList(value);
    if (value is List<int>) return List<int>.of(value);
    if (value is List<String>) return List<String>.of(value);
    if (value is List) return value.map(_copy).toList();
    return value;
  }
}

class _Flight {
  _Flight(this.cancelToken);
  final CancelToken cancelToken;
  late final Future<Response<dynamic>> future;
  int waiters = 0;
}

class _CacheEntry {
  _CacheEntry(this.response, this.expiresAt);
  final Response<dynamic> response;
  final DateTime expiresAt;
}
