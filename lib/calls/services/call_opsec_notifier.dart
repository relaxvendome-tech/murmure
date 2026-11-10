import 'dart:typed_data';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../account.dart';
import '../../lock.dart';

/// MISE À JOUR (Google Play) : en mode discret, le texte est désormais NEUTRE (« Rappel —
/// Nouvelle activité. ») au lieu d'imiter une calculatrice, pour ne pas enfreindre la policy
/// « Impersonation » (Android affiche de toute façon le nom réel de l'appli dans l'en-tête).
/// Les mentions « calculatrice » ci-dessous décrivent l'ancien comportement.
///
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

  // v3 : les noms/descriptions des canaux v2 (« Activité (mode discret) », « … en mode discret »)
  // révélaient eux-mêmes l'existence du mode discret dans Réglages > Notifications. Un nom de
  // canal étant figé à sa création, on change d'identifiant et on supprime les anciens dans init().
  static const _calcChannelId = 'discreet_activity_v3';
  static const _honestChannelId = 'murmure_calls';
  static const _notificationId = 4143;
  static const _calcRingChannelId = 'discreet_ring_v3';

  /// Anciens canaux d'appel à supprimer. Volontairement SANS `sys_calc_cache_v1`/`sys_calc_bg_v1`,
  /// toujours utilisés par le mesh (`lib/mesh/mesh_opsec_notifier.dart`, `MeshForegroundService`).
  /// Supprimer un canal inexistant est sans effet côté Android.
  static const _legacyChannelIds = <String>[
    'discreet_activity_v2',
    'discreet_ring_v2',
    'discreet_activity_v1',
    'discreet_ring_v1',
    'discreet_activity',
    'discreet_ring',
  ];
  static const _honestRingChannelId = 'murmure_incoming_calls';
  static const _ringingNotificationId = 4144;

  /// Tous les identifiants de canaux d'appel connus de ce fichier : canaux actuels puis anciens
  /// (supprimés par [init]). Exposé pour qu'un autre module (purge globale, tests) n'ait pas à
  /// dupliquer ces chaînes.
  static const List<String> allChannelIds = <String>[
    _calcChannelId,
    _honestChannelId,
    _calcRingChannelId,
    _honestRingChannelId,
    ..._legacyChannelIds,
  ];

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void>? _initFuture;

  /// À appeler une fois au démarrage, dans `main()` avant `runApp` : initialise le plugin et
  /// purge les anciens canaux, SANS demander la permission POST_NOTIFICATIONS (une boîte de
  /// dialogue système par-dessus l'écran de verrou/calculatrice trahirait l'appli — voir
  /// [requestPermission], appelée après déverrouillage). Idempotent et sûr en appels
  /// concurrents (un seul `initialize`). Best-effort : ne lève jamais.
  static Future<void> init() {
    if (_initialized) return Future<void>.value();
    return _initFuture ??= _doInit();
  }

  static Future<void> _doInit() async {
    try {
      await _plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ));
      // Prêt dès que le plugin est initialisé : la purge des anciens canaux ci-dessous n'est
      // qu'un nettoyage et ne doit pas retarder ni empêcher les notifications.
      _initialized = true;
      final android = _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      for (final id in _legacyChannelIds) {
        try {
          await android?.deleteNotificationChannel(id);
        } catch (_) {
          // Best-effort, canal déjà absent ou API indisponible.
        }
      }
    } catch (_) {
      // Pas de notification possible sur cet appareil/cette version d'Android : tant pis, le
      // reste de l'appli (et le fail-closed de CallPolicy) n'en dépend pas. On autorise une
      // nouvelle tentative au prochain appel.
      if (!_initialized) _initFuture = null;
    }
  }

  /// Demande POST_NOTIFICATIONS (Android 13+). À appeler APRÈS un déverrouillage réussi, jamais
  /// avant : la boîte de dialogue système nomme l'appli réelle. Initialise d'abord le plugin si
  /// nécessaire. Best-effort : ne lève jamais.
  static Future<void> requestPermission() async {
    await init();
    if (!_initialized) return;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
    } catch (_) {
      // Permission refusée ou API indisponible : les notifications resteront muettes.
    }
  }

  /// Garantit que le plugin est prêt avant un `show` : si [init] a été lancé sans être attendu
  /// (ou pas lancé du tout), on l'attend ici plutôt que de perdre la notification.
  static Future<bool> _ensureReady() async {
    if (_initialized) return true;
    await init();
    return _initialized;
  }

  static Future<void> notifyMissedCall() async {
    if (!await _ensureReady()) return;
    final calcMode = await AppLock.calcMode();
    try {
      if (calcMode) {
        await _plugin.show(
          _notificationId,
          'Rappel',
          'Nouvelle activité.',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _calcChannelId,
              'Activité',
              channelDescription: 'Activité',
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

  /// Sonnerie d'appel entrant, appelée par `MurmureWebRTCDelegate.playRingtone()` (le SDK
  /// l'invoque juste avant `handleNewCall`, et appelle `stopRingtone()` sur décroché, raccroché,
  /// réponse depuis un autre appareil ou fin d'appel — voir `voip.dart`/`call_session.dart` au tag
  /// v0.29.0). Implémentée comme une notification sur un canal dédié plutôt qu'avec un lecteur
  /// audio : aucune dépendance de plus, et Android respecte nativement le mode silencieux/Ne pas
  /// déranger de l'utilisateur, ce qu'un lecteur audio maison contournerait.
  ///
  /// - Mode normal : sonnerie système de l'appareil, en boucle (FLAG_INSISTENT) jusqu'à
  ///   [stopIncomingCall] ou 60 s au plus (filet si `stopRingtone` n'était jamais appelé).
  ///   Le texte ne contient JAMAIS le nom de l'appelant : il serait lisible écran verrouillé.
  /// - Mode discret : aucune sonnerie (une sonnerie d'appel venant d'une « calculatrice » serait
  ///   elle-même un signal), vibration seule et texte camouflé.
  ///
  /// LIMITE HONNÊTE : le son d'un canal Android est figé à sa création ; le rendu réel (sonnerie,
  /// boucle, Ne pas déranger) n'a pas été vérifié sur un appareil depuis ce bac à sable.
  static Future<void> notifyIncomingCall() async {
    if (!await _ensureReady()) return;
    final calcMode = await AppLock.calcMode();
    try {
      if (calcMode) {
        await _plugin.show(
          _ringingNotificationId,
          'Rappel',
          'Nouvelle activité.',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _calcRingChannelId,
              'Rappels',
              channelDescription: 'Rappels',
              importance: Importance.high,
              priority: Priority.high,
              playSound: false,
              enableVibration: true,
              enableLights: false,
              autoCancel: true,
              timeoutAfter: 60000,
            ),
          ),
        );
      } else {
        await _plugin.show(
          _ringingNotificationId,
          'Murmure',
          'Appel entrant',
          NotificationDetails(
            android: AndroidNotificationDetails(
              _honestRingChannelId,
              'Appels entrants',
              channelDescription: 'Sonnerie des appels audio/vidéo entrants',
              importance: Importance.max,
              priority: Priority.max,
              category: AndroidNotificationCategory.call,
              visibility: NotificationVisibility.private,
              playSound: true,
              sound: const UriAndroidNotificationSound('content://settings/system/ringtone'),
              audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
              enableVibration: true,
              ongoing: true,
              autoCancel: false,
              timeoutAfter: 60000,
              // FLAG_INSISTENT (0x4) : le son boucle jusqu'à l'annulation de la notification.
              additionalFlags: Int32List.fromList(const <int>[4]),
            ),
          ),
        );
      }
    } catch (_) {
      // Best-effort : l'écran d'appel entrant (handleNewCall) s'affiche quand même.
    }
  }

  static Future<void> stopIncomingCall() async {
    try {
      await _plugin.cancel(_ringingNotificationId);
    } catch (_) {
      // Au pire, timeoutAfter coupe la sonnerie au bout de 60 s.
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
