import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../lock.dart';
import 'mesh.dart';

/// Notification système pour un message reçu via le mode maillé Bluetooth (voir `mesh.dart`),
/// camouflée en mode discret — même principe que `calls/services/call_opsec_notifier.dart`.
///
/// Trouvé en audit interne (revue multi-IA croisée) : `Mesh.instance.events` n'était écouté que
/// par `MeshScreen` (voir `ui/mesh_screen.dart`), qui ne s'abonne que lorsque cet écran est
/// effectivement ouvert. Un message reçu alors que l'utilisateur est sur un autre écran, ou que le
/// téléphone est en poche (service de premier plan actif, voir `mesh_foreground_service.dart`),
/// n'était donc jamais signalé : le message restait bien persisté en base (SQLCipher, voir
/// `Mesh._handleIncomingLocked`), mais invisible tant que l'utilisateur ne rouvrait pas
/// manuellement l'écran mesh. Pour un mode dont la raison d'être est précisément de fonctionner
/// « en arrière-plan, sans y penser » (coupure réseau, manifestation), c'est un défaut fonctionnel
/// majeur, pas un simple confort manquant.
///
/// Ce fichier s'abonne une fois, dès le démarrage de l'appli (voir `main.dart`), indépendamment de
/// l'écran affiché — exactement comme `CallOpsecNotifier` le fait pour les appels manqués.
///
/// LIMITE OPSEC DÉLIBÉRÉE : la notification n'affiche JAMAIS le texte du message ni un
/// identifiant de l'expéditeur — un écran verrouillé affiche en général les notifications même
/// sans déverrouillage, donc tout contenu ou identifiant mis ici fuiterait exactement ce que le
/// verrou PIN/calculatrice cherche à protéger. Seul le fait « quelque chose est arrivé » est
/// signalé, à charge pour l'utilisateur d'ouvrir l'écran mesh pour le lire.
///
/// POLICY PLAY « USURPATION » (corrigé) : en mode discret, la notification se présentait comme
/// « Calculatrice » (« Cache de résultats mis à jour. »), c.-à-d. comme une AUTRE appli — ce que la
/// policy Google Play « Impersonation » interdit, même de façon optionnelle (même raisonnement que
/// le retrait de l'activity-alias calculatrice, voir MainActivity.kt). Le mode discret affiche
/// désormais un texte NEUTRE (« Rappel » / « Nouvelle activité. ») et une petite icône monochrome
/// neutre (`res/drawable/ic_stat_neutral.xml`) : rien ne nomme Murmure ni ne se fait passer pour
/// une autre appli. Nouveau canal `discreet_bg_v2` (un nom de canal est figé à sa création),
/// l'ancien `sys_calc_cache_v1` est supprimé dans [init].
class MeshOpsecNotifier {
  MeshOpsecNotifier._();

  static const _calcChannelId = 'discreet_bg_v2';

  /// Anciens canaux à supprimer à l'initialisation : `sys_calc_cache_v1` (ancienne notification
  /// « Calculatrice » de ce fichier) et `sys_calc_bg_v1` (ancien canal du service de premier plan,
  /// MeshForegroundService.kt, qui le supprime aussi côté natif — doublon sans effet). Supprimer un
  /// canal inexistant est sans effet côté Android.
  static const _legacyChannelIds = <String>['sys_calc_cache_v1', 'sys_calc_bg_v1'];
  static const _honestChannelId = 'murmure_mesh';
  // 4143/4144 : appels (CallOpsecNotifier), 4145 : messages (MessageNotifier), 4150 : service de
  // premier plan du maillage (MeshForegroundService.kt). Avant : 4144, en collision avec l'appel
  // entrant (une notification écrasait/annulait l'autre).
  static const _notificationId = 4146;

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static StreamSubscription<MeshEvent>? _sub;

  /// À appeler une fois au démarrage (voir `main.dart`, juste après `CallOpsecNotifier.init()`).
  /// Best-effort, comme le reste des notifications de ce dépôt : un échec ici ne doit jamais faire
  /// planter l'appli ni bloquer le mode mesh lui-même.
  static Future<void> init() async {
    if (_initialized) return;
    try {
      await _plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ));
      // Pas de requestNotificationsPermission ici : cet init() tourne dans main() AVANT runApp,
      // donc avant l'onboarding et l'écran de verrou — une fenêtre système de permission à ce
      // moment serait mauvaise pour l'UX et révélatrice en mode discret. La permission
      // POST_NOTIFICATIONS (Android 13+) est demandée ailleurs : par CallOpsecNotifier.init()
      // (main.dart, `_PostUnlockInit`, seulement une fois connecté ET déverrouillé — donc PAS pour
      // un usage « mesh seul » sans compte), et par l'écran mesh lui-même au démarrage du mode
      // hors-ligne (ui/mesh_screen.dart, Permission.notification). Sans elle, show() échoue
      // silencieusement (try/catch de _notify) : le message reste en base, seul le signal manque.
      final android = _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      for (final id in _legacyChannelIds) {
        try {
          await android?.deleteNotificationChannel(id);
        } catch (_) {
          // Best-effort : canal déjà absent ou API indisponible.
        }
      }
      _initialized = true;
    } catch (_) {
      return;
    }
    _sub ??= Mesh.instance.events.listen((e) {
      if (e is MeshMessageReceived) {
        unawaited(_notify());
      }
    });
  }

  static Future<void> _notify() async {
    if (!_initialized) return;
    try {
      final calcMode = await AppLock.calcMode();
      if (calcMode) {
        await _plugin.show(
          _notificationId,
          'Rappel',
          'Nouvelle activité.',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _calcChannelId,
              'Activité en arrière-plan',
              channelDescription: 'Notifications discrètes',
              // Icône monochrome neutre (res/drawable/ic_stat_neutral.xml), référencée aussi par
              // MeshForegroundService.kt (R.drawable) : jamais retirée par le shrinker de ressources.
              icon: 'ic_stat_neutral',
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
          'Nouveau message (maillage Bluetooth)',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _honestChannelId,
              'Maillage Bluetooth',
              channelDescription: 'Messages reçus en mode hors-ligne',
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

  /// À appeler quand l'utilisateur ouvre effectivement l'écran mesh (voir `ui/mesh_screen.dart`,
  /// `initState`) : il vient de lire l'inbox, la notification en attente n'a plus de raison
  /// d'être affichée.
  static Future<void> clear() async {
    try {
      await _plugin.cancel(_notificationId);
    } catch (_) {
      // Rien à faire de plus, voir le commentaire de clear() dans CallOpsecNotifier.
    }
  }
}
