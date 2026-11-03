import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

/// Vérification manuelle (par empreinte) des appareils d'un contact — voir
/// `docs/E2EE_VERIFICATION.md` pour le constat d'audit qui a mené à cet écran et pour ce qui
/// reste volontairement non fait.
///
/// LIMITE HONNÊTE : cet écran compare une empreinte Ed25519 affichée en clair, à vérifier
/// *hors bande* (en personne, par appel vocal déjà authentifié, etc.) — il n'y a PAS de
/// vérification interactive SAS (comparaison d'emojis entre les deux appareils). Le flux SAS de
/// `matrix-dart-sdk` (`DeviceKeys.startVerification()`, `KeyVerification`, `sasEmojis`,
/// `acceptSas()`...) a été consulté via la documentation publiée du paquet, mais ce bac à sable ne
/// permet pas d'accéder de façon fiable à la documentation strictement alignée sur la version
/// épinglée ici (`matrix: ^0.29.0`, résolu à `0.29.13`) : pub.dev a été constaté, pendant cette
/// même passe, en train de servir le contenu d'une version ultérieure bien plus récente sous une
/// URL censée correspondre à une ancienne version (`.../0.9.0/...` a renvoyé un contenu étiqueté
/// version 11.0.0). Implémenter le flux SAS sur la base d'une documentation dont on ne peut pas
/// garantir qu'elle correspond au code réellement résolu serait exactement le type d'erreur que ce
/// dépôt cherche à éviter (voir CLAUDE.md / l'historique de `build.gradle.kts`). Tant que cette
/// vérification de version n'est pas possible de façon fiable, seule la vérification manuelle
/// d'empreinte — dont l'API (`DeviceKeys.ed25519Key`, `.verified`, `.setVerified()`) est stable et
/// inchangée dans tout l'historique public du paquet consulté — est implémentée ici.
///
/// Appareils marqués "vérifié" ici : confiance réelle, basée sur une comparaison faite par
/// l'utilisateur. Appareils non marqués : toujours en confiance TOFU pure (le SDK les accepte et
/// leur chiffre des messages sans distinction) — ce que ce dépôt documentait déjà comme non
/// résolu. Cet écran ne change PAS ce que le SDK fait réellement avec un appareil non vérifié : il
/// ne fait que rendre visible, pour la première fois dans Murmure, qui a été vérifié ou pas.
class DeviceVerificationScreen extends StatefulWidget {
  const DeviceVerificationScreen({
    super.key,
    required this.client,
    required this.userId,
    required this.displayName,
  });

  final Client client;
  final String userId;
  final String displayName;

  @override
  State<DeviceVerificationScreen> createState() => _DeviceVerificationScreenState();
}

class _DeviceVerificationScreenState extends State<DeviceVerificationScreen> {
  // Évite un double-appui pendant qu'un setVerified() est en cours pour un appareil donné.
  String? _busyDeviceId;

  /// Regroupe une empreinte Ed25519 (base64, ~43 caractères) en blocs de 4 pour une comparaison
  /// visuelle plus facile — convention courante pour l'affichage d'empreintes de clé publique.
  String _formatFingerprint(String key) {
    final upper = key.toUpperCase();
    final groups = <String>[];
    for (var i = 0; i < upper.length; i += 4) {
      groups.add(upper.substring(i, i + 4 > upper.length ? upper.length : i + 4));
    }
    return groups.join(' ');
  }

  Future<void> _confirmAndSetVerified(DeviceKeys device) async {
    final fingerprint = device.ed25519Key;
    if (fingerprint == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmer la vérification'),
        content: Text(
          'Vous confirmez avoir comparé cette empreinte avec ${widget.displayName} par un canal '
          'différent de Murmure (en personne, par un appel déjà authentifié, etc.) et qu\'elle '
          'correspond exactement :\n\n${_formatFingerprint(fingerprint)}\n\n'
          'Ne confirmez que si vous avez vraiment fait cette comparaison — marquer un appareil '
          'comme vérifié sans l\'avoir fait ne protège de rien.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Ça correspond, vérifier'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _setVerified(device, true);
  }

  Future<void> _setVerified(DeviceKeys device, bool verified) async {
    final deviceId = device.deviceId;
    if (deviceId == null || _busyDeviceId != null) return;
    setState(() => _busyDeviceId = deviceId);
    try {
      await device.setVerified(verified);
    } finally {
      if (mounted) setState(() => _busyDeviceId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = widget.client.userDeviceKeys[widget.userId];
    final devices = list?.deviceKeys.values.toList() ?? [];

    return Scaffold(
      appBar: AppBar(title: Text('Appareils de ${widget.displayName}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: scheme.onSurfaceVariant, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Comparez l\'empreinte ci-dessous avec ${widget.displayName} par un moyen '
                    'autre que Murmure (en personne, de préférence) avant de marquer un appareil '
                    'comme vérifié. Un appareil non vérifié reste accepté par le chiffrement : '
                    'ceci ne fait qu\'afficher l\'état, pas bloquer les appareils inconnus.',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text(
                'Aucun appareil connu pour ${widget.displayName} pour l\'instant. Ouvrez ou '
                'continuez une conversation chiffrée avec cette personne, puis revenez sur cet '
                'écran.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            )
          else
            ...devices.map((device) => _DeviceTile(
                  device: device,
                  fingerprint: device.ed25519Key == null
                      ? null
                      : _formatFingerprint(device.ed25519Key!),
                  busy: _busyDeviceId == device.deviceId,
                  onVerify: () => _confirmAndSetVerified(device),
                  onUnverify: () => _setVerified(device, false),
                )),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.fingerprint,
    required this.busy,
    required this.onVerify,
    required this.onUnverify,
  });

  final DeviceKeys device;
  final String? fingerprint;
  final bool busy;
  final VoidCallback onVerify;
  final VoidCallback onUnverify;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final verified = device.verified;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  verified ? Icons.verified_user : Icons.gpp_maybe_outlined,
                  color: verified ? Colors.green : scheme.error,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    device.deviceDisplayName ?? device.deviceId ?? 'Appareil',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  verified ? 'Vérifié' : 'Non vérifié',
                  style: TextStyle(
                    color: verified ? Colors.green : scheme.error,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              fingerprint ?? 'Empreinte indisponible pour cet appareil',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13, letterSpacing: 0.5),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : (verified
                      ? TextButton(
                          onPressed: onUnverify,
                          child: const Text('Retirer la vérification'),
                        )
                      : FilledButton.tonal(
                          onPressed: fingerprint == null ? null : onVerify,
                          child: const Text('Vérifier'),
                        )),
            ),
          ],
        ),
      ),
    );
  }
}
