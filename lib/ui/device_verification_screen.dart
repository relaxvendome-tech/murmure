import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'sas_verification_screen.dart';

/// Vérification des appareils d'un contact — par empreinte (manuelle, hors bande) OU par SAS
/// (comparaison interactive d'émojis) — voir `docs/E2EE_VERIFICATION.md` pour le constat d'audit
/// initial et pour l'API SAS, désormais vérifiée directement contre le code source de
/// `matrix-dart-sdk` (tag `v0.29.0`, pas devinée depuis une documentation ou une IA externe).
///
/// Le SAS authentifie en plus l'absence d'un adversaire actif au moment même de l'échange de
/// clés — la comparaison d'empreinte seule ne protège pas contre ce cas précis. Les deux méthodes
/// restent proposées : le SAS suppose que le correspondant est disponible pour comparer en direct
/// tout de suite, l'empreinte peut se vérifier en différé (ex. lue par téléphone déjà authentifié).
///
/// Appareils marqués "vérifié" ici (par l'une ou l'autre méthode) : confiance réelle. Appareils
/// non marqués : toujours en confiance TOFU pure (le SDK les accepte et leur chiffre des messages
/// sans distinction) — ce que ce dépôt documentait déjà comme non résolu. Cet écran ne change PAS
/// ce que le SDK fait réellement avec un appareil non vérifié : il ne fait que rendre visible qui
/// a été vérifié ou pas, et proposer les deux moyens de le faire.
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

  // Évite de lancer deux demandes SAS en parallèle vers le même contact.
  bool _startingSas = false;

  /// Lance une vérification SAS vers [widget.userId] (pas vers un appareil précis : le SDK choisit
  /// l'appareil qui répond — voir `startVerification()` sur `DeviceKeysList`, docs/E2EE_VERIFICATION.md).
  /// `.verified` (affiché par [_DeviceTile]) reflète déjà `directVerified`, positionné par le SDK
  /// lui-même dès que le SAS réussit : pas de `setVerified()` manuel à faire ici, juste rafraîchir
  /// l'affichage au retour de [SasVerificationScreen].
  Future<void> _startSas() async {
    if (_startingSas) return;
    setState(() => _startingSas = true);
    try {
      final list = widget.client.userDeviceKeys[widget.userId];
      if (list == null) return;
      final request = await list.startVerification();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SasVerificationScreen(request: request, peerName: widget.displayName),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Impossible de démarrer la vérification : $e')),
      );
    } finally {
      if (mounted) setState(() => _startingSas = false);
    }
  }

  /// Regroupe une empreinte Ed25519 (base64, ~43 caractères) en blocs de 4 pour une comparaison
  /// visuelle plus facile. La casse est CONSERVÉE : le base64 y est sensible (« a » ≠ « A »),
  /// mettre en majuscules ferait accepter deux empreintes différentes comme identiques.
  String _formatFingerprint(String key) {
    final groups = <String>[];
    for (var i = 0; i < key.length; i += 4) {
      groups.add(key.substring(i, i + 4 > key.length ? key.length : i + 4));
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
          'correspond exactement (majuscules et minuscules comprises) :\n\n'
          '${_formatFingerprint(fingerprint)}\n\n'
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
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(verified
              ? 'Impossible de marquer l\'appareil comme vérifié. Réessayez.'
              : 'Impossible de retirer la vérification. Réessayez.'),
        ));
      }
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
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _startingSas ? null : _startSas,
              icon: _startingSas
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.emoji_emotions_outlined),
              label: const Text('Vérifier par émojis (SAS)'),
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
