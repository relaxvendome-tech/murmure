import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../lock.dart';
import '../ui/sas_verification_screen.dart';

/// Écoute les demandes de vérification SAS entrantes (`client.onKeyVerificationRequest`) et
/// propose à l'utilisateur de les accepter — voir `docs/E2EE_VERIFICATION.md` pour l'API vérifiée
/// et `lib/ui/sas_verification_screen.dart` pour l'écran de comparaison d'émojis lui-même.
///
/// Construit une seule fois dans `main.dart`, aux côtés de [CallManager] et pour la même raison
/// structurelle : ce flux doit exister avant tout arbre de widgets, pour ne jamais manquer une
/// demande arrivée pendant le tout premier rendu.
///
/// Trouvé en audit interne (généralisation délibérée du correctif déjà fait pour les appels, voir
/// [AppLock.isUnlocked] et `calls/services/call_manager.dart`) : exactement le même risque de
/// contournement existait ici en germe — un `Navigator.push`/`showDialog` déclenché depuis un
/// flux hors widget-tree s'empile TOUJOURS par-dessus [LockGate], verrouillé ou pas, puisque ce
/// dernier n'est pas une frontière de navigation. Une demande de vérification affichée par-dessus
/// l'écran de verrou/calculatrice révélerait l'appli réelle en mode discret, même sans toucher au
/// chiffrement lui-même. Tant que l'appli est verrouillée, la demande est donc purement ignorée
/// ici : elle expire de son côté selon le délai normal du protocole `m.key.verification.request`
/// (géré entièrement par le SDK, pas par ce fichier), exactement comme un appel non décroché.
class VerificationManager {
  VerificationManager({required this.client, this.navigatorKey});

  final Client client;
  GlobalKey<NavigatorState>? navigatorKey;

  StreamSubscription<KeyVerification>? _sub;

  void start() {
    _sub?.cancel();
    _sub = client.onKeyVerificationRequest.stream.listen(_onRequest);
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }

  Future<void> _onRequest(KeyVerification request) async {
    if (!AppLock.isUnlocked) return; // voir le commentaire de classe ci-dessus

    final nav = navigatorKey?.currentState;
    final context = nav?.overlay?.context;
    if (nav == null || context == null) return;

    final peerName = request.room?.getLocalizedDisplayname() ?? request.userId;

    final accept = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Demande de vérification'),
        content: Text(
          '$peerName demande à vérifier cet appareil par comparaison d\'émojis. Acceptez '
          'seulement si vous êtes prêt à comparer tout de suite, en direct, avec cette personne.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Refuser'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Accepter'),
          ),
        ],
      ),
    );

    if (accept != true) {
      try {
        await request.rejectVerification();
      } catch (_) {}
      return;
    }

    try {
      await request.acceptVerification();
    } catch (_) {
      return;
    }
    if (nav.mounted) {
      nav.push(MaterialPageRoute(
        builder: (_) => SasVerificationScreen(request: request, peerName: peerName),
      ));
    }
  }
}
