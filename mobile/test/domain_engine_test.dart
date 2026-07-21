import 'package:filterd_mobile/core/domain_engine.dart';
import 'package:filterd_mobile/core/list_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parse adblock lines', () {
    expect(parseAdblockLine('||pornhub.com^'), 'pornhub.com');
    expect(parseAdblockLine('! comment'), '');
    expect(parseAdblockLine('0.0.0.0 bad.example'), 'bad.example');
  });

  test('parent label match + allow wins', () {
    final e = DomainEngine();
    e.block.add('example.com', 'nsfw');
    e.allow.add('cdn.example.com', 'allow');

    expect(e.check('a.b.example.com').blocked, isTrue);
    expect(e.check('a.b.example.com').matchedRule, 'example.com');
    expect(e.check('cdn.example.com').blocked, isFalse);
    expect(e.check('cdn.example.com').allowedBy, 'cdn.example.com');
    expect(e.check('google.com').blocked, isFalse);
  });
}
