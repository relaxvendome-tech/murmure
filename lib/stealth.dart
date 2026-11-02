import 'package:flutter/services.dart';

/// Pont vers le canal natif Android qui bascule l'icône de lancement entre « Murmure » et
/// « Calculatrice » (voir android/app/src/main/kotlin/.../MainActivity.kt). Aucune vérification
/// de code n'a lieu côté natif : ce canal ne fait que déplacer laquelle des deux activity-alias
/// est active, le PIN reste entièrement vérifié en Dart (AppLock).
class Stealth {
  static const _channel = MethodChannel('fr.lansight.murmure/stealth');

  /// Bascule l'icône visible sur l'écran d'accueil. Pas d'effet sur iOS ou le web (canal absent) :
  /// l'appel échoue silencieusement, le réglage Dart (`calc_mode`) reste la source de vérité pour
  /// l'écran de verrou affiché au lancement suivant.
  static Future<void> setStealth(bool enabled) async {
    try {
      await _channel.invokeMethod<bool>('setStealth', {'enabled': enabled});
    } on PlatformException {
      // Plateforme sans ce canal (iOS, desktop, web) : rien à faire, le mode discret est une
      // fonctionnalité Android uniquement pour l'instant.
    } on MissingPluginException {
      // Idem.
    }
  }

  static Future<bool> isStealth() async {
    try {
      return await _channel.invokeMethod<bool>('isStealth') ?? false;
    } catch (_) {
      return false;
    }
  }
}
