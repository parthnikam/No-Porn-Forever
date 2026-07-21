// HaGeZi / Adblock-style DNS list parsing — mirrors filterd/core/lists.go

String normalizeDomain(String s) {
  s = s.trim();
  while (s.endsWith('.')) {
    s = s.substring(0, s.length - 1);
  }
  s = s.toLowerCase();
  if (s.isEmpty) return '';
  if (s.contains(RegExp(r'[\s/\\]'))) return '';
  if (s.startsWith('*.')) s = s.substring(2);
  if (s.isEmpty || s == '*') return '';
  for (final part in s.split('.')) {
    if (part.isEmpty) return '';
  }
  return s;
}

bool _isIPv4Literal(String s) {
  final parts = s.split('.');
  if (parts.length != 4) return false;
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return false;
  }
  return true;
}

/// Extract a domain from one list line. Empty = skip.
String parseAdblockLine(String line) {
  line = line.trim();
  if (line.isEmpty) return '';
  final c0 = line.codeUnitAt(0);
  if (c0 == 0x21 /* ! */ || c0 == 0x5B /* [ */ || c0 == 0x23 /* # */) {
    return '';
  }

  if (line.startsWith('||')) {
    var rest = line.substring(2);
    for (final sep in ['^', r'$', '/', '*']) {
      final i = rest.indexOf(sep);
      if (i >= 0) {
        if (sep == '*' && i == 0) return '';
        rest = rest.substring(0, i);
        break;
      }
    }
    final sp = rest.indexOf(RegExp(r'\s'));
    if (sp >= 0) rest = rest.substring(0, sp);
    return normalizeDomain(rest);
  }

  final fields = line.split(RegExp(r'\s+'));
  if (fields.length >= 2 &&
      (fields[0] == '0.0.0.0' ||
          fields[0] == '127.0.0.1' ||
          fields[0] == '::' ||
          fields[0] == '::1')) {
    return normalizeDomain(fields[1]);
  }

  if (fields.length == 1 && fields[0].contains('.')) {
    if (_isIPv4Literal(fields[0])) return '';
    return normalizeDomain(fields[0]);
  }

  return '';
}
