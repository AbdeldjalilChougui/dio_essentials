import 'dart:async';

import 'package:dio/dio.dart';

import 'jwt_claims.dart';

/// The `error` of the [DioException] a caller receives when the session could
/// not be refreshed (the refresh callback threw or returned `null`).
class SessionExpiredException implements Exception {
  /// Creates the exception, optionally carrying what the refresh threw.
  const SessionExpiredException([this.cause]);

  /// What the refresh callback threw, if it threw.
  final Object? cause;

  @override
  String toString() => 'SessionExpiredException: the session could not be '
      'refreshed${cause == null ? '' : ' (${cause.runtimeType})'}';
}

/// Attaches an access token to requests and transparently refreshes it.
///
/// * [tokenProvider] is asked for the current token before every request.
/// * On a `401` for a request that carried a token, exactly one call to
///   [refreshToken] runs, however many requests fail concurrently. The others
///   wait for it, then every one is replayed once with the new token. A `401`
///   that arrives after a refresh already produced a newer token is replayed
///   with that token without refreshing again.
/// * If the refresh throws or returns `null`, every waiter fails with its
///   original `401` whose [DioException.error] is a [SessionExpiredException],
///   and [onSessionExpired] fires once for that refresh.
/// * With [proactiveLeeway], a JWT whose `exp` claim is within the leeway is
///   refreshed *before* the request is sent. The claim is read with
///   [JwtClaims.decodeUnverified], which does not verify the signature; that
///   is fine for a client-side timing hint.
///
/// **No loops.** Requests to [skipPaths], requests with
/// `extra[AuthRefreshInterceptor.skipExtraKey] == true`, and every request
/// made *while [refreshToken] runs* (tracked with a [Zone] value, so a refresh
/// that calls the same [Dio] is safe even without marking) bypass the
/// interceptor. A replayed request that fails with `401` again is not
/// refreshed a second time.
///
/// [refreshToken] must persist the new token so that [tokenProvider] returns
/// it afterwards; the interceptor also uses its return value for the replay.
class AuthRefreshInterceptor extends Interceptor {
  /// Creates the interceptor. [dio] must be the instance it is attached to;
  /// it is used to replay requests after a refresh.
  AuthRefreshInterceptor({
    required this.dio,
    required this.tokenProvider,
    required this.refreshToken,
    this.onSessionExpired,
    this.skipPaths = const [],
    this.skipWhen,
    this.proactiveLeeway,
    this.headerName = 'Authorization',
    this.formatHeader = bearer,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// `RequestOptions.extra` key: `true` makes the interceptor ignore the
  /// request entirely (no token, no refresh).
  static const String skipExtraKey = 'dio_essentials.auth.skip';

  static const String _replayKey = 'dio_essentials.auth.replay';
  static const String _tokenKey = 'dio_essentials.auth.token';
  static final Object _zoneKey = Object();

  /// Formats a token as `Bearer <token>`.
  static String bearer(String token) => 'Bearer $token';

  /// The Dio instance this interceptor is attached to.
  final Dio dio;

  /// Returns the current access token, or `null` when signed out.
  final Future<String?> Function() tokenProvider;

  /// Obtains and persists a new access token, returning it. Return `null` or
  /// throw when the session cannot be renewed.
  final Future<String?> Function() refreshToken;

  /// Called once each time a refresh fails.
  final void Function()? onSessionExpired;

  /// Paths that never get a token or a refresh, such as login and refresh
  /// endpoints. An entry matches the request path exactly, or as a prefix
  /// when it ends with `*` (`'/auth/*'`). Both the path passed to Dio and the
  /// resolved URI path are checked.
  final List<String> skipPaths;

  /// An extra predicate for requests to leave alone.
  final bool Function(RequestOptions options)? skipWhen;

  /// When set, a JWT expiring within this window is refreshed before sending.
  final Duration? proactiveLeeway;

  /// The header that carries the token.
  final String headerName;

  /// Turns a token into the header value. Defaults to [bearer].
  final String Function(String token) formatHeader;

  final DateTime Function() _clock;
  Future<_Outcome>? _inflight;

  /// Whether a refresh is currently running.
  bool get isRefreshing => _inflight != null;

  bool _skips(RequestOptions options) {
    if (options.extra[skipExtraKey] == true) return true;
    if (identical(Zone.current[_zoneKey], this)) return true;
    if (skipWhen?.call(options) ?? false) return true;
    final paths = {options.path, options.uri.path};
    for (final pattern in skipPaths) {
      if (pattern.endsWith('*')) {
        final prefix = pattern.substring(0, pattern.length - 1);
        if (paths.any((p) => p.startsWith(prefix))) return true;
      } else if (paths.contains(pattern)) {
        return true;
      }
    }
    return false;
  }

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (_skips(options)) return handler.next(options);
    try {
      var token = options.extra[_replayKey] == true
          ? options.extra[_tokenKey] as String?
          : await tokenProvider();

      final leeway = proactiveLeeway;
      if (token != null &&
          leeway != null &&
          options.extra[_replayKey] != true &&
          (JwtClaims.tryDecodeUnverified(token)
                  ?.expiresWithin(leeway, now: _clock()) ??
              false)) {
        final outcome = await _refresh();
        if (outcome.token == null) {
          return handler.reject(DioException(
            requestOptions: options,
            error: SessionExpiredException(outcome.error),
            message: 'Session expired: proactive token refresh failed.',
          ));
        }
        token = outcome.token;
      }

      if (token != null) {
        options.headers[headerName] = formatHeader(token);
      }
      options.extra[_tokenKey] = token;
      handler.next(options);
    } catch (e, st) {
      handler.reject(DioException(
        requestOptions: options,
        error: e,
        stackTrace: st,
        message: 'Could not obtain an access token.',
      ));
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final used = options.extra[_tokenKey] as String?;
    if (err.response?.statusCode != 401 ||
        used == null ||
        options.extra[_replayKey] == true ||
        _skips(options)) {
      return handler.next(err);
    }

    String? fresh;
    Object? failure;
    if (_inflight == null) {
      String? current;
      try {
        current = await tokenProvider();
      } catch (_) {
        current = null;
      }
      if (current != null && current != used && _inflight == null) {
        // Another request already refreshed after this one was sent.
        fresh = current;
      }
    }
    if (fresh == null) {
      final outcome = await _refresh();
      fresh = outcome.token;
      failure = outcome.error;
    }
    if (fresh == null) {
      return handler.next(
        err.copyWith(error: SessionExpiredException(failure)),
      );
    }

    final replay = options.copyWith(
      headers: {...options.headers, headerName: formatHeader(fresh)},
      extra: {...options.extra, _replayKey: true, _tokenKey: fresh},
    );
    try {
      handler.resolve(await dio.fetch<dynamic>(replay));
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  /// Runs [refreshToken] unless a refresh is already running, in which case
  /// the caller joins it.
  Future<_Outcome> _refresh() {
    final running = _inflight;
    if (running != null) return running;
    final completer = Completer<_Outcome>();
    // Publish before starting, so even a synchronous failure is shared.
    _inflight = completer.future;
    _runRefresh().then(completer.complete).whenComplete(() {
      _inflight = null;
    });
    return completer.future;
  }

  Future<_Outcome> _runRefresh() async {
    try {
      final token = await runZoned(
        refreshToken,
        zoneValues: {_zoneKey: this},
      );
      if (token == null || token.isEmpty) {
        _expire();
        return const _Outcome(null, null);
      }
      return _Outcome(token, null);
    } catch (e) {
      _expire();
      return _Outcome(null, e);
    }
  }

  void _expire() {
    try {
      onSessionExpired?.call();
    } catch (_) {
      // A throwing callback must not strand the requests waiting on us.
    }
  }
}

class _Outcome {
  const _Outcome(this.token, this.error);
  final String? token;
  final Object? error;
}
