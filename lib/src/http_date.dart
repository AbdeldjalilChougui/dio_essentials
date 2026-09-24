/// HTTP-date parsing and formatting (RFC 9110 section 5.6.7) without
/// `dart:io`, so the package also works on the web.
library;

const _months = [
  'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
  'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

// Sun, 06 Nov 1994 08:49:37 GMT
final _imf = RegExp(
  r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
);
// Sunday, 06-Nov-94 08:49:37 GMT
final _rfc850 = RegExp(
  r'^[A-Za-z]+, (\d{2})-([A-Za-z]{3})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) GMT$',
);
// Sun Nov  6 08:49:37 1994
final _asctime = RegExp(
  r'^[A-Za-z]{3} ([A-Za-z]{3}) ([ \d]\d) (\d{2}):(\d{2}):(\d{2}) (\d{4})$',
);

/// Parses an HTTP-date in any of the three formats HTTP allows, returning a
/// UTC [DateTime], or `null` if [value] is not a valid HTTP-date.
DateTime? parseHttpDate(String value) {
  final s = value.trim();
  var m = _imf.firstMatch(s);
  if (m != null) {
    return _build(m[3]!, m[2]!, m[1]!, m[4]!, m[5]!, m[6]!);
  }
  m = _rfc850.firstMatch(s);
  if (m != null) {
    // RFC 9110: a two-digit year more than 50 years in the future is taken
    // to be in the past century. Resolve against the current year.
    final yy = int.parse(m[3]!);
    final nowYear = DateTime.now().toUtc().year;
    var year = (nowYear ~/ 100) * 100 + yy;
    if (year > nowYear + 50) year -= 100;
    return _build('$year', m[2]!, m[1]!, m[4]!, m[5]!, m[6]!);
  }
  m = _asctime.firstMatch(s);
  if (m != null) {
    return _build(m[6]!, m[1]!, m[2]!.trim(), m[3]!, m[4]!, m[5]!);
  }
  return null;
}

DateTime? _build(
  String year,
  String month,
  String day,
  String hour,
  String minute,
  String second,
) {
  final mo = _months.indexOf(month.toLowerCase()) + 1;
  if (mo == 0) return null;
  final y = int.parse(year);
  final d = int.parse(day);
  final h = int.parse(hour);
  final mi = int.parse(minute);
  final se = int.parse(second);
  if (d < 1 || h > 23 || mi > 59 || se > 60) return null;
  final result = DateTime.utc(y, mo, d, h, mi, se);
  // DateTime silently rolls 31 Feb into March; reject such dates.
  if (result.month != mo || result.day != d) return null;
  return result;
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Formats [time] as an IMF-fixdate, the preferred HTTP-date format.
String formatImfFixdate(DateTime time) {
  final t = time.toUtc();
  final month = _months[t.month - 1];
  final monthName = month[0].toUpperCase() + month.substring(1);
  return '${_weekdays[t.weekday - 1]}, ${_two(t.day)} $monthName '
      '${t.year.toString().padLeft(4, '0')} '
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)} GMT';
}
