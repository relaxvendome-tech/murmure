import 'package:matrix/matrix.dart';

/// Statut de vérification des appareils d'un utilisateur, à partir de ses [devices] connus.
///
/// `null` : aucune clé d'appareil connue (inconnu, pas "non vérifié") ; `true` : tous les
/// appareils connus sont vérifiés ; `false` : au moins un ne l'est pas. Fonction pure, extraite
/// à l'identique de `_deviceVerificationStatus` (rooms_screen.dart).
bool? deviceVerificationStatusOf(Iterable<DeviceKeys>? devices) {
  if (devices == null || devices.isEmpty) return null;
  return devices.every((d) => d.verified);
}

/// Idem pour l'utilisateur [userId] d'après `client.userDeviceKeys`.
bool? userVerificationStatus(Client client, String userId) =>
    deviceVerificationStatusOf(client.userDeviceKeys[userId]?.deviceKeys.values);
