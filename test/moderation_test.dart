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

  group('hideRoomPreview (aperçu de la liste des conversations)', () {
    test('message normal : affiché', () {
      expect(hideRoomPreview(redacted: false, expired: false, senderBlocked: false), isFalse);
    });
    test('rédigé, expiré ou expéditeur bloqué : masqué', () {
      expect(hideRoomPreview(redacted: true, expired: false, senderBlocked: false), isTrue);
      expect(hideRoomPreview(redacted: false, expired: true, senderBlocked: false), isTrue);
      expect(hideRoomPreview(redacted: false, expired: false, senderBlocked: true), isTrue);
    });
  });

  group('isInviteHidden', () {
    test('invitant bloqué : invitation masquée', () {
      expect(isInviteHidden('@eve:ex.org', const ['@eve:ex.org']), isTrue);
    });
    test('invitant non bloqué ou inconnu : invitation affichée', () {
      expect(isInviteHidden('@alice:ex.org', const ['@eve:ex.org']), isFalse);
      expect(isInviteHidden(null, const ['@eve:ex.org']), isFalse);
    });
  });

  group('isReplyTargetUsable', () {
    test('message cité normal : utilisable', () {
      expect(isReplyTargetUsable(redacted: false, expired: false, senderBlocked: false), isTrue);
    });
    test('rédigé, expiré ou expéditeur bloqué : réponse annulée', () {
      expect(isReplyTargetUsable(redacted: true, expired: false, senderBlocked: false), isFalse);
      expect(isReplyTargetUsable(redacted: false, expired: true, senderBlocked: false), isFalse);
      expect(isReplyTargetUsable(redacted: false, expired: false, senderBlocked: true), isFalse);
    });
  });
}
