import 'package:flutter/services.dart';

/// Pont vers le service de premier plan Android du maillage Bluetooth (voir
/// android/app/src/main/kotlin/.../MeshForegroundService.kt).
///
/// Trouvé en audit interne : sans ce service, Android peut suspendre ou tuer le processus dès
/// l'appli mise en arrière-plan ou l'écran verrouillé, coupant silencieusement le scan/relais BLE
/// (lib/mesh/mesh.dart) — alors que l'usage visé (téléphone en poche pendant une manifestation)
/// exige justement qu'il continue sans que l'appli reste à l'écran.
///
/// Comme les autres ponts natifs best-effort de ce dépôt, ce pont ne lève jamais : sur une
/// plateforme sans ce canal (iOS, desktop, web), [start]/[stop] ne font rien et le scan BLE
/// continue de fonctionner au premier plan comme avant ce correctif — seule la survie en
/// arrière-plan n'est pas garantie sur ces plateformes, ce qui n'a jamais été prétendu ailleurs
/// que sur Android.
class MeshForegroundService {
  static const _channel = MethodChannel('fr.lansight.murmure/mesh_fg');

  /// À appeler au moment où le scan/l'annonce BLE démarre (voir `Mesh.start()`). `calcMode` doit
  /// refléter l'état du déguisement calculatrice AU MOMENT de l'appel (jamais recalculé côté
  /// natif) pour que le texte de la notification reste cohérent avec l'icône affichée.
  static Future<void> start({required bool calcMode}) async {
    try {
      await _channel.invokeMethod<bool>('start', {'calcMode': calcMode});
    } on PlatformException {
      // Pas de levier de premier plan sur cette plateforme (iOS, desktop, web) : le maillage
      // continue de fonctionner tant que l'appli reste au premier plan, comme avant ce correctif.
    } on MissingPluginException {
      // Idem.
    }
  }

  /// À appeler au moment où le scan/l'annonce BLE s'arrête (voir `Mesh.stop()`), y compris lors
  /// d'un `Mesh.reset()` (déconnexion/panique).
  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<bool>('stop');
    } on PlatformException {
      // Rien à arrêter sur cette plateforme.
    } on MissingPluginException {
      // Idem.
    }
  }
}
