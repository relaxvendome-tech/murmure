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
/// API du SDK : `Client.onEvent` (flux d'`EventUpdate`), `Client.ignoredUsers`,
/// `Room.pushRuleState`, `Room.membership`, `Event.fromJson`.
///
/// Trouvé en audit interne (re-vérifié contre le SDK matrix-dart pinné, tag v16.0.2, après la
/// migration 0.29 -> 16 : `client.dart`) : le commentaire précédent affirmait qu'`onTimelineEvent`
/// n'existait pas « à cette version » (v0.29.0) pour justifier l'usage d'`onEvent` ci-dessous —
/// redevenu faux depuis, et trompeur tel quel. Au tag épinglé, `Client.onEvent`/`EventUpdate` sont
/// explicitement `@Deprecated` par le SDK lui-même, au profit de `onTimelineEvent`/`onHistoryEvent`
/// (flux d'`Event` déjà déchiffrés, avec expéditeur) et surtout d'`onNotification` (événements
/// post-déchiffrement qui DEVRAIENT déclencher une notification, déjà filtrés par les règles de
/// push Matrix via `pushruleEvaluator.match(...).notify` — ce qui couvrirait aussi la limite
/// documentée ci-dessus sur les messages encore chiffrés à la réception). `onEvent` reste
/// fonctionnellement correct au tag épinglé (toujours alimenté pour chaque mise à jour de timeline,
/// vérifié dans `client.dart`) : aucun changement de comportement ici. Migrer vers `onNotification`
/// serait une amélioration réelle, mais change la source de vérité des notifications (minuteur de
/// push rules côté SDK plutôt que la logique ad hoc ci-dessous) sans pouvoir être validée sur un
/// appareil réel depuis ce bac à sable — laissé pour une passe dédiée plutôt que fait à l'aveugle.
///
/// Logique pure (testable sans plugin ni client Matrix, voir test/message_notifier_test.dart) :
/// total des messages encore en attente de notification, par salon, après avoir marqué [roomId]
/// comme vu (ouverture de cette conversation). Les messages des AUTRES salons restent en
/// attente — [roomId] est le seul retiré du compte. Un [roomId] absent de [pending] ne change
/// rien à la somme (ouvrir un salon sans rien en attente ne doit rien effacer ailleurs).
int remainingAfterViewing(Map<String, int> pending, String roomId) {
  var total = 0;
  for (final entry in pending.entries) {
    if (entry.key == roomId) continue;
    total += entry.value;
  }
  return total;
}

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
    // Trouvé en audit interne : appelait auparavant `clear()` sans condition, qui efface LA
    // notification (unique, partagée entre salons, voir [_show]) ET remet `_count` à zéro —
    // ouvrir N'IMPORTE QUELLE conversation (même une sans aucun message en attente) effaçait donc
    // aussi le signal de messages reçus dans d'AUTRES salons restés non lus. Exemple concret :
    // deux messages arrivent, un dans le salon A et un dans le salon B ; l'utilisateur ouvre A (ou
    // même un salon C sans rien en attente) → la notification disparaissait entièrement, alors que
    // le message du salon B n'a jamais été vu. Seuls les messages DU salon ouvert sont maintenant
    // retirés de l'attente (voir [_markRoomSeen] et [remainingAfterViewing]) ; s'il en reste
    // ailleurs, la notification reste affichée avec un compte à jour plutôt que de disparaître.
    if (id != null) unawaited(_markRoomSeen(id));
  }

  static int _count = 0;
  static final Set<String> _seen = <String>{};
  /// Messages notifiés et pas encore vus, par salon (nombre, pas les identifiants : seul le
  /// décompte importe ici, [_seen] gère déjà le dédoublonnage par eventId). Vidé par [clear]
  /// (effacement global) ; un salon y est retiré par [_markRoomSeen] quand il est ouvert.
  static final Map<String, int> _pendingByRoom = <String, int>{};
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
      _pendingByRoom.update(room.id, (v) => v + 1, ifAbsent: () => 1);
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

  /// Efface la notification et remet le compteur à zéro (TOUS les salons : utilisé pour une
  /// remise à zéro globale, pas pour l'ouverture d'une conversation précise, voir
  /// [_markRoomSeen]).
  static Future<void> clear() async {
    _count = 0;
    _pendingByRoom.clear();
    _stopUnlockWatch();
    try {
      await _plugin.cancel(_notificationId);
    } catch (_) {}
  }

  /// Marque les messages de [roomId] comme vus (conversation ouverte) : retire SEULEMENT ce
  /// salon de l'attente (voir [remainingAfterViewing]). S'il ne reste rien en attente ailleurs, la
  /// notification est effacée comme avant ; sinon elle est réaffichée avec le compte restant,
  /// pour ne pas faire disparaître le signal de messages non vus dans d'autres salons.
  static Future<void> _markRoomSeen(String roomId) async {
    if (!_pendingByRoom.containsKey(roomId)) return; // rien en attente pour ce salon
    final remaining = remainingAfterViewing(_pendingByRoom, roomId);
    _pendingByRoom.remove(roomId);
    if (remaining == 0) {
      await clear();
      return;
    }
    _count = remaining;
    // L'utilisateur vient d'ouvrir une conversation : forcément au premier plan et déverrouillé,
    // aucune surveillance du déverrouillage à faire pour le compte restant.
    _stopUnlockWatch();
    try {
      await _show();
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
