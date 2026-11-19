// Tests de `shouldStartForeground` (lib/calls/services/call_manager.dart) — logique pure derrière
// `MurmureWebRTCDelegate._syncForeground`.
//
// Couvre précisément le défaut trouvé en audit interne : un appel vidéo qui démarre le service de
// premier plan AVANT que la permission CAMERA ne soit accordée (cas normal pour un premier appel
// vidéo, voir le commentaire de `_syncForeground`) doit pouvoir le redémarrer ensuite pour y
// ajouter le type caméra, sans jamais le redémarrer pour rien une fois qu'elle l'a déjà.
import 'package:flutter_test/flutter_test.dart';
import 'package:murmure/calls/services/call_manager.dart';

void main() {
  group('shouldStartForeground', () {
    test('jamais démarré : toujours vrai (appel audio)', () {
      expect(
        shouldStartForeground(started: false, hasCamera: false, wantVideo: false, camNow: false),
        isTrue,
      );
    });

    test('jamais démarré : toujours vrai (appel vidéo, caméra pas encore accordée)', () {
      // Le cas déclencheur du défaut : premier appel vidéo, CAMERA pas encore accordée au moment
      // où le service démarre pour la première fois (avant que `getUserMedia` ne la demande).
      expect(
        shouldStartForeground(started: false, hasCamera: false, wantVideo: true, camNow: false),
        isTrue,
      );
    });

    test('jamais démarré : toujours vrai (appel vidéo, caméra déjà accordée)', () {
      expect(
        shouldStartForeground(started: false, hasCamera: false, wantVideo: true, camNow: true),
        isTrue,
      );
    });

    test('déjà démarré, appel audio : jamais redémarré', () {
      expect(
        shouldStartForeground(started: true, hasCamera: false, wantVideo: false, camNow: false),
        isFalse,
      );
    });

    test('déjà démarré sans caméra, appel vidéo, caméra toujours pas accordée : pas de redémarrage', () {
      expect(
        shouldStartForeground(started: true, hasCamera: false, wantVideo: true, camNow: false),
        isFalse,
      );
    });

    test(
        'déjà démarré SANS caméra, appel vidéo, caméra accordée depuis : redémarre (le correctif)',
        () {
      expect(
        shouldStartForeground(started: true, hasCamera: false, wantVideo: true, camNow: true),
        isTrue,
      );
    });

    test('déjà démarré AVEC caméra, appel vidéo : jamais redémarré (idempotent)', () {
      expect(
        shouldStartForeground(started: true, hasCamera: true, wantVideo: true, camNow: true),
        isFalse,
      );
    });

    test('déjà démarré AVEC caméra : jamais redémarré même si `camNow` redevient faux (pas de '
        'retrait)', () {
      // `camNow` ne peut pas réellement redevenir faux après avoir été accordée (Android ne
      // révoque pas une permission en cours de session), mais la fonction ne doit dans tous les
      // cas jamais retirer la caméra une fois obtenue.
      expect(
        shouldStartForeground(started: true, hasCamera: true, wantVideo: true, camNow: false),
        isFalse,
      );
    });
  });
}
