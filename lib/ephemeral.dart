import 'dart:async';

import 'package:matrix/matrix.dart';

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

/// Logique pure : date d'activation effective d'un contenu d'état posé à [originServerTs].
/// `enabled_at_ms` est retenu s'il est un entier > 0 NON POSTÉRIEUR à l'événement (une valeur
/// future, écrite par un client bogué ou malveillant, rendrait sinon des messages permanents) ;
/// sinon [originServerTs].
DateTime resolveEnabledAt(Map<String, Object?>? content, DateTime originServerTs) {
  final v = content?['enabled_at_ms'];
  if (v is int && v > 0) {
    final at = DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);
    if (!at.isAfter(originServerTs)) return at;
  }
  return originServerTs;
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

/// Date de première activation du réglage actuel (voir [resolveEnabledAt]), ou null si inconnue
/// (état « stripped » d'une invitation).
DateTime? ephemeralEnabledAt(Room room) {
  final st = room.getState(kEphemeralEventType);
  return st is Event ? resolveEnabledAt(st.content, st.originServerTs) : null;
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
      prevEnabledAt: ephemeralEnabledAt(room),
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

/// Service qui rédige périodiquement les messages expirés ENVOYÉS PAR L'UTILISATEUR.
class EphemeralService {
  EphemeralService._();
  static final EphemeralService instance = EphemeralService._();

  Timer? _timer;
  Client? _client;
  bool _sweeping = false;
  final Set<String> _inFlight = {};

  /// Démarre (idempotent) le balayage toutes les 60 s pour [client].
  void start(Client client, {Duration interval = const Duration(seconds: 60)}) {
    if (_timer != null && identical(_client, client)) return;
    _timer?.cancel();
    _client = client;
    _timer = Timer.periodic(interval, (_) => unawaited(sweepAll()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _client = null;
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

  /// Rédige les messages de l'utilisateur expirés dans [room] (parmi ceux de la timeline chargée).
  /// Hors ligne / erreur serveur : abandonné silencieusement, réessayé au prochain balayage.
  Future<void> sweepRoom(Room room) async {
    if (ephemeralTtlSeconds(room) <= 0) return;
    final me = room.client.userID;
    if (me == null) return;
    Timeline? timeline;
    try {
      timeline = await room.getTimeline();
      // La timeline chargée ne contient que les derniers événements : remonter l'historique
      // (jusqu'à [kSweepMaxPages] pages de [kSweepPageSize]) tant qu'il peut rester des messages
      // postérieurs à l'activation, sinon un vieux message expiré ne serait jamais rédigé.
      // Arrêt dès que l'événement le plus ancien chargé est antérieur à l'activation.
      final enabledAt = ephemeralEnabledAt(room);
      for (var page = 0; page < kSweepMaxPages && timeline.canRequestHistory; page++) {
        final oldest = timeline.events.isEmpty ? null : timeline.events.last.originServerTs;
        if (oldest != null && enabledAt != null && oldest.isBefore(enabledAt)) break;
        final before = timeline.events.length;
        await timeline.requestHistory(historyCount: kSweepPageSize);
        if (timeline.events.length == before) break; // plus rien à charger
      }
      final now = DateTime.now();
      final expired = timeline.events.where((e) =>
          e.type == EventTypes.Message &&
          e.senderId == me &&
          !e.redacted &&
          e.status.isSent &&
          isExpiredAt(
            originServerTs: e.originServerTs,
            ttlSeconds: ephemeralTtlSeconds(room),
            now: now,
            enabledAt: enabledAt,
          ));
      for (final e in expired.toList()) {
        if (!_inFlight.add(e.eventId)) continue;
        try {
          await e.redactEvent(reason: 'ephemeral');
        } catch (_) {
          // Hors ligne ou refus : on réessaiera au prochain balayage.
        } finally {
          _inFlight.remove(e.eventId);
        }
      }
    } catch (_) {
      // Timeline indisponible : réessai ultérieur.
    } finally {
      timeline?.cancelSubscriptions();
    }
  }
}
