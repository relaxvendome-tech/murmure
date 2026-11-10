// Tests de la logique pure de blocage (lib/moderation.dart) : voir ce fichier pour le constat
// d'audit (ni le SDK Matrix pinné ni Synapse ne retirent d'un salon déjà rejoint les messages ou
// réactions d'un expéditeur bloqué — seul un filtre côté client peut le faire).
import 'package:flutter_test/flutter_test.dart';
import 'package:murmure/moderation.dart';

void main() {
  group('isSenderBlocked', () {
    test('expéditeur présent dans la liste des bloqués : vrai', () {
      expect(isSenderBlocked('@eve:ex.org', const ['@eve:ex.org']), isTrue);
    });

    test('expéditeur absent de la liste : faux', () {
      expect(isSenderBlocked('@alice:ex.org', const ['@eve:ex.org']), isFalse);
    });

    test('liste des bloqués vide : jamais bloqué', () {
      expect(isSenderBlocked('@alice:ex.org', const []), isFalse);
    });

    test('comparaison exacte, sensible à la casse (identifiants Matrix sensibles à la casse)', () {
      expect(isSenderBlocked('@Eve:ex.org', const ['@eve:ex.org']), isFalse);
    });
  });
}
