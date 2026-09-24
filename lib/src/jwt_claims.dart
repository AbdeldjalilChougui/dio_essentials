import 'dart:convert';

/// The claims of a JSON Web Token, decoded **without verifying anything**.
///
/// **Security warning:** [decodeUnverified] does *not* check the signature,
/// the algorithm, the issuer or the audience. Anyone can forge a token whose
/// payload says anything. Use these claims only for client-side hints such as
/// "refresh before this token expires" or "show the user's display name". Never
/// use them to make an authorization decision; that is the server's job.
class JwtClaims {
  JwtClaims._(this.claims);

  /// Decodes the payload (second segment) of [token] without verifying the
  /// signature. See the class documentation for why that matters.
  ///
  /// A leading `Bearer ` prefix is ignored. Throws a [FormatException] when the
  /// token does not have three dot-separated segments, when the payload is not
  /// valid base64url, or when it is not a JSON object.
  factory JwtClaims.decodeUnverified(String token) {
    var raw = token.trim();
    if (raw.toLowerCase().startsWith('bearer ')) raw = raw.substring(7).trim();
    final parts = raw.split('.');
    if (parts.length != 3 || parts[1].isEmpty) {
      throw const FormatException('A JWT must have three segments.');
    }
    final Object? json;
    try {
      final bytes = base64Url.decode(base64Url.normalize(parts[1]));
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw FormatException('JWT payload is not base64url JSON: ${e.message}');
    }
    if (json is! Map<String, dynamic>) {
      throw const FormatException('JWT payload is not a JSON object.');
    }
    return JwtClaims._(Map.unmodifiable(json));
  }

  /// Like [JwtClaims.decodeUnverified] but returns `null` for a `null` or
  /// malformed token instead of throwing. The signature is still not verified.
  static JwtClaims? tryDecodeUnverified(String? token) {
    if (token == null) return null;
    try {
      return JwtClaims.decodeUnverified(token);
    } on FormatException {
      return null;
    }
  }

  /// Every claim in the payload, unmodifiable.
  final Map<String, dynamic> claims;

  /// The raw value of claim [name], or `null` if absent.
  Object? operator [](String name) => claims[name];

  /// The `sub` claim, if it is a string.
  String? get subject {
    final sub = claims['sub'];
    return sub is String ? sub : null;
  }

  /// The `exp` claim as a UTC [DateTime], or `null` if absent or not numeric.
  DateTime? get expiresAt => _epoch('exp');

  /// The `iat` claim as a UTC [DateTime], or `null` if absent or not numeric.
  DateTime? get issuedAt => _epoch('iat');

  /// Whether [expiresAt] falls within [leeway] of [now] (or has passed).
  ///
  /// Returns `false` when the token has no `exp` claim: such a token never
  /// expires on its own, so there is nothing to refresh ahead of.
  /// [now] defaults to [DateTime.now].
  bool expiresWithin(Duration leeway, {DateTime? now}) {
    final exp = expiresAt;
    if (exp == null) return false;
    return !(now ?? DateTime.now()).add(leeway).isBefore(exp);
  }

  DateTime? _epoch(String name) {
    final value = claims[name];
    if (value is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (value * 1000).round(),
      isUtc: true,
    );
  }

  @override
  String toString() => 'JwtClaims(unverified, ${claims.keys.join(', ')})';
}
