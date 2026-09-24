# dio_essentials

Four production-grade [Dio](https://pub.dev/packages/dio) interceptors that
are often missing or subtly broken: request deduplication, safe retries,
single-flight token refresh, and a logger that cannot leak secrets.

[![pub package](https://img.shields.io/pub/v/dio_essentials.svg)](https://pub.dev/packages/dio_essentials)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Features

- **`DedupInterceptor`**
  - Merges identical in-flight requests into one network call. The key is
    the method, the URI (query order ignored), selected headers and a body
    hash. You can supply your own key builder.
  - Optional short-lived cache for `GET`/`HEAD` (configurable TTL). Writes
    are never cached or replayed, and a write clears the cache.
  - Cancelling one waiter never cancels the others. The shared call is
    cancelled only when every waiter has cancelled.
- **`RetryInterceptor`**
  - Real exponential backoff with full jitter: `random(0, min(cap, base * 2^n))`.
    You configure the base, the cap and the maximum number of attempts.
  - Honours `Retry-After` in both the seconds form and the HTTP-date form
    (all three RFC 9110 date formats).
  - Retries `GET`, `HEAD`, `OPTIONS`, `PUT` and `DELETE` only. `POST` and
    `PATCH` are retried only when the request has an `Idempotency-Key`
    header or opts in explicitly.
  - Retries connection errors, timeouts, and the statuses 408, 429, 502, 503
    and 504. A custom predicate can change this.
  - Never retries a cancelled request, or a `Stream` or `FormData` body.
  - The clock, sleep and random source can be injected for deterministic
    tests.
- **`AuthRefreshInterceptor`**
  - Attaches a token from an async provider.
  - On a `401`, runs exactly one refresh while concurrent requests wait for
    it, then replays each of them once with the new token.
  - If the refresh fails, every waiter fails with a `SessionExpiredException`,
    and `onSessionExpired` fires once.
  - Skip paths such as `'/auth/*'`, plus an optional proactive refresh when
    the JWT `exp` is within a leeway.
  - Cannot loop: any request made *inside* the refresh callback bypasses the
    interceptor, even on the same `Dio` instance.
- **`RedactingLogInterceptor`**
  - A compact, one-record-per-event logger with a pluggable sink.
  - Redacts headers, query parameters, form fields and nested JSON keys
    (`authorization`, `cookie`, `set-cookie`, `password`, `token`, `access`,
    `refresh`, `secret`, `api_key`, and more). Matching ignores case and
    separators.
  - Replaces any JWT-shaped string with a fingerprint such as `jwt#a1b2c3`.
  - Truncates large bodies and flags HTML responses to JSON endpoints.
  - Error records are scrubbed too, including the exception's text.
- **`JwtClaims.decodeUnverified`**: reads JWT claims (`exp`, `sub`, and so
  on) for client-side hints. It does **not** verify the signature.

Pure Dart. The only dependency is `dio`, and it works on the VM, Flutter
and the web.

## Install

```sh
dart pub add dio_essentials
```

## Usage

```dart
import 'package:dio/dio.dart';
import 'package:dio_essentials/dio_essentials.dart';

Dio buildClient(TokenStore store, void Function() goToLogin) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));

  dio.interceptors.addAll([
    // 1. Dedup first: everything after it sees one request per merged group.
    DedupInterceptor(dio: dio, cacheTtl: const Duration(seconds: 3)),

    // 2. The logger next, so it also logs the 401s and 503s that the
    //    interceptors below recover from.
    RedactingLogInterceptor(sink: print, maxBodyChars: 1500),

    // 3. Auth.
    AuthRefreshInterceptor(
      dio: dio,
      tokenProvider: store.readAccess,
      refreshToken: () async {
        // Requests made in here bypass the interceptor automatically.
        final res = await dio.post<Map<String, dynamic>>(
          '/auth/refresh',
          data: {'refresh': await store.readRefresh()},
        );
        final access = res.data!['access'] as String;
        await store.writeAccess(access);
        return access;
      },
      onSessionExpired: goToLogin,
      skipPaths: const ['/auth/*'],
      proactiveLeeway: const Duration(seconds: 30),
    ),

    // 4. Retry.
    RetryInterceptor(
      dio: dio,
      maxAttempts: 4,
      baseDelay: const Duration(milliseconds: 300),
      maxDelay: const Duration(seconds: 10),
    ),
  ]);
  return dio;
}

abstract class TokenStore {
  Future<String?> readAccess();
  Future<String?> readRefresh();
  Future<void> writeAccess(String token);
}
```

Per-request switches, set through `Options(extra: {...})`:

| Key | Effect |
| --- | --- |
| `DedupInterceptor.extraKey: true` | Merge this request even though its method (for example `POST`) is not merged by default. It is still never cached. |
| `DedupInterceptor.extraKey: false` | Skip deduplication and caching. |
| `RetryInterceptor.retryExtraKey: true` | Allow retrying a non-idempotent method. |
| `RetryInterceptor.retryExtraKey: false` | Never retry this request. |
| `AuthRefreshInterceptor.skipExtraKey: true` | No token and no refresh. |

A safely retryable `POST`:

```dart
await dio.post<void>(
  '/payments',
  data: {'amount': 1200},
  options: Options(headers: {'Idempotency-Key': paymentId}),
);
```

Reading claims, for hints only:

```dart
final claims = JwtClaims.tryDecodeUnverified(token); // no signature check!
if (claims?.expiresWithin(const Duration(minutes: 1)) ?? false) {
  // Refresh soon.
}
```

`example/main.dart` is a runnable, offline tour
(`dart run example/main.dart`).

### Interceptor order

Dio runs request, response and error handlers in the order the interceptors
were added. When an interceptor recovers from an error, the error handlers
after it never see that error.

- **`DedupInterceptor` goes first.** The shared call re-enters the chain, so
  any interceptor before it would run twice for the first caller.
- **Put `RedactingLogInterceptor` before auth and retry** to log every attempt,
  including recovered failures. The trade-off is that the request line does
  not show headers added later, such as `Authorization`. If you put it last,
  you see the final headers, but only final outcomes.
- `AuthRefreshInterceptor` and `RetryInterceptor` replay through the same
  `Dio` instance, so replays go through the whole chain again (a fresh token
  and a new log record). Pass the `Dio` they are attached to.

## Migrating from ad-hoc interceptors

Hand-written interceptors of these kinds often have the same bugs. Here is
what changes:

- **Retry**
  - `delay = base * (factor * attempt)` is linear, and it is zero on the
    first retry. This package uses a real exponential with full jitter.
  - Retrying on connection errors "for every method" also replays `POST`.
    Here a `POST` is retried only with an `Idempotency-Key` header or an
    explicit opt-in.
  - A replay through a fresh `Dio()` loses your interceptors. Pass the
    `Dio` the interceptor is attached to.
- **Token refresh**
  - A `QueuedInterceptor` serialises *all* errors behind one refresh. This
    package uses a single shared future, so unrelated errors are not
    delayed.
  - Some interceptors refresh again when a stale `401` arrives after a
    refresh already finished. This one compares tokens and replays without
    a second refresh.
  - If the refresh callback calls the same `Dio`, it no longer deadlocks.
- **Dedup**
  - Some interceptors cache by method and path only, so a `POST` or `PATCH`
    response gets replayed. Here writes are never cached, and the body is
    part of the key.
  - `handler.resolve` with the same shared `Response` lets callers mutate
    each other's data. Here each waiter gets its own copy.
- **Logging**
  - Instead of wrapping `pretty_dio_logger` and redacting per printed line
    (which misses tokens wrapped across lines), `RedactingLogInterceptor`
    redacts the structured data before formatting. The output is compact:
    one record per event.

## Limitations

- **Dedup**
  - A merged request's response data is deep-copied only for JSON-like
    values (maps, lists, strings, numbers, bytes). Custom objects produced
    by a custom transformer are shared.
  - Requests with `FormData` or `Stream` bodies, and requests expecting
    `ResponseType.stream`, are never merged.
- **Retry**
  - `FormData` bodies are never retried, even when every part could be
    cloned.
  - The two-digit year of the obsolete RFC 850 date is resolved against the
    real current year, not the injected clock.
- **Auth refresh**
  - The refresh callback must persist the new token so that `tokenProvider`
    returns it.
  - A `401` on a request that carried no token is passed through without a
    refresh.
  - The "requests made inside the refresh bypass the interceptor" rule uses
    a `Zone` value. Work that escapes the zone, such as a request started
    from a stream listener created earlier, must be marked with
    `skipExtraKey` or listed in `skipPaths`.
- **Logger**
  - Redaction is best effort for values it cannot recognise. A secret whose
    key is not in the configured names, that is not a JWT or auth-scheme
    credential, and that was not redacted elsewhere in the same request,
    will be printed. Add your own names with `redactKeys` or
    `redactKeyFragments`.
  - Values shorter than 4 characters are redacted where they appear
    structurally, but are not searched for in free text.
- **`JwtClaims`** never verifies signatures, by design.

## License

MIT. See [LICENSE](LICENSE).

Made by [Abdeldjalil Chougui](https://abdeldjalilchougui.biz/).
