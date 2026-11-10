import 'dart:async';

import 'package:matrix/matrix.dart';

import 'account.dart';

/// Messages éphémères par conversation.
///
/// Réglage : événement d'état Matrix personnalisé `fr.murmure.ephemeral` (state_key ''), contenu
/// `{"ttl_seconds": int, "enabled_at_ms": int?}` (TTL 0 ou absent = désactivé).
/// `enabled_at_ms` = date (ms epoch) de la PREMIÈRE activation, conservée tant que le TTL reste
/// > 0 : changer la durée (1 jour → 1 h) ne doit pas rendre permanents les messages antérieurs au
/// changement. Absent lors d'une nouvelle activation : on prend alors l'horodatage serveur de
/// l'événement d'état (pas l'horloge locale, qui peut être fausse).
///
/// CONFIDENTIALITÉ : dans un salon chiffré, les événements d'état ne sont PAS chiffrés (seuls les
/// événements de timeline le sont). Le serveur voit donc la durée choisie, mais jamais le contenu
/// des messages.
///
/// LIMITES HONNÊTES : le serveur Conduit n'implémente pas la rétention serveur (MSC1763) ; la
/// suppression repose donc sur les clients Murmure : (1) chaque appareil MASQUE localement les
/// messages expirés ; (2) l'auteur d'un message le RÉDIGE (redactEvent) une fois expiré. Rien ne
/// protège contre une capture d'écran ou un client modifié. Aucun contenu de message n'est logué.
///
/// RÉACTIONS : elles ne sont PAS chiffrées (voir lib/reactions.dart). L'interface les désactive et
/// les masque dans un salon à messages éphémères ; le balayage rédige aussi les réactions expirées
/// de l'utilisateur (posées avant l'activation ou par un autre client).
const String kEphemeralEventType = 'fr.murmure.ephemeral';

/// Durées proposées dans l'interface : (libellé, secondes). 0 = désactivé.
const List<(String, int)> kEphemeralChoices = [
  ('Désactivé', 0),
  ('5 minutes', 300),
  ('1 heure', 3600),
  ('1 jour', 86400),
  ('1 semaine', 604800),
];

/// Libellé court d'une durée (pour les infobulles) ; durée hors liste : secondes brutes.
String ephemeralLabel(int ttlSeconds) {
  for (final c in kEphemeralChoices) {
    if (c.$2 == ttlSeconds) return c.$1;
  }
  return '$ttlSeconds s';
}

/// Logique pure d'expiration (testable sans serveur) : un message est expiré si son âge dépasse
/// STRICTEMENT le TTL. TTL <= 0 : jamais expiré. Âge négatif (horloge locale en retard sur le
/// serveur) : non expiré.
///
/// [enabledAt] : date d'activation du réglage. Un message ANTÉRIEUR n'expire jamais — activer
/// « 5 minutes » ne doit pas effacer rétroactivement tout l'historique (revue interne).
/// [kClockSkewTolerance] : marge contre une horloge locale en avance sur le serveur, qui
/// masquerait sinon un message à peine reçu (revue croisée Grok, vérifiée).
const Duration kClockSkewTolerance = Duration(seconds: 60);

/// TTL maximal accepté depuis le contenu d'état (un autre client peut écrire n'importe quoi).
const int kMaxTtlSeconds = 365 * 86400;

bool isExpiredAt({
  required DateTime originServerTs,
  required int ttlSeconds,
  required DateTime now,
  DateTime? enabledAt,
}) {
  if (ttlSeconds <= 0) return false;
  if (enabledAt != null && originServerTs.isBefore(enabledAt)) return false;
  return now.difference(originServerTs) > Duration(seconds: ttlSeconds) + kClockSkewTolerance;
}

/// Extrait un TTL valide d'un contenu d'état brut ; tout ce qui n'est pas un entier > 0 donne 0.
int parseTtlSeconds(Map<String, Object?>? content) {
  final v = content?['ttl_seconds'];
  if (v is int && v > 0) return v > kMaxTtlSeconds ? kMaxTtlSeconds : v;
  return 0;
}

/// Logique pure : date d'activation effective d'un contenu d'état [content] posé à
/// [originServerTs], connaissant le contenu de l'état qu'il REMPLACE ([prevContent], fourni par le
/// serveur dans `unsigned.prev_content` — exposé par le SDK v0.29.0 via `Event.prevContent`) et,
/// si connu, l'horodatage serveur de cet état précédent ([prevEventTs]).
///
/// `enabled_at_ms` est une valeur écrite par un CLIENT (donc par n'importe quel membre autorisé à
/// changer ce réglage) : sans contrôle, un contact pourrait publier une date très ancienne et faire
/// expirer (masquer, puis rédiger chez chacun) tout l'historique de la conversation. Il n'est donc
/// retenu que s'il est un entier > 0, NON POSTÉRIEUR à l'événement, ET :
/// - l'état précédent avait un TTL > 0 et portait EXACTEMENT le même `enabled_at_ms` (simple
///   changement de durée, la date de première activation est reconduite) ; ou
/// - l'état précédent avait un TTL > 0 sans `enabled_at_ms` (première activation, datée par son
///   horodatage serveur), et la valeur n'est pas antérieure à [prevEventTs] (connu).
/// Dans tous les autres cas (activation depuis un état désactivé ou absent, valeur différente,
/// horodatage précédent inconnu) : [originServerTs], l'horodatage serveur de l'événement.
DateTime resolveEnabledAt(
  Map<String, Object?>? content,
  DateTime originServerTs, {
  Map<String, Object?>? prevContent,
  DateTime? prevEventTs,
}) {
  final v = content?['enabled_at_ms'];
  if (v is! int || v <= 0) return originServerTs;
  final at = DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);
  if (at.isAfter(originServerTs)) return originServerTs;
  if (parseTtlSeconds(prevContent) <= 0) return originServerTs;
  final prevV = prevContent?['enabled_at_ms'];
  if (prevV is int && prevV > 0) return prevV == v ? at : originServerTs;
  if (prevEventTs != null && !at.isBefore(prevEventTs)) return at;
  return originServerTs;
}

/// Logique pure : applique le plancher local d'un salon (date à laquelle CET appareil a résolu
/// pour la première fois un TTL > 0, voir [EphemeralFloors]) : la date effective ne peut jamais
/// être antérieure au plancher.
DateTime applyEnabledAtFloor(DateTime resolved, DateTime? floor) =>
    floor != null && floor.isAfter(resolved) ? floor : resolved;

/// Logique pure : action à mener sur le plancher local d'un salon, selon le TTL courant.
/// - TTL <= 0 : effacer le plancher s'il existe (`(clear: true, write: null)`).
/// - TTL > 0 sans plancher : l'écrire avec la date résolue (`write`).
/// - TTL > 0 avec plancher : rien.
({bool clear, DateTime? write}) floorUpdate({
  required int ttlSeconds,
  required DateTime? currentFloor,
  required DateTime? resolved,
}) {
  if (ttlSeconds <= 0) return (clear: currentFloor != null, write: null);
  if (currentFloor == null && resolved != null) return (clear: false, write: resolved);
  return (clear: false, write: null);
}

/// Logique pure : contenu d'état à publier pour passer à [ttlSeconds], connaissant l'état
/// précédent ([prevContent], et sa date d'activation résolue [prevEnabledAt]).
/// - TTL 0 : désactivation, aucune date conservée (une réactivation repartira de zéro).
/// - TTL > 0 et TTL précédent > 0 avec date connue : la date de première activation est conservée.
/// - Sinon (nouvelle activation) : pas de `enabled_at_ms`, l'horodatage serveur fera foi.
Map<String, Object?> buildEphemeralContent({
  required int ttlSeconds,
  Map<String, Object?>? prevContent,
  DateTime? prevEnabledAt,
}) {
  final ttl = ttlSeconds.clamp(0, kMaxTtlSeconds);
  if (ttl <= 0) return {'ttl_seconds': 0};
  if (parseTtlSeconds(prevContent) > 0 && prevEnabledAt != null) {
    return {'ttl_seconds': ttl, 'enabled_at_ms': prevEnabledAt.millisecondsSinceEpoch};
  }
  return {'ttl_seconds': ttl};
}

/// Plancher local par salon (clé `eph_floor_<roomId>` dans le stockage sécurisé via [Account]) :
/// écrit la première fois que cet appareil observe un TTL > 0, effacé quand le TTL repasse à 0.
/// Empêche qu'un état ultérieur (même accepté par [resolveEnabledAt]) recule la date d'activation
/// en deçà de ce que cet appareil a déjà vu. Cache mémoire lu de façon synchrone par
/// [ephemeralEnabledAt] ; chargé/mis à jour par [refreshEphemeralState].
class EphemeralFloors {
  EphemeralFloors._();
  static final Map<String, DateTime?> _floors = {};

  /// Horodatages serveur des états précédents (par event id), récupérés à la demande.
  static final Map<String, DateTime> _prevTs = {};

  static String key(String roomId) => 'eph_floor_$roomId';
  static DateTime? floorOf(String roomId) => _floors[roomId];
}

Map<String, Object?>? _prevContentOf(Event st) {
  final p = st.prevContent;
  return p == null ? null : Map<String, Object?>.from(p);
}

String? _replacesStateOf(Event st) {
  final r = st.unsigned?['replaces_state'];
  return r is String && r.isNotEmpty ? r : null;
}

DateTime? _resolvedWithoutFloor(Room room) {
  final st = room.getState(kEphemeralEventType);
  if (st is! Event) return null;
  final prevId = _replacesStateOf(st);
  return resolveEnabledAt(
    st.content,
    st.originServerTs,
    prevContent: _prevContentOf(st),
    prevEventTs: prevId == null ? null : EphemeralFloors._prevTs[prevId],
  );
}

/// Date de première activation EFFECTIVE du réglage actuel (voir [resolveEnabledAt], bornée par le
/// plancher local), ou null si inconnue (état « stripped » d'une invitation).
DateTime? ephemeralEnabledAt(Room room) {
  final resolved = _resolvedWithoutFloor(room);
  if (resolved == null) return null;
  return applyEnabledAtFloor(resolved, EphemeralFloors.floorOf(room.id));
}

/// Met à jour (best-effort, ne lève jamais) l'horodatage de l'état précédent si nécessaire, puis
/// le plancher local du salon. À appeler à l'ouverture d'une conversation et à chaque balayage.
Future<void> refreshEphemeralState(Room room) async {
  try {
    final st = room.getState(kEphemeralEventType);
    final ttl = parseTtlSeconds(st?.content);
    if (st is Event && ttl > 0) {
      final prevId = _replacesStateOf(st);
      final prev = _prevContentOf(st);
      final needsPrevTs = prevId != null &&
          !EphemeralFloors._prevTs.containsKey(prevId) &&
          parseTtlSeconds(prev) > 0 &&
          prev?['enabled_at_ms'] is! int &&
          st.content['enabled_at_ms'] is int;
      if (needsPrevTs && prevId != null) {
        try {
          final ev = await room.client.getOneRoomEvent(room.id, prevId);
          EphemeralFloors._prevTs[prevId] = ev.originServerTs;
        } catch (_) {
          // Inconnu : resolveEnabledAt retombera sur l'horodatage de l'événement courant.
        }
      }
    }
    final k = EphemeralFloors.key(room.id);
    if (!EphemeralFloors._floors.containsKey(room.id)) {
      final raw = await Account.read(k);
      final ms = raw == null ? null : int.tryParse(raw);
      EphemeralFloors._floors[room.id] =
          ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    }
    final upd = floorUpdate(
      ttlSeconds: ttl,
      currentFloor: EphemeralFloors._floors[room.id],
      resolved: _resolvedWithoutFloor(room),
    );
    if (upd.clear) {
      await Account.delete(k);
      EphemeralFloors._floors[room.id] = null;
    } else if (upd.write != null) {
      await Account.write(k, '${upd.write!.millisecondsSinceEpoch}');
      EphemeralFloors._floors[room.id] = upd.write;
    }
  } catch (_) {
    // Stockage indisponible : le plancher sera retenté au prochain appel.
  }
}

/// TTL (secondes) configuré pour cette conversation ; 0 = désactivé.
int ephemeralTtlSeconds(Room room) =>
    parseTtlSeconds(room.getState(kEphemeralEventType)?.content);

/// Publie le réglage dans la conversation (tous les participants le voient). Lève en cas d'erreur
/// réseau/serveur (`ErrorResponse`) : à gérer par l'appelant. Nécessite le droit d'envoyer cet
/// événement d'état (voir `Room.canChangeStateEvent`).
Future<void> setEphemeralTtl(Room room, int ttlSeconds) async {
  await room.client.setRoomStateWithKey(
    room.id,
    kEphemeralEventType,
    '',
    buildEphemeralContent(
      ttlSeconds: ttlSeconds,
      prevContent: room.getState(kEphemeralEventType)?.content,
      // Date résolue SANS le plancher local : c'est la valeur que les autres appareils sauront
      // valider (identique à l'état précédent) ; chacun applique ensuite son propre plancher.
      prevEnabledAt: _resolvedWithoutFloor(room),
    ),
  );
}

/// Vrai si [event] doit être masqué localement dans [room] (messages des autres compris).
bool isExpired(Event event, Room room, {DateTime? now}) => isExpiredAt(
      originServerTs: event.originServerTs,
      ttlSeconds: ephemeralTtlSeconds(room),
      now: now ?? DateTime.now(),
      enabledAt: ephemeralEnabledAt(room),
    );

/// Pagination du balayage : au plus 50 pages de 100 événements par conversation et par balayage.
const int kSweepMaxPages = 50;
const int kSweepPageSize = 100;

/// Logique pure : événement à rédiger par le balayage — message OU réaction (`m.reaction`, envoyée
/// EN CLAIR par le SDK, voir lib/reactions.dart) de l'utilisateur [me], déjà envoyé, non rédigé,
/// et expiré.
bool shouldSweep({
  required String type,
  required String senderId,
  required String me,
  required bool redacted,
  required bool sent,
  required bool expired,
}) =>
    (type == EventTypes.Message || type == EventTypes.Reaction) &&
    senderId == me &&
    !redacted &&
    sent &&
    expired;

/// Logique pure : borne en deçà de laquelle la pagination du balayage peut s'arrêter. Tout
/// événement antérieur à l'activation ([enabledAt]) n'expire jamais ; tout événement antérieur à
/// [handledBefore] (mémorisé après un balayage COMPLET et sans échec du même réglage) était déjà
/// expiré lors de ce balayage et a donc déjà été rédigé. La borne retenue est la plus récente.
DateTime? sweepStopBefore({DateTime? enabledAt, DateTime? handledBefore}) {
  if (enabledAt == null) return handledBefore;
  if (handledBefore == null) return enabledAt;
  return handledBefore.isAfter(enabledAt) ? handledBefore : enabledAt;
}

/// Logique pure : date sous laquelle tout est traité après un balayage complet effectué à [now] :
/// un événement antérieur à `now - ttl - tolérance` était expiré à [now].
DateTime handledBeforeAfterSweep(DateTime now, int ttlSeconds) =>
    now.subtract(Duration(seconds: ttlSeconds) + kClockSkewTolerance);

/// Service qui rédige périodiquement les messages et réactions expirés ENVOYÉS PAR L'UTILISATEUR.
class EphemeralService {
  EphemeralService._();
  static final EphemeralService instance = EphemeralService._();

  Timer? _timer;
  Client? _client;
  bool _sweeping = false;
  final Set<String> _inFlight = {};

  /// Par salon : (réglage TTL + date d'activation) du dernier balayage complet, et date sous
  /// laquelle tout a déjà été traité. Évite de recharger jusqu'à 5000 événements toutes les 60 s.
  final Map<String, ({String setting, DateTime handledBefore})> _progress = {};

  /// Démarre (idempotent) le balayage toutes les 60 s pour [client].
  void start(Client client, {Duration interval = const Duration(seconds: 60)}) {
    if (_timer != null && identical(_client, client)) return;
    _timer?.cancel();
    _client = client;
    _progress.clear();
    _timer = Timer.periodic(interval, (_) => unawaited(sweepAll()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _client = null;
    _progress.clear();
  }

  /// Balaye toutes les conversations ayant un TTL actif. Ne lève jamais.
  Future<void> sweepAll() async {
    final client = _client;
    if (client == null || _sweeping) return;
    _sweeping = true;
    try {
      for (final room in List<Room>.from(client.rooms)) {
        if (room.membership != Membership.join) continue;
        await sweepRoom(room);
      }
    } catch (_) {
      // Jamais de plantage ; nouvelle tentative au prochain tour.
    } finally {
      _sweeping = false;
    }
  }

  /// Rédige les messages et réactions de l'utilisateur expirés dans [room].
  /// Hors ligne / erreur serveur : abandonné silencieusement, réessayé au prochain balayage.
  Future<void> sweepRoom(Room room) async {
    await refreshEphemeralState(room);
    final ttl = ephemeralTtlSeconds(room);
    if (ttl <= 0) {
      _progress.remove(room.id);
      return;
    }
    final me = room.client.userID;
    if (me == null) return;
    Timeline? timeline;
    try {
      timeline = await room.getTimeline();
      final enabledAt = ephemeralEnabledAt(room);
      final setting = '$ttl/${enabledAt?.millisecondsSinceEpoch}';
      final prev = _progress[room.id];
      final stopBefore = sweepStopBefore(
        enabledAt: enabledAt,
        handledBefore: prev != null && prev.setting == setting ? prev.handledBefore : null,
      );
      // La timeline chargée ne contient que les derniers événements : remonter l'historique
      // (jusqu'à [kSweepMaxPages] pages de [kSweepPageSize]) tant qu'il peut rester des événements
      // non traités. Arrêt dès que l'événement le plus ancien chargé est antérieur à la borne.
      var complete = false;
      for (var page = 0; page < kSweepMaxPages; page++) {
        final oldest = timeline.events.isEmpty ? null : timeline.events.last.originServerTs;
        if (oldest != null && stopBefore != null && oldest.isBefore(stopBefore)) {
          complete = true;
          break;
        }
        if (!timeline.canRequestHistory) {
          complete = true;
          break;
        }
        final before = timeline.events.length;
        await timeline.requestHistory(historyCount: kSweepPageSize);
        if (timeline.events.length == before) {
          complete = true; // plus rien à charger
          break;
        }
      }
      final now = DateTime.now();
      final expired = timeline.events.where((e) => shouldSweep(
            type: e.type,
            senderId: e.senderId,
            me: me,
            redacted: e.redacted,
            sent: e.status.isSent,
            expired: isExpiredAt(
              originServerTs: e.originServerTs,
              ttlSeconds: ttl,
              now: now,
              enabledAt: enabledAt,
            ),
          ));
      var failed = false;
      for (final e in expired.toList()) {
        if (!_inFlight.add(e.eventId)) {
          failed = true; // rédaction concurrente non confirmée : ne pas avancer la borne
          continue;
        }
        try {
          await e.redactEvent(reason: 'ephemeral');
        } catch (_) {
          failed = true; // Hors ligne ou refus : on réessaiera au prochain balayage.
        } finally {
          _inFlight.remove(e.eventId);
        }
      }
      if (complete && !failed) {
        _progress[room.id] =
            (setting: setting, handledBefore: handledBeforeAfterSweep(now, ttl));
      }
    } catch (_) {
      // Timeline indisponible : réessai ultérieur.
    } finally {
      timeline?.cancelSubscriptions();
    }
  }
}
