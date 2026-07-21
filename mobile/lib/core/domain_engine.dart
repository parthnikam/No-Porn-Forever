import 'list_parser.dart';

/// Policy decision — mirrors filterd/core Decision.
class Decision {
  final String domain;
  final bool blocked;
  final String? matchedRule;
  final String? source;
  final String? allowedBy;

  const Decision({
    required this.domain,
    this.blocked = false,
    this.matchedRule,
    this.source,
    this.allowedBy,
  });
}

/// In-memory domain set with parent-label walk.
class DomainSet {
  final Map<String, String> _domains = {};

  int get length => _domains.length;

  bool add(String domain, [String source = 'nsfw']) {
    domain = normalizeDomain(domain);
    if (domain.isEmpty) return false;
    if (_domains.containsKey(domain)) return false;
    _domains[domain] = source;
    return true;
  }

  bool hasExact(String domain) {
    domain = normalizeDomain(domain);
    return _domains.containsKey(domain);
  }

  /// a.b.example.com → check a.b.example.com, b.example.com, example.com
  (String matched, String source)? match(String domain) {
    domain = normalizeDomain(domain);
    if (domain.isEmpty) return null;
    var d = domain;
    while (true) {
      final src = _domains[d];
      if (src != null) return (d, src);
      final i = d.indexOf('.');
      if (i < 0) return null;
      d = d.substring(i + 1);
      if (d.isEmpty) return null;
    }
  }

  void clear() => _domains.clear();
}

/// Allowlist wins over blocklist — same as filterd Engine.
class DomainEngine {
  final DomainSet block = DomainSet();
  final DomainSet allow = DomainSet();

  Decision check(String domain) {
    domain = normalizeDomain(domain);
    if (domain.isEmpty) return Decision(domain: domain);

    final a = allow.match(domain);
    if (a != null) {
      return Decision(
        domain: domain,
        blocked: false,
        allowedBy: a.$1,
        source: a.$2,
      );
    }
    final b = block.match(domain);
    if (b != null) {
      return Decision(
        domain: domain,
        blocked: true,
        matchedRule: b.$1,
        source: b.$2,
      );
    }
    return Decision(domain: domain);
  }

  int loadBlocklist(String text, {String source = 'nsfw'}) {
    var added = 0;
    for (final line in text.split('\n')) {
      final d = parseAdblockLine(line);
      if (d.isNotEmpty && block.add(d, source)) added++;
    }
    return added;
  }

  int loadAllowlist(String text, {String source = 'allow'}) {
    var added = 0;
    for (final line in text.split('\n')) {
      final d = parseAdblockLine(line);
      if (d.isNotEmpty && allow.add(d, source)) added++;
    }
    return added;
  }
}
