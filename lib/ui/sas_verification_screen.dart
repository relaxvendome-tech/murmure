import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

/// Vérification interactive SAS (comparaison d'émojis/chiffres entre deux appareils) — voir
/// `docs/E2EE_VERIFICATION.md` pour l'API vérifiée directement contre le code source de
/// `matrix-dart-sdk` (pas devinée depuis une documentation ou une IA externe) qui a permis cet
/// écran : [KeyVerificationState], `startVerification()`, `acceptVerification()`, `acceptSas()`,
/// `rejectSas()`, `cancel()`, et le champ `onUpdate` (callback simple, pas un `Stream`) par lequel
/// le SDK notifie chaque changement d'état.
///
/// Contrairement à la vérification manuelle d'empreinte (`device_verification_screen.dart`), le
/// SAS authentifie aussi l'absence d'un adversaire actif AU MOMENT de la vérification elle-même
/// (attaque de l'homme du milieu sur l'échange de clés), pas seulement l'identité statique de la
/// clé — c'est la défense standard contre un serveur compromis qui injecterait un appareil
/// supplémentaire sur le compte d'un correspondant.
///
/// Reçoit un [KeyVerification] déjà créé (par `startVerification()` côté initiateur, ou reçu via
/// `client.onKeyVerificationRequest` puis `acceptVerification()` côté destinataire — ce deuxième
/// cas est géré par [VerificationManager], pas par cet écran). Cet écran se contente d'afficher
/// l'état courant et de réagir aux boutons ; toute la logique de protocole reste dans le SDK.
class SasVerificationScreen extends StatefulWidget {
  const SasVerificationScreen({super.key, required this.request, required this.peerName});

  final KeyVerification request;
  final String peerName;

  @override
  State<SasVerificationScreen> createState() => _SasVerificationScreenState();
}

class _SasVerificationScreenState extends State<SasVerificationScreen> {
  @override
  void initState() {
    super.initState();
    // Seul mécanisme de notification réel de ce type (vérifié dans le code source : un simple
    // champ `void Function()? onUpdate`, pas un Stream) — voir le commentaire de classe ci-dessus.
    widget.request.onUpdate = () {
      if (mounted) setState(() {});
    };
    // Si on arrive ici avec une demande déjà acceptée côté destinataire (voir VerificationManager)
    // mais pas encore côté choix de méthode, rien à faire de plus : le SDK progresse seul dès que
    // les événements `m.key.verification.*` arrivent par la synchronisation habituelle.
  }

  @override
  void dispose() {
    // Ne jamais laisser un callback pointer vers un State détruit ; ne PAS annuler la vérification
    // elle-même ici (l'utilisateur a pu juste tourner l'écran ou changer d'appli temporairement).
    widget.request.onUpdate = null;
    super.dispose();
  }

  Future<void> _cancel() async {
    try {
      await widget.request.cancel();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _confirmMatch() async {
    try {
      await widget.request.acceptSas();
    } catch (_) {}
  }

  Future<void> _rejectMatch() async {
    try {
      await widget.request.rejectSas();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = widget.request.state;

    return Scaffold(
      appBar: AppBar(
        title: Text('Vérifier ${widget.peerName}'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: _cancel),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Center(child: _body(state, scheme)),
        ),
      ),
    );
  }

  Widget _body(KeyVerificationState state, ColorScheme scheme) {
    switch (state) {
      case KeyVerificationState.askAccept:
      case KeyVerificationState.waitingAccept:
      case KeyVerificationState.askChoice:
      case KeyVerificationState.askSSSS:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(
              'En attente de ${widget.peerName}…',
              style: TextStyle(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        );

      case KeyVerificationState.askSas:
        final emojis = widget.request.sasEmojis;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Comparez ces émojis à voix haute avec ${widget.peerName}. L\'ordre compte.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 18,
              runSpacing: 18,
              children: [
                for (final e in emojis)
                  Column(
                    children: [
                      Text(e.emoji, style: const TextStyle(fontSize: 36)),
                      const SizedBox(height: 4),
                      Text(e.name, style: const TextStyle(fontSize: 11)),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 32),
            Text(
              'Ne confirmez que si CHAQUE émoji correspond exactement, dans le même ordre, sur '
              'les deux appareils. En cas de doute, refusez.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(onPressed: _rejectMatch, child: const Text('Ça ne correspond pas')),
                const SizedBox(width: 12),
                FilledButton(onPressed: _confirmMatch, child: const Text('Ça correspond')),
              ],
            ),
          ],
        );

      case KeyVerificationState.waitingSas:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(
              'En attente de la confirmation de ${widget.peerName}…',
              style: TextStyle(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        );

      case KeyVerificationState.done:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_user, color: Colors.green, size: 56),
            const SizedBox(height: 16),
            Text(
              '${widget.peerName} est vérifié.',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Terminer'),
            ),
          ],
        );

      case KeyVerificationState.error:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.gpp_bad_outlined, color: scheme.error, size: 56),
            const SizedBox(height: 16),
            Text(
              'Vérification annulée ou échouée. Si ce n\'est pas vous qui avez annulé, ne faites '
              'pas confiance à cet appareil tant que la vérification n\'a pas réussi.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Fermer'),
            ),
          ],
        );

      case KeyVerificationState.showQRSuccess:
      case KeyVerificationState.confirmQRScan:
        // Variante QR non proposée par cet écran (pas de scanner dans ce dépôt pour l'instant,
        // voir docs/E2EE_VERIFICATION.md) : si jamais atteint, on annule proprement plutôt que de
        // rester bloqué sur un état que cette UI ne sait pas représenter.
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'La vérification par QR code n\'est pas prise en charge dans cette version.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _cancel, child: const Text('Annuler')),
          ],
        );
    }
  }
}
