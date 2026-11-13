import 'package:flutter_test/flutter_test.dart';
import 'package:murmure/conversation_search.dart';

void main() {
  group('matchesSearchQuery', () {
    test('correspondance insensible à la casse', () {
      expect(matchesSearchQuery('Rendez-vous à 18h devant la mairie', 'MAIRIE'), isTrue);
      expect(matchesSearchQuery('Rendez-vous à 18h devant la mairie', 'mairie'), isTrue);
    });

    test('sous-chaîne au milieu du texte', () {
      expect(matchesSearchQuery('on se retrouve où exactement ?', 'retrouve'), isTrue);
    });

    test('aucune correspondance', () {
      expect(matchesSearchQuery('bonjour tout le monde', 'absent'), isFalse);
    });

    test('requête vide ne correspond à rien (jamais "tout affiche")', () {
      expect(matchesSearchQuery('bonjour', ''), isFalse);
    });

    test('requête blanche (espaces seuls) ne correspond à rien', () {
      expect(matchesSearchQuery('bonjour', '   '), isFalse);
    });

    test('espaces superflus autour de la requête sont ignorés', () {
      expect(matchesSearchQuery('bonjour tout le monde', '  tout le monde  '), isTrue);
    });

    test('texte vide ne correspond à aucune requête non vide', () {
      expect(matchesSearchQuery('', 'quoi que ce soit'), isFalse);
    });
  });
}
