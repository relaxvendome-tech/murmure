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

  group('date de première activation (enabled_at_ms)', () {
    final stateTs = DateTime.utc(2026, 3, 1, 12);
    final firstOn = DateTime.utc(2026, 2, 1, 8);

    test('resolveEnabledAt : enabled_at_ms valide et antérieur retenu', () {
      final at = resolveEnabledAt(
          {'ttl_seconds': 3600, 'enabled_at_ms': firstOn.millisecondsSinceEpoch}, stateTs);
      expect(at.millisecondsSinceEpoch, firstOn.millisecondsSinceEpoch);
    });

    test('resolveEnabledAt : absent, invalide ou futur → horodatage de l\'événement', () {
      expect(resolveEnabledAt({'ttl_seconds': 3600}, stateTs), stateTs);
      expect(resolveEnabledAt(null, stateTs), stateTs);
      expect(resolveEnabledAt({'enabled_at_ms': 'x'}, stateTs), stateTs);
      expect(resolveEnabledAt({'enabled_at_ms': -1}, stateTs), stateTs);
      final future = stateTs.add(const Duration(days: 1)).millisecondsSinceEpoch;
      expect(resolveEnabledAt({'enabled_at_ms': future}, stateTs), stateTs);
    });

    test('changer la durée conserve la date de première activation', () {
      final c = buildEphemeralContent(
          ttlSeconds: 3600, prevContent: {'ttl_seconds': 86400}, prevEnabledAt: firstOn);
      expect(c['ttl_seconds'], 3600);
      expect(c['enabled_at_ms'], firstOn.millisecondsSinceEpoch);
      // Un message envoyé entre la première activation et le changement expire bien.
      final msg = firstOn.add(const Duration(days: 2));
      expect(
          isExpiredAt(
              originServerTs: msg,
              ttlSeconds: 3600,
              now: stateTs,
              enabledAt: resolveEnabledAt(c, stateTs)),
          isTrue);
    });

    test('nouvelle activation : pas de date, l\'horodatage serveur fera foi', () {
      final c = buildEphemeralContent(
          ttlSeconds: 300, prevContent: {'ttl_seconds': 0}, prevEnabledAt: firstOn);
      expect(c.containsKey('enabled_at_ms'), isFalse);
      expect(buildEphemeralContent(ttlSeconds: 300).containsKey('enabled_at_ms'), isFalse);
      expect(
          buildEphemeralContent(ttlSeconds: 300, prevContent: {'ttl_seconds': 60})
              .containsKey('enabled_at_ms'),
          isFalse);
    });

    test('désactiver efface la date ; réactiver repart d\'une nouvelle date', () {
      final off = buildEphemeralContent(
          ttlSeconds: 0, prevContent: {'ttl_seconds': 3600}, prevEnabledAt: firstOn);
      expect(off, {'ttl_seconds': 0});
      final on = buildEphemeralContent(
          ttlSeconds: 3600, prevContent: off, prevEnabledAt: stateTs);
      expect(on.containsKey('enabled_at_ms'), isFalse);
      expect(resolveEnabledAt(on, stateTs.add(const Duration(hours: 1))),
          stateTs.add(const Duration(hours: 1)));
    });

    test('TTL hors bornes borné à la publication', () {
      expect(buildEphemeralContent(ttlSeconds: 1 << 40)['ttl_seconds'], kMaxTtlSeconds);
      expect(buildEphemeralContent(ttlSeconds: -5), {'ttl_seconds': 0});
    });
  });
}
