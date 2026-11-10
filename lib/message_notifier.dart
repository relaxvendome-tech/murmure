import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart';

import 'account.dart';
import 'ephemeral.dart';
import 'lock.dart';
import 'reactions.dart';

/// Notifications locales de nouveaux messages, tant que le PROCESSUS de l'appli vit (premier plan,
/// ou arrière-plan avant que le système ne le tue).
///
/// LIMITES HONNÊTES (volontaires, cette passe) :
/// - Aucun service de premier plan persistant et aucun push (ni FCM ni UnifiedPush : choix de
///   confidentialité du projet). Une fois le processus tué par Android, plus aucune notification
///   de message n'arrive avant la prochaine ouverture ; les messages reçus entre-temps sont
///   signalés (au plus 24 h en arrière) au prochain rattrapage de sync.
/// - Un message encore chiffré à sa réception (clé pas encore arrivée) notifie immédiatement un
///   « Nouveau message » générique : la mise à jour `decryptedTimelineQueue` envoyée plus tard par
///   le SDK est reconstruite SANS expéditeur (impossible d'exclure ses propres messages ou ceux d'un
///   utilisateur bloqué) et est donc ignorée. Contrepartie : un événement chiffré illisible peut
///   aussi notifier. Les réactions, elles, sont ignorées : leur relation `m.annotation` est en
///   clair (type `m.reaction`, ou `m.relates_to` recopié dans l'enveloppe `m.room.encrypted`).
/// - Rien n'est notifié pendant une synchronisation initiale (`Client.prevBatch == null` :
///   première connexion, ou vidage du cache après blocage/déblocage d'un utilisateur), sinon tout
///   l'historique récent déclencherait une rafale de fausses notifications.
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
      // Synchronisation initiale (connexion, clearCache après blocage/déblocage) : `prevBatch`
      // n'est affecté qu'APRÈS le traitement de la réponse /sync (même garde que le SDK pour les
      // événements d'appel). Lu avant tout `await`.
      if (client.prevBatch == null) return;
      // Seulement la timeline en direct. `decryptedTimelineQueue` est ignoré : son contenu est
      // reconstruit sans `sender` (voir l'en-tête) et le message a déjà notifié sous sa forme
      // chiffrée (dédoublonnage par eventId).
      if (u.type != EventUpdateType.timeline) return;
      final type = u.content['type'];
      if (type != EventTypes.Message && type != EventTypes.Encrypted) return;
      if (isAnnotationRelation(u.content['content'])) return; // réaction, pas un message
      final room = client.getRoomById(u.roomID);
      if (room == null || room.membership != Membership.join) return;
      if (room.id == _activeRoomId && _isForegroundUnlocked) return;
      if (room.pushRuleState == PushRuleState.dontNotify) return; // salon mis en sourdine
      final event = Event.fromJson(u.content, room);
      if (event.senderId == client.userID) return;
      if (client.ignoredUsers.contains(event.senderId)) return; // utilisateur bloqué
      if (event.relationshipType == RelationshipTypes.edit) return; // édition, pas un nouveau message
      // Demande de vérification d'appareil envoyée comme message : pas un message de conversation.
      if (event.content['msgtype'] == 'm.key.verification.request') return;
      if (DateTime.now().difference(event.originServerTs) > _maxAge) return;
      if (isExpired(event, room)) return;
      if (!await isEnabled()) return;
      if (await AppLock.calcMode()) return; // mode discret : silence total
      if (!_seen.add(event.eventId)) return; // dédoublonnage (re-sync)
      if (_seen.length > _maxSeen) _seen.remove(_seen.first);
      _count++;
      await _show();
      _watchUnlock();
    } catch (_) {
      // Best-effort ; jamais de log (le contenu ne doit jamais fuiter).
    }
  }

  /// Vrai si l'appli est au premier plan ET déverrouillée : seule situation où la conversation
  /// « active » est réellement sous les yeux de l'utilisateur.
  static bool get _isForegroundUnlocked =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed && AppLock.isUnlocked;

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
    _stopUnlockWatch();
    try {
      await _plugin.cancel(_notificationId);
    } catch (_) {}
  }

  /// Tant qu'une notification est affichée et que l'appli est au premier plan mais verrouillée,
  /// vérifie chaque seconde si elle a été déverrouillée (lock_screens.dart ne prévient pas : fichier
  /// hors périmètre) pour effacer la notification. Le minuteur n'existe QU'AU PREMIER PLAN : il est
  /// arrêté dès que l'appli passe en arrière-plan et relancé au retour (didChangeAppLifecycleState).
  /// Appli déjà déverrouillée au premier plan : rien à surveiller (la notification concerne une
  /// autre conversation et reste affichée).
  static void _watchUnlock() {
    if (_count == 0) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    if (AppLock.isUnlocked) return;
    _unlockWatch ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        _stopUnlockWatch();
      } else if (AppLock.isUnlocked) {
        unawaited(clear());
      }
    });
  }

  static void _stopUnlockWatch() {
    _unlockWatch?.cancel();
    _unlockWatch = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (AppLock.isUnlocked) {
        unawaited(clear()); // retour dans l'appli déverrouillée : nouveautés vues
      } else {
        _watchUnlock(); // surveille le déverrouillage, au premier plan seulement
      }
    } else {
      _stopUnlockWatch(); // aucun minuteur en arrière-plan
    }
  }
}
