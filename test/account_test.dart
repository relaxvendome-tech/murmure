// Tests de la logique pure d'extraction/partage d'identifiant Matrix (lib/account.dart),
// utilisée partout où un identifiant est saisi à la main, collé, ou scanné par QR : ajout de
// membre à un groupe (ui/group_screen.dart, ui/group_info_screen.dart) et ajout de contact /
// démarrage de conversation directe (ui/rooms_screen.dart). Jamais testée jusqu'ici malgré ce
// rôle (frontière d'entrée utilisateur la plus exposée de l'appli, y compris à un QR code
// malveillant) : couvre ici le comportement réel de la regex, pas une intention supposée.
import 'package:flutter_test/flutter_test.dart';
import 'package:murmure/account.dart';
import 'package:murmure/config.dart';

void main() {
  group('parseUserId', () {
    test('identifiant simple, sans rien autour', () {
      expect(parseUserId('@alice:example.org'), '@alice:example.org');
    });

    test('précédé du préfixe de partage murmure: (QR/lien, voir shareableId)', () {
      expect(parseUserId('murmure:@alice:example.org'), '@alice:example.org');
    });

    test('entouré de texte libre (collé depuis un message, une URL...)', () {
      expect(parseUserId('Contactez-moi : @bob:matrix.example.fr !'), '@bob:matrix.example.fr');
    });

    test('avec un port explicite sur le serveur', () {
      expect(parseUserId('@bob:example.org:8448'), '@bob:example.org:8448');
    });

    test('localpart avec les caractères autorisés par la grammaire Matrix (point, égal, tiret bas, barre oblique, plus, tiret)', () {
      expect(parseUserId('@a.b=c_d/e+f-g:example.org'), '@a.b=c_d/e+f-g:example.org');
    });

    test('serveur avec sous-domaines et tirets', () {
      expect(parseUserId('@alice:sub-domain.example.co.uk'), '@alice:sub-domain.example.co.uk');
    });

    test('aucun identifiant dans le texte : null', () {
      expect(parseUserId('bonjour, comment ça va ?'), isNull);
    });

    test('chaîne vide : null', () {
      expect(parseUserId(''), isNull);
    });

    test('arobase seule, sans forme de domaine après : null', () {
      expect(parseUserId('@juste-un-arobase'), isNull);
    });

    // La grammaire Matrix des identifiants utilisateur (localpart) est strictement minuscule ;
    // un identifiant mal formé avec une majuscule ne doit pas être extrait tel quel.
    test('localpart avec une majuscule : jamais renvoyé tel quel', () {
      expect(parseUserId('@Alice:example.org'), isNull);
    });

    test('plusieurs identifiants dans le texte : seul le premier est renvoyé', () {
      expect(parseUserId('@alice:example.org et @bob:example.org'), '@alice:example.org');
    });
  });

  group('shareableId', () {
    test('préfixe le paramètre avec kIdPrefix, sans rien modifier d\'autre', () {
      expect(shareableId('@alice:example.org'), '$kIdPrefix@alice:example.org');
      expect(shareableId('@alice:example.org'), 'murmure:@alice:example.org');
    });

    // Propriété qui justifie l'usage conjoint des deux fonctions dans l'appli (voir
    // ui/qr_screens.dart pour l'émission, ui/rooms_screen.dart pour la lecture) : ce que
    // shareableId encode doit être ce que parseUserId retrouve, à l'identique.
    test('round-trip avec parseUserId', () {
      const id = '@alice:example.org';
      expect(parseUserId(shareableId(id)), id);
    });
  });
}
