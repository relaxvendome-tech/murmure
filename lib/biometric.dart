import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';

import 'account.dart';

/// Issue d'une tentative biométrique.
enum BioResult {
  /// Empreinte/visage reconnu.
  success,

  /// Annulée, non reconnue ou indisponible : retour silencieux au PIN.
  fallback,

  /// Capteur verrouillé temporairement par Android : message clair + PIN.
  lockedTemporarily,

  /// Capteur verrouillé durablement par Android (il faudra le PIN/schéma de l'appareil).
  lockedPermanently,
}

/// Déverrouillage biométrique OPTIONNEL, en complément du code PIN (jamais en remplacement).
///
/// Sécurité :
/// - La biométrie ne déverrouille QUE l'interface. La clé SQLCipher reste dans le Keystore comme
///   avant (voir [Account.dbKey]) : rien ici ne touche à la dérivation ni au stockage des clés.
/// - Jamais proposée sur l'écran factice « Calculatrice » (mode discret) : un prompt biométrique
///   trahirait l'appli. Seul `PinScreen` en mode unlock l'appelle.
/// - La biométrie, comme tout raccourci, ne permet PAS d'entrer le code de contrainte (duress) :
///   seul le PIN le peut. Le code de contrainte n'est donc jamais désactivé ni affaibli.
/// - Le réglage ([_key]) vit dans le Keystore via [Account] : il est effacé par
///   `Account.wipeLocal` (`deleteAll`), par `AppLock.disable()` et après
///   `AppLock.bioMaxPinFailures` échecs de PIN consécutifs (voir `lock.dart`).
/// - Aucun log, aucune donnée biométrique : Android ne renvoie qu'un succès/échec.
class Biometric {
  static const _key = 'bio_enabled';
  static final _auth = LocalAuthentication();

  static Future<bool> enabled() async => (await Account.read(_key)) == '1';

  static Future<void> setEnabled(bool v) =>
      v ? Account.write(_key, '1') : Account.delete(_key);

  /// Vrai si l'appareil a un capteur ET au moins une biométrie enrôlée.
  static Future<bool> available() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      if (!await _auth.canCheckBiometrics) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } on PlatformException {
      return false;
    }
  }

  /// Affiche le prompt système. [biometricOnly] : pas de repli sur le code/schéma de l'appareil
  /// (le repli, c'est le PIN de Murmure).
  static Future<BioResult> authenticate(String reason) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        authMessages: const [
          AndroidAuthMessages(
            signInTitle: 'Déverrouiller Murmure',
            biometricHint: '',
            biometricNotRecognized: 'Non reconnu, réessayez',
            biometricSuccess: 'Reconnu',
            cancelButton: 'Utiliser le code',
          ),
        ],
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          useErrorDialogs: false,
        ),
      );
      return ok ? BioResult.success : BioResult.fallback;
    } on PlatformException catch (e) {
      // Codes de local_auth (auth_error.dart) : 'LockedOut' / 'PermanentlyLockedOut'.
      if (e.code == 'LockedOut') return BioResult.lockedTemporarily;
      if (e.code == 'PermanentlyLockedOut') return BioResult.lockedPermanently;
      return BioResult.fallback;
    }
  }
}
