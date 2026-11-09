import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../account.dart';
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
class MeshOpsecNotifier {
  MeshOpsecNotifier._();

  static const _calcChannelId = 'sys_calc_cache_v1';
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
      // Pas de requestNotificationsPermission ici : CallOpsecNotifier l'a déjà demandée au
      // démarrage de l'appli (une seule demande de permission Android, pas une par notifieur).
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
      final calcMode = await Account.read('calc_mode') == '1';
      if (calcMode) {
        await _plugin.show(
          _notificationId,
          'Calculatrice',
          'Cache de résultats mis à jour.',
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
