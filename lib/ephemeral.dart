import 'dart:async';

import 'package:matrix/matrix.dart';

/// Messages éphémères par conversation.
///
/// Réglage : événement d'état Matrix personnalisé `fr.murmure.ephemeral` (state_key ''), contenu
/// `{"ttl_seconds": int}` (0 ou absent = désactivé).
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
bool isExpiredAt({
  required DateTime originServerTs,
  required int ttlSeconds,
  required DateTime now,
}) {
  if (ttlSeconds <= 0) return false;
  return now.difference(originServerTs) > Duration(seconds: ttlSeconds);
}

/// Extrait un TTL valide d'un contenu d'état brut ; tout ce qui n'est pas un entier > 0 donne 0.
int parseTtlSeconds(Map<String, Object?>? content) {
  final v = content?['ttl_seconds'];
  if (v is int && v > 0) return v;
  return 0;
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
    {'ttl_seconds': ttlSeconds < 0 ? 0 : ttlSeconds},
  );
}

/// Vrai si [event] doit être masqué localement dans [room] (messages des autres compris).
bool isExpired(Event event, Room room, {DateTime? now}) => isExpiredAt(
      originServerTs: event.originServerTs,
      ttlSeconds: ephemeralTtlSeconds(room),
      now: now ?? DateTime.now(),
    );

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
