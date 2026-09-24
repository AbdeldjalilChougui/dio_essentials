import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';

import 'http_date.dart';

/// Details of one retry, passed to [RetryInterceptor.onRetry].
class RetryEvent {
  /// Creates a retry event.
  const RetryEvent({
    required this.error,
    required this.attempt,
    required this.delay,
    required this.fromRetryAfter,
  });

  /// The error that triggered the retry.
  final DioException error;

  /// The retry number, starting at 1 for the first retry.
  final int attempt;

  /// How long the interceptor waits before sending the retry.
  final Duration delay;

  /// Whether [delay] came from a `Retry-After` response header.
  final bool fromRetryAfter;

  @override
  String toString() =>
      'RetryEvent(attempt: $attempt, delay: $delay, retryAfter: $fromRetryAfter)';
}

/// Retries failed requests with exponential backoff and full jitter.
///
/// Safe by default:
///
/// * Only [defaultIdempotentMethods] are retried. `POST` and `PATCH` (or any
///   other method) are retried only when the request carries an
///   `Idempotency-Key` header or sets `extra[RetryInterceptor.retryExtraKey]`
///   to `true`.
/// * Only transient failures are retried (see [isTransientError]); pass
///   [retryIf] to change that.
/// * A cancelled request is never retried, and cancelling during the backoff
///   wait aborts immediately.
/// * Bodies that cannot be sent twice ([Stream] and [FormData]) are never
///   retried.
/// * A `Retry-After` header (seconds or HTTP-date) overrides the backoff.
///
/// The delay before retry *n* (starting at 0) is a uniformly random value in
/// `[0, min(maxDelay, baseDelay * 2^n))`, the "full jitter" strategy.
///
/// The interceptor replays through [dio], which must be the instance it is
/// attached to, so that other interceptors (auth, logging) see the retry.
class RetryInterceptor extends Interceptor {
  /// Creates a retry interceptor that replays through [dio].
  ///
  /// [maxAttempts] counts every attempt including the first, so the default
  /// of 3 means at most 2 retries. [clock], [sleep] and [random] exist so
  /// tests can be deterministic.
  RetryInterceptor({
    required this.dio,
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 30),
    this.maxRetryAfter = const Duration(minutes: 2),
    this.idempotentMethods = defaultIdempotentMethods,
    this.retryIf = isTransientError,
    this.onRetry,
    DateTime Function()? clock,
    Future<void> Function(Duration delay)? sleep,
    Random? random,
  })  : assert(maxAttempts >= 1, 'maxAttempts must be at least 1'),
        _clock = clock ?? DateTime.now,
        _sleep = sleep ?? _defaultSleep,
        _random = random ?? Random();

  /// Methods that are retried without any opt-in.
  static const Set<String> defaultIdempotentMethods = {
    'GET',
    'HEAD',
    'OPTIONS',
    'PUT',
    'DELETE',
  };

  /// HTTP status codes that [isTransientError] treats as retryable.
  static const Set<int> retryableStatusCodes = {408, 429, 502, 503, 504};

  /// `RequestOptions.extra` key: `true` allows retrying a non-idempotent
  /// method for this request, `false` disables retrying it entirely.
  static const String retryExtraKey = 'dio_essentials.retry';

  /// `RequestOptions.extra` key holding the 1-based attempt number of a
  /// replayed request. Set by the interceptor; do not set it yourself.
  static const String attemptExtraKey = 'dio_essentials.retry.attempt';

  /// The Dio instance this interceptor is attached to, used for replays.
  final Dio dio;

  /// Total attempts including the first one.
  final int maxAttempts;

  /// The backoff ceiling for the first retry; it doubles on each retry.
  final Duration baseDelay;

  /// The largest backoff ceiling, before jitter.
  final Duration maxDelay;

  /// The longest `Retry-After` the interceptor will wait. A longer one makes
  /// it give up and surface the error instead.
  final Duration maxRetryAfter;

  /// Methods retried without an idempotency key or explicit opt-in.
  /// Compared case-insensitively; keep the entries upper-case.
  final Set<String> idempotentMethods;

  /// Decides whether an error is worth retrying. Method, body and
  /// cancellation checks still apply on top of it.
  final bool Function(DioException error) retryIf;

  /// Called before each retry, for logging or metrics.
  final void Function(RetryEvent event)? onRetry;

  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;
  final Random _random;

  static Future<void> _defaultSleep(Duration d) => Future<void>.delayed(d);

  /// The default retry classification: connection errors, connect/send/receive
  /// timeouts, and responses with a status in [retryableStatusCodes].
  static bool isTransientError(DioException error) {
    // Not an exhaustive switch: newer dio versions add exception types, and
    // an unknown type must default to "do not retry".
    final type = error.type;
    if (type == DioExceptionType.connectionError ||
        type == DioExceptionType.connectionTimeout ||
        type == DioExceptionType.sendTimeout ||
        type == DioExceptionType.receiveTimeout) {
      return true;
    }
    if (type == DioExceptionType.badResponse) {
      return retryableStatusCodes.contains(error.response?.statusCode);
    }
    return false;
  }

  /// Parses a `Retry-After` header value into a delay measured from [now].
  ///
  /// Accepts delay-seconds (`"120"`) and the three HTTP-date formats of
  /// RFC 9110 section 5.6.7. A date in the past yields [Duration.zero].
  /// Returns `null` for anything else.
  static Duration? parseRetryAfter(String value, DateTime now) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    if (RegExp(r'^\d+$').hasMatch(trimmed)) {
      final seconds = int.tryParse(trimmed);
      return seconds == null ? null : Duration(seconds: seconds);
    }
    final date = parseHttpDate(trimmed);
    if (date == null) return null;
    final delta = date.difference(now);
    return delta.isNegative ? Duration.zero : delta;
  }

  /// Formats [time] as an IMF-fixdate, e.g. `Sun, 06 Nov 1994 08:49:37 GMT`.
  static String formatHttpDate(DateTime time) => formatImfFixdate(time);

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final attempt = (options.extra[attemptExtraKey] as int?) ?? 1;

    if (attempt >= maxAttempts || !_mayRetry(err)) {
      return handler.next(err);
    }

    var delay = _backoff(attempt - 1);
    var fromRetryAfter = false;
    final header = err.response?.headers.value('retry-after');
    if (header != null) {
      final retryAfter = parseRetryAfter(header, _clock());
      if (retryAfter != null) {
        if (retryAfter > maxRetryAfter) return handler.next(err);
        delay = retryAfter;
        fromRetryAfter = true;
      }
    }

    onRetry?.call(RetryEvent(
      error: err,
      attempt: attempt,
      delay: delay,
      fromRetryAfter: fromRetryAfter,
    ));

    final cancelToken = options.cancelToken;
    if (cancelToken != null) {
      final cancelled = await Future.any([
        _sleep(delay).then((_) => false),
        cancelToken.whenCancel.then((_) => true),
      ]);
      if (cancelled || cancelToken.isCancelled) {
        return handler.next(
          cancelToken.cancelError ??
              DioException.requestCancelled(
                requestOptions: options,
                reason: 'cancelled during retry backoff',
              ),
        );
      }
    } else {
      await _sleep(delay);
    }

    final replay = options.copyWith(
      extra: {...options.extra, attemptExtraKey: attempt + 1},
    );
    try {
      final response = await dio.fetch<dynamic>(replay);
      handler.resolve(response);
    } on DioException catch (e) {
      // The replay went through this interceptor again, which already made
      // any further retries; just surface its final outcome.
      handler.next(e);
    }
  }

  bool _mayRetry(DioException err) {
    final options = err.requestOptions;
    if (err.type == DioExceptionType.cancel) return false;
    if (options.cancelToken?.isCancelled ?? false) return false;

    final optIn = options.extra[retryExtraKey];
    if (optIn == false) return false;

    final data = options.data;
    if (data is Stream || data is FormData) return false;

    final method = options.method.toUpperCase();
    final methodAllowed = idempotentMethods.contains(method) ||
        optIn == true ||
        _hasIdempotencyKey(options.headers);
    if (!methodAllowed) return false;

    return retryIf(err);
  }

  static bool _hasIdempotencyKey(Map<String, dynamic> headers) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'idempotency-key' &&
          entry.value != null &&
          entry.value.toString().isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  Duration _backoff(int retryIndex) {
    final base = baseDelay.inMicroseconds.toDouble();
    final cap = maxDelay.inMicroseconds.toDouble();
    // Clamp the exponent so pow() cannot overflow to infinity.
    final ceiling = min(cap, base * pow(2, min(retryIndex, 62)));
    return Duration(microseconds: (ceiling * _random.nextDouble()).floor());
  }
}
