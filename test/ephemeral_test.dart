// Tests de la logique pure d'expiration des messages éphémères (lib/ephemeral.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:murmure/ephemeral.dart';

void main() {
  final sent = DateTime.utc(2026, 1, 1, 12);

  test('TTL 0 ou négatif : jamais expiré', () {
    final later = sent.add(const Duration(days: 365));
    expect(isExpiredAt(originServerTs: sent, ttlSeconds: 0, now: later), isFalse);
    expect(isExpiredAt(originServerTs: sent, ttlSeconds: -5, now: later), isFalse);
  });

  test('expire strictement après TTL + tolérance d\'horloge', () {
    expect(isExpiredAt(originServerTs: sent, ttlSeconds: 300,
        now: sent.add(const Duration(seconds: 360))), isFalse);
    expect(isExpiredAt(originServerTs: sent, ttlSeconds: 300,
        now: sent.add(const Duration(seconds: 361))), isTrue);
  });

  test('message antérieur à l\'activation : jamais expiré (pas d\'effacement rétroactif)', () {
    final enabled = sent.add(const Duration(hours: 1));
    final much = sent.add(const Duration(days: 30));
    expect(isExpiredAt(originServerTs: sent, ttlSeconds: 300, now: much, enabledAt: enabled),
        isFalse);
    expect(isExpiredAt(originServerTs: enabled.add(const Duration(seconds: 1)), ttlSeconds: 300,
        now: much, enabledAt: enabled), isTrue);
  });

  test('TTL démesuré borné à 1 an', () {
    expect(parseTtlSeconds({'ttl_seconds': 1 << 40}), kMaxTtlSeconds);
  });

  test('horloge locale en retard : non expiré', () {
    expect(isExpiredAt(originServerTs: sent, ttlSeconds: 60,
        now: sent.subtract(const Duration(minutes: 10))), isFalse);
  });

  test('parseTtlSeconds tolère les contenus invalides', () {
    expect(parseTtlSeconds(null), 0);
    expect(parseTtlSeconds({}), 0);
    expect(parseTtlSeconds({'ttl_seconds': 'x'}), 0);
    expect(parseTtlSeconds({'ttl_seconds': -3}), 0);
    expect(parseTtlSeconds({'ttl_seconds': 3600}), 3600);
  });

  test('libellés des choix', () {
    expect(ephemeralLabel(604800), '1 semaine');
    expect(ephemeralLabel(42), '42 s');
    expect(kEphemeralChoices.first.$2, 0);
  });
}
