import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
// Voir le commentaire équivalent dans ui/sas_verification_screen.dart : `KeyVerification` vit
// dans le barrel séparé `package:matrix/encryption.dart`, pas dans `package:matrix/matrix.dart`.
import 'package:matrix/encryption.dart';

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
/// chiffrement lui-même. Tant que l'appli est verrouillée, la demande n'affiche rien et est
/// annulée proprement (`cancel('m.user')`) : le demandeur n'attend pas indéfiniment.
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

  bool _isBlocked(String userId) {
    try {
      return client.ignoredUsers.contains(userId);
    } catch (_) {
      return false;
    }
  }

  Future<void> _onRequest(KeyVerification request) async {
    // Demande venant d'un utilisateur bloqué : rejetée d'office, sans aucune UI (même appli
    // verrouillée — le rejet n'affiche rien).
    if (_isBlocked(request.userId)) {
      try {
        await request.rejectVerification();
      } catch (_) {}
      return;
    }
    if (!AppLock.isUnlocked) {
      // Voir le commentaire de classe ci-dessus : aucune UI tant que verrouillé. La demande est en
      // plus annulée proprement (code utilisateur du SDK, comme [KeyVerification.rejectVerification])
      // au lieu de rester pendante côté demandeur jusqu'à expiration.
      try {
        await request.cancel('m.user');
      } catch (_) {}
      return;
    }

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

    if (accept != true || !AppLock.isUnlocked) {
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
    // L'appli a pu se reverrouiller pendant le dialogue ou l'acceptation réseau : jamais d'écran
    // SAS par-dessus le verrou — on annule alors la vérification déjà acceptée.
    if (!AppLock.isUnlocked || !nav.mounted) {
      try {
        await request.cancel('m.user');
      } catch (_) {}
      return;
    }
    nav.push(MaterialPageRoute(
      builder: (_) => SasVerificationScreen(request: request, peerName: peerName),
    ));
  }
}
