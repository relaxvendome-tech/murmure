import 'package:flutter/services.dart';

/// Pont vers le service de premier plan Android des appels (voir
/// android/app/src/main/kotlin/.../CallForegroundService.kt).
///
/// Sans service de premier plan de type `microphone` (et `camera` en vidéo), Android coupe l'accès
/// au micro et à la caméra d'une appli passée en arrière-plan ou dont l'écran est éteint : l'appel
/// reste « connecté » mais plus aucun son/image ne part. Ce service ne fait rien par lui-même ; il
/// ne sert qu'à garder le micro/la caméra utilisables pendant un appel déclenché par l'utilisateur.
///
/// Best-effort comme les autres ponts natifs : ne lève jamais. Hors Android (canal absent), les
/// méthodes ne font rien.
class CallForegroundService {
  static const _channel = MethodChannel('fr.lansight.murmure/call_fg');

  /// À appeler quand l'appel devient « vivant ». [video] ajoute le type `camera`. [calcMode] doit
  /// refléter le mode discret AU MOMENT de l'appel : la notification est alors neutre.
  static Future<void> start({required bool video, required bool calcMode}) async {
    try {
      await _channel.invokeMethod<bool>('start', {'video': video, 'calcMode': calcMode});
    } on PlatformException {
      // Pas de service de premier plan disponible : l'appel continue au premier plan seulement.
    } on MissingPluginException {
      // Idem (plateforme sans ce canal).
    } catch (_) {
      // Jamais d'exception qui casse un appel.
    }
  }

  /// À appeler à la fin de l'appel (terminé, manqué, raccroché).
  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<bool>('stop');
    } on PlatformException {
      // Rien à arrêter.
    } on MissingPluginException {
      // Idem.
    } catch (_) {
      // Idem.
    }
  }
}
