// Tests de la logique pure des réactions (lib/reactions.dart) : extraction de la clé emoji depuis
// un contenu JSON, regroupement par emoji, détection d'une réaction déjà posée par soi-même.
// Aucun objet Matrix (Event/Room/Client) n'est nécessaire : toute cette logique prend des valeurs
// construites à la main, par construction (voir le commentaire de lib/reactions.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:murmure/reactions.dart';

void main() {
  group('reactionKeyOf', () {
    test('contenu null : aucune clé', () {
      expect(reactionKeyOf(null), isNull);
    });

    test('pas de m.relates_to : aucune clé', () {
      expect(reactionKeyOf({'body': 'texte'}), isNull);
    });

    test('m.relates_to pas une map : aucune clé', () {
      expect(reactionKeyOf({'m.relates_to': 'pas une map'}), isNull);
    });

    test('clé absente : aucune clé', () {
      expect(
        reactionKeyOf({
          'm.relates_to': {'rel_type': 'm.annotation', 'event_id': '\$abc'},
        }),
        isNull,
      );
    });

    test('clé vide : aucune clé (événement malformé, pas un emoji vide valide)', () {
      expect(
        reactionKeyOf({
          'm.relates_to': {'rel_type': 'm.annotation', 'event_id': '\$abc', 'key': ''},
        }),
        isNull,
      );
    });

    test('clé non textuelle : aucune clé', () {
      expect(
        reactionKeyOf({
          'm.relates_to': {'rel_type': 'm.annotation', 'event_id': '\$abc', 'key': 42},
        }),
        isNull,
      );
    });

    test('contenu valide : la clé emoji est extraite', () {
      expect(
        reactionKeyOf({
          'm.relates_to': {'rel_type': 'm.annotation', 'event_id': '\$abc', 'key': '👍'},
        }),
        '👍',
      );
    });
  });

  group('groupReactionsBySenders', () {
    test('aucune réaction : carte vide', () {
      expect(groupReactionsBySenders(const []), isEmpty);
    });

    test('un emoji, plusieurs expéditeurs : regroupés sous la même clé', () {
      final grouped = groupReactionsBySenders(const [
        (senderId: '@alice:ex.org', key: '👍'),
        (senderId: '@bob:ex.org', key: '👍'),
      ]);
      expect(grouped.keys, ['👍']);
      expect(grouped['👍'], ['@alice:ex.org', '@bob:ex.org']);
    });

    test('plusieurs emojis : une entrée par emoji, ordre de première apparition', () {
      final grouped = groupReactionsBySenders(const [
        (senderId: '@bob:ex.org', key: '😂'),
        (senderId: '@alice:ex.org', key: '👍'),
        (senderId: '@carol:ex.org', key: '😂'),
      ]);
      // 😂 vu avant 👍 dans la liste d'entrée : il doit rester en tête malgré un compte égal.
      expect(grouped.keys.toList(), ['😂', '👍']);
      expect(grouped['😂'], ['@bob:ex.org', '@carol:ex.org']);
      expect(grouped['👍'], ['@alice:ex.org']);
    });

    test('même expéditeur présent deux fois (ne devrait pas arriver, mais pas de crash)', () {
      final grouped = groupReactionsBySenders(const [
        (senderId: '@alice:ex.org', key: '👍'),
        (senderId: '@alice:ex.org', key: '👍'),
      ]);
      expect(grouped['👍'], ['@alice:ex.org', '@alice:ex.org']);
    });
  });

  group('hasOwnReaction', () {
    const reactions = [
      (senderId: '@alice:ex.org', key: '👍'),
      (senderId: '@bob:ex.org', key: '😂'),
    ];

    test('moi présent avec cet emoji : vrai', () {
      expect(hasOwnReaction(reactions, '@alice:ex.org', '👍'), isTrue);
    });

    test('moi présent mais avec un autre emoji : faux', () {
      expect(hasOwnReaction(reactions, '@alice:ex.org', '😂'), isFalse);
    });

    test('un autre a réagi avec cet emoji, pas moi : faux', () {
      expect(hasOwnReaction(reactions, '@carol:ex.org', '👍'), isFalse);
    });

    test('aucune réaction : faux', () {
      expect(hasOwnReaction(const [], '@alice:ex.org', '👍'), isFalse);
    });
  });
}
