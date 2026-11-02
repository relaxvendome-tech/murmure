import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../account.dart';

/// Notification d'appel manqué, adaptée au mode discret (voir `lib/stealth.dart` et
/// `ui/lock_screens.dart`) : camouflée en notification de calculatrice quand le mode discret est
/// actif, honnête (« Murmure — Appel manqué ») sinon.
///
/// Corrige une proposition reçue dans cette conversation (validée par l'utilisateur comme
/// direction produit — l'Option B, notification camouflée — mais dont le code devait être
/// revérifié avant d'être intégré) :
///
/// - Le hook d'origine écoutait `matrixClient.onRoomEvent` pour `m.call.hangup` et comparait au
///   `call_id` de `matrixClient.voip.currentSession` — ni l'un ni l'autre n'existe sous cette
///   forme dans `matrix-dart-sdk` à la version utilisée ici (`voip` n'a pas de propriété
///   `currentSession`), et cela réimplémentait par-dessus un mécanisme déjà géré par le SDK.
///   Remplacé : la détection se fait dans `CallSessionScreen` elle-même, en observant
///   `CallSession.onCallStateChanged` passer à `CallState.kEnded` sans jamais avoir été décrochée
///   — c'est l'écran qui sait réellement si l'appel entrant a été accepté ou non, pas un
///   événement brut reconstruit à la main.
/// - **Toujours** afficher le texte « Calculatrice » camouflé, même quand l'utilisateur utilise
///   Murmure ouvertement (mode discret désactivé), serait lui-même suspect : une appli de
///   messagerie affichant une notification parlant de « fonctions trigonométriques » attirerait
///   plus l'attention qu'elle n'en détournerait. Ce fichier n'utilise le camouflage calculatrice
///   QUE quand le mode discret est effectivement actif à l'instant de la notification, et bascule
///   sur un message honnête sinon — deux canaux de notification séparés en conséquence (un nom de
///   canal, une fois créé, reste visible dans les réglages Android même après l'annulation d'une
///   notification : autant qu'il porte un nom cohérent avec l'identité affichée de l'appli au
///   moment où il a été créé).
///
/// LIMITE HONNÊTE : l'icône de notification utilisée ici est celle de l'appli (`@mipmap/
/// ic_launcher`), pas une icône monochrome dédiée — Android affiche en général les petites icônes
/// de notification en silhouette blanche unie, donc le rendu réel à l'écran n'a pas été vérifié
/// visuellement sur un appareil. Personne dans ce bac à sable ne peut concevoir d'asset graphique
/// vérifié ; à contrôler vous-même avant de compter sur ce détail pour l'OPSEC.
class CallOpsecNotifier {
  CallOpsecNotifier._();

  static const _calcChannelId = 'sys_calc_sync_v1';
  static const _honestChannelId = 'murmure_calls';
  static const _notificationId = 4143;

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// À appeler une fois au démarrage (voir `main.dart`). Best-effort : une notification ratée ne
  /// doit jamais faire planter l'appli, seulement priver l'utilisateur de ce confort.
  static Future<void> init() async {
    if (_initialized) return;
    try {
      await _plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ));
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      _initialized = true;
    } catch (_) {
      // Pas de notification possible sur cet appareil/cette version d'Android : tant pis, le
      // reste de l'appli (et le fail-closed de CallPolicy) n'en dépend pas.
    }
  }

  static Future<void> notifyMissedCall() async {
    if (!_initialized) return;
    final calcMode = await Account.read('calc_mode') == '1';
    try {
      if (calcMode) {
        await _plugin.show(
          _notificationId,
          'Calculatrice',
          'Indexation des fonctions trigonométriques terminée.',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _calcChannelId,
              'Synchronisation arrière-plan',
              channelDescription: "Maintenance automatique de l'historique des calculs",
              importance: Importance.low,
              priority: Priority.low,
              playSound: false,
              enableVibration: false,
              enableLights: false,
            ),
          ),
        );
      } else {
        await _plugin.show(
          _notificationId,
          'Murmure',
          'Appel manqué',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _honestChannelId,
              'Appels',
              channelDescription: "Appels audio/vidéo manqués",
              importance: Importance.low,
              priority: Priority.low,
              playSound: false,
              enableVibration: false,
              enableLights: false,
            ),
          ),
        );
      }
    } catch (_) {
      // Best-effort, voir le commentaire de init().
    }
  }

  /// À appeler dès le déverrouillage réussi (voir `ui/lock_screens.dart`, les deux chemins
  /// `onUnlocked`/`onSuccess`) : fait disparaître la notification — camouflée ou honnête, les deux
  /// partagent le même [_notificationId], donc un seul `cancel` suffit — avant que l'interface
  /// interne ne s'affiche.
  static Future<void> clear() async {
    try {
      await _plugin.cancel(_notificationId);
    } catch (_) {
      // Rien à faire de plus : au pire, la notification reste visible une fraction de seconde
      // de plus — pas une régression de sécurité, juste un confort manqué.
    }
  }
}
