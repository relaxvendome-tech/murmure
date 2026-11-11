// Tests de la logique pure de lib/message_notifier.dart : quels salons restent « en attente »
// (messages notifiés mais pas encore vus) une fois qu'une conversation donnée est ouverte.
//
// Trouvé en audit interne : avant le correctif que ce test couvre, ouvrir N'IMPORTE QUELLE
// conversation (même sans aucun message en attente) effaçait la notification ET le compteur
// pour TOUS les salons — un message reçu dans un salon B pouvait donc disparaître du radar de
// l'utilisateur simplement parce qu'il venait d'ouvrir un salon A (ou même un salon C sans rien
// en attente). `remainingAfterViewing` isole la logique corrigée (un seul salon retiré à la
// fois) pour qu'elle soit vérifiée sans FlutterLocalNotificationsPlugin ni Client Matrix.
import 'package:flutter_test/flutter_test.dart';
import 'package:murmure/message_notifier.dart';

void main() {
  group('remainingAfterViewing', () {
    test('aucun salon en attente : total nul', () {
      expect(remainingAfterViewing(const {}, '!a:ex.org'), 0);
    });

    test('un seul salon en attente, ouvert : plus rien en attente', () {
      expect(remainingAfterViewing(const {'!a:ex.org': 3}, '!a:ex.org'), 0);
    });

    test('salon ouvert sans rien en attente : les autres salons restent intacts', () {
      // Cas concret du bug : ouvrir un salon C qui n'a rien en attente ne doit PAS effacer ce
      // qui attend dans A et B.
      final pending = {'!a:ex.org': 2, '!b:ex.org': 1};
      expect(remainingAfterViewing(pending, '!c:ex.org'), 3);
      // Et la carte d'entrée n'est pas mutée par la fonction (logique pure).
      expect(pending, {'!a:ex.org': 2, '!b:ex.org': 1});
    });

    test('deux salons en attente, un seul ouvert : seul celui-ci est retiré du total', () {
      final pending = {'!a:ex.org': 2, '!b:ex.org': 5};
      expect(remainingAfterViewing(pending, '!a:ex.org'), 5);
      expect(remainingAfterViewing(pending, '!b:ex.org'), 2);
    });

    test('plusieurs salons, aucun n\'est celui ouvert : somme de tous', () {
      final pending = {'!a:ex.org': 1, '!b:ex.org': 2, '!c:ex.org': 4};
      expect(remainingAfterViewing(pending, '!d:ex.org'), 7);
    });
  });
}
