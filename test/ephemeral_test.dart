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

    test('resolveEnabledAt : retenu si l\'état précédent (TTL > 0) portait la même valeur', () {
      final ms = firstOn.millisecondsSinceEpoch;
      final at = resolveEnabledAt({'ttl_seconds': 3600, 'enabled_at_ms': ms}, stateTs,
          prevContent: {'ttl_seconds': 86400, 'enabled_at_ms': ms});
      expect(at.millisecondsSinceEpoch, ms);
    });

    test('resolveEnabledAt : sans état précédent actif → horodatage de l\'événement '
        '(un contact ne peut pas effacer tout l\'historique)', () {
      final ancient = DateTime.utc(2000).millisecondsSinceEpoch;
      final c = {'ttl_seconds': 300, 'enabled_at_ms': ancient};
      expect(resolveEnabledAt(c, stateTs), stateTs);
      expect(resolveEnabledAt(c, stateTs, prevContent: {'ttl_seconds': 0}), stateTs);
      expect(resolveEnabledAt(c, stateTs, prevContent: {}), stateTs);
    });

    test('resolveEnabledAt : valeur différente de celle de l\'état précédent → rejetée', () {
      final c = {'ttl_seconds': 300, 'enabled_at_ms': DateTime.utc(2000).millisecondsSinceEpoch};
      expect(
          resolveEnabledAt(c, stateTs, prevContent: {
            'ttl_seconds': 3600,
            'enabled_at_ms': firstOn.millisecondsSinceEpoch,
          }),
          stateTs);
    });

    test('resolveEnabledAt : état précédent actif sans date → valeur acceptée seulement si '
        'non antérieure à l\'événement précédent (connu)', () {
      final prev = {'ttl_seconds': 86400};
      final c = {'ttl_seconds': 3600, 'enabled_at_ms': firstOn.millisecondsSinceEpoch};
      expect(resolveEnabledAt(c, stateTs, prevContent: prev, prevEventTs: firstOn), firstOn);
      expect(
          resolveEnabledAt(c, stateTs,
              prevContent: prev, prevEventTs: firstOn.add(const Duration(seconds: 1))),
          stateTs);
      // Horodatage précédent inconnu : prudence, horodatage de l'événement.
      expect(resolveEnabledAt(c, stateTs, prevContent: prev), stateTs);
    });

    test('resolveEnabledAt : absent, invalide ou futur → horodatage de l\'événement', () {
      expect(resolveEnabledAt({'ttl_seconds': 3600}, stateTs), stateTs);
      expect(resolveEnabledAt(null, stateTs), stateTs);
      expect(resolveEnabledAt({'enabled_at_ms': 'x'}, stateTs), stateTs);
      expect(resolveEnabledAt({'enabled_at_ms': -1}, stateTs), stateTs);
      final future = stateTs.add(const Duration(days: 1)).millisecondsSinceEpoch;
      expect(
          resolveEnabledAt({'enabled_at_ms': future}, stateTs,
              prevContent: {'ttl_seconds': 60, 'enabled_at_ms': future}),
          stateTs);
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
              enabledAt: resolveEnabledAt(c, stateTs,
                  prevContent: {'ttl_seconds': 86400}, prevEventTs: firstOn)),
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

    test('plancher local : la date effective ne recule jamais sous le plancher', () {
      expect(applyEnabledAtFloor(firstOn, null), firstOn);
      expect(applyEnabledAtFloor(firstOn, stateTs), stateTs);
      expect(applyEnabledAtFloor(stateTs, firstOn), stateTs);
    });

    test('plancher local : écrit au 1er TTL > 0 observé, effacé quand TTL = 0', () {
      final w = floorUpdate(ttlSeconds: 300, currentFloor: null, resolved: stateTs);
      expect(w.write, stateTs);
      expect(w.clear, isFalse);
      final keep = floorUpdate(ttlSeconds: 300, currentFloor: firstOn, resolved: stateTs);
      expect(keep.write, isNull);
      expect(keep.clear, isFalse);
      final off = floorUpdate(ttlSeconds: 0, currentFloor: firstOn, resolved: stateTs);
      expect(off.clear, isTrue);
      expect(off.write, isNull);
      expect(floorUpdate(ttlSeconds: 0, currentFloor: null, resolved: null).clear, isFalse);
    });

    test('attaque : enabled_at_ms ancien accepté en chaîne mais borné par le plancher', () {
      final ancient = DateTime.utc(2000).millisecondsSinceEpoch;
      final resolved = resolveEnabledAt({'ttl_seconds': 300, 'enabled_at_ms': ancient}, stateTs,
          prevContent: {'ttl_seconds': 300, 'enabled_at_ms': ancient});
      final effective = applyEnabledAtFloor(resolved, firstOn);
      expect(effective, firstOn);
      final oldMsg = firstOn.subtract(const Duration(days: 1));
      expect(
          isExpiredAt(
              originServerTs: oldMsg,
              ttlSeconds: 300,
              now: stateTs,
              enabledAt: effective),
          isFalse);
    });

    test('TTL hors bornes borné à la publication', () {
      expect(buildEphemeralContent(ttlSeconds: 1 << 40)['ttl_seconds'], kMaxTtlSeconds);
      expect(buildEphemeralContent(ttlSeconds: -5), {'ttl_seconds': 0});
    });
  });

  group('balayage', () {
    test('shouldSweep : ses propres messages ET réactions expirés, envoyés, non rédigés', () {
      bool f({String type = 'm.room.message', String sender = '@me:x', bool redacted = false,
              bool sent = true, bool expired = true}) =>
          shouldSweep(
              type: type,
              senderId: sender,
              me: '@me:x',
              redacted: redacted,
              sent: sent,
              expired: expired);
      expect(f(), isTrue);
      expect(f(type: 'm.reaction'), isTrue);
      expect(f(type: 'm.room.member'), isFalse);
      expect(f(sender: '@other:x'), isFalse);
      expect(f(redacted: true), isFalse);
      expect(f(sent: false), isFalse);
      expect(f(expired: false), isFalse);
    });

    test('sweepStopBefore : borne la plus récente entre activation et déjà traité', () {
      final a = DateTime.utc(2026, 1, 1);
      final b = DateTime.utc(2026, 2, 1);
      expect(sweepStopBefore(), isNull);
      expect(sweepStopBefore(enabledAt: a), a);
      expect(sweepStopBefore(handledBefore: b), b);
      expect(sweepStopBefore(enabledAt: a, handledBefore: b), b);
      expect(sweepStopBefore(enabledAt: b, handledBefore: a), b);
    });

    test('handledBeforeAfterSweep : now - TTL - tolérance', () {
      final now = DateTime.utc(2026, 1, 1, 12);
      expect(handledBeforeAfterSweep(now, 300),
          now.subtract(const Duration(seconds: 300) + kClockSkewTolerance));
      // Un événement plus ancien que cette borne était bien expiré à `now`.
      final older = handledBeforeAfterSweep(now, 300).subtract(const Duration(seconds: 1));
      expect(isExpiredAt(originServerTs: older, ttlSeconds: 300, now: now), isTrue);
    });
  });
}
