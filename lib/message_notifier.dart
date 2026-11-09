import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart';

import 'account.dart';
import 'ephemeral.dart';
import 'lock.dart';

/// Notifications locales de nouveaux messages, tant que le PROCESSUS de l'appli vit (premier plan,
/// ou arrière-plan avant que le système ne le tue).
///
/// LIMITES HONNÊTES (volontaires, cette passe) :
/// - Aucun service de premier plan persistant et aucun push (ni FCM ni UnifiedPush : choix de
///   confidentialité du projet). Une fois le processus tué par Android, plus aucune notification
///   de message n'arrive avant la prochaine ouverture ; les messages reçus entre-temps sont
///   signalés (au plus 24 h en arrière) au prochain rattrapage de sync.
/// - Un message chiffré qui ne peut pas être déchiffré (clé manquante) ne déclenche rien tant
///   qu'il n'est pas déchiffré (le SDK renvoie alors une mise à jour `decryptedTimelineQueue`).
/// - Le rendu réel (canal, écran verrouillé) n'a pas été vérifié sur appareil depuis ce bac à sable.
///
/// CONFIDENTIALITÉ : jamais le contenu, jamais le nom de l'expéditeur ni du salon : titre
/// « Murmure », corps « Nouveau message » / « N nouveaux messages », visibilité privée sur écran
/// verrouillé. Mode discret (`calc_mode == '1'`) : AUCUNE notification de message. Aucun log.
///
/// API du SDK (tag v0.29.0) : `Client.onEvent` (flux d'`EventUpdate`, il n'existe pas de
/// `onTimelineEvent` à cette version), `Client.ignoredUsers`, `Room.pushRuleState`,
/// `Room.membership`, `Event.fromJson`.
class MessageNotifier with WidgetsBindingObserver {
  MessageNotifier._();
  static final MessageNotifier instance = MessageNotifier._();

  static const _channelId = 'murmure_messages';
  static const _notificationId = 4145; // distinct de 4143/4144 (appels) et mesh
  static const _settingKey = 'notif_messages';
  static const _maxAge = Duration(hours: 24);
  static const _maxSeen = 500;

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// Conversation actuellement affichée à l'écran (ChatScreen) ; aucune notification pour elle.
  static String? _activeRoomId;
  static String? get activeRoomId => _activeRoomId;
  static set activeRoomId(String? id) {
    _activeRoomId = id;
    if (id != null) unawaited(clear()); // ouvrir une conversation = on a vu les nouveautés
  }

  static int _count = 0;
  static final Set<String> _seen = <String>{};
  static StreamSubscription<EventUpdate>? _sub;
  static Timer? _unlockWatch;
  static bool _observing = false;

  /// Réglage « Notifications de messages » : activé par défaut.
  static Future<bool> isEnabled() async => await Account.read(_settingKey) != '0';
  static Future<void> setEnabled(bool v) async {
    await Account.write(_settingKey, v ? '1' : '0');
    if (!v) await clear();
  }

  /// À appeler au démarrage (main.dart). Best-effort : ne doit jamais faire planter l'appli.
  static Future<void> init() async {
    if (_initialized) return;
    try {
      await _plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ));
      // La permission POST_NOTIFICATIONS est déjà demandée par CallOpsecNotifier.init().
      _initialized = true;
    } catch (_) {}
  }

  /// Branche l'écoute sur le client Matrix (une fois ; un nouvel appel remplace l'abonnement).
  static void attach(Client client) {
    _sub?.cancel();
    _sub = client.onEvent.stream.listen((u) => unawaited(_onUpdate(client, u)));
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(instance);
    }
  }

  static Future<void> _onUpdate(Client client, EventUpdate u) async {
    try {
      if (!_initialized) return;
      if (u.type != EventUpdateType.timeline &&
          u.type != EventUpdateType.decryptedTimelineQueue) {
        return;
      }
      // Les messages encore chiffrés (type m.room.encrypted) sont ignorés : on attend la version
      // déchiffrée, ce qui évite de notifier des réactions/éditions/états illisibles.
      if (u.content['type'] != EventTypes.Message) return;
      final room = client.getRoomById(u.roomID);
      if (room == null || room.membership != Membership.join) return;
      if (room.id == _activeRoomId) return;
      if (room.pushRuleState == PushRuleState.dontNotify) return; // salon mis en sourdine
      final event = Event.fromJson(u.content, room);
      if (event.senderId == client.userID) return;
      if (client.ignoredUsers.contains(event.senderId)) return; // utilisateur bloqué
      if (event.relationshipType == RelationshipTypes.edit) return; // édition, pas un nouveau message
      if (DateTime.now().difference(event.originServerTs) > _maxAge) return;
      if (isExpired(event, room)) return;
      if (!await isEnabled()) return;
      if (await Account.read('calc_mode') == '1') return; // mode discret : silence total
      if (!_seen.add(event.eventId)) return; // dédoublonnage (mise à jour déchiffrée, re-sync)
      if (_seen.length > _maxSeen) _seen.remove(_seen.first);
      _count++;
      await _show();
      _watchUnlock();
    } catch (_) {
      // Best-effort ; jamais de log (le contenu ne doit jamais fuiter).
    }
  }

  static Future<void> _show() async {
    await _plugin.show(
      _notificationId, // id fixe : une seule notification, mise à jour
      'Murmure',
      _count == 1 ? 'Nouveau message' : '$_count nouveaux messages',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Messages',
          channelDescription: 'Nouveaux messages (sans aperçu du contenu)',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.private,
          autoCancel: true,
        ),
      ),
    );
  }

  /// Efface la notification et remet le compteur à zéro.
  static Future<void> clear() async {
    _count = 0;
    _unlockWatch?.cancel();
    _unlockWatch = null;
    try {
      await _plugin.cancel(_notificationId);
    } catch (_) {}
  }

  /// Tant qu'une notification est affichée et que l'appli est au premier plan, l'efface dès que
  /// l'appli est déverrouillée (lock_screens.dart ne l'appelle pas : fichier hors périmètre).
  static void _watchUnlock() {
    _unlockWatch ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final foreground =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      if (foreground && AppLock.isUnlocked) unawaited(clear());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && AppLock.isUnlocked) unawaited(clear());
  }
}
