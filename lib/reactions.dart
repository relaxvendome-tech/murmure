/// Réactions (emoji) à un message — logique d'agrégation et de bascule, séparée du SDK Matrix et
/// de l'UI pour rester testable sans serveur ni objet `Event` (voir test/reactions_test.dart).
///
/// Mécanique Matrix : une réaction est un événement `m.reaction` dont le contenu porte
/// `m.relates_to: {rel_type: "m.annotation", event_id, key}` — `Room.sendReaction(eventId, key)`
/// l'envoie, et le SDK l'agrège lui-même dans
/// `Event.aggregatedEvents(timeline, RelationshipTypes.reaction)` ; une réaction retirée est une
/// REDACTION de cet événement (`Event.redactEvent()`), que le SDK retire alors de cette même
/// agrégation (`Timeline.removeAggregatedEvent`, vérifié dans timeline.dart).
///
/// Trouvé en audit interne (re-vérifié contre le SDK matrix-dart pinné, tag v16.0.2, après la
/// migration 0.29 -> 16 — commit 3ac025a) : ce commentaire citait encore l'ancien tag v0.29.0,
/// jamais mis à jour depuis, pour les trois affirmations ci-dessus et celles de confidentialité
/// plus bas. Les trois API (`sendReaction`, `aggregatedEvents`, `redactEvent`/
/// `removeAggregatedEvent`) existent à l'identique au tag épinglé : rien ne change ici.
///
/// CONFIDENTIALITÉ — LES RÉACTIONS NE SONT PAS CHIFFRÉES : re-vérifié au tag épinglé dans
/// `room.dart` (`Room._sendContent`) et `encryption.dart`
/// (`Encryption.encryptGroupMessagePayload`) — PAS un cas spécial sur le type d'événement comme
/// l'affirmait l'ancien commentaire, mais une conséquence de la FORME du contenu envoyé par
/// `sendReaction` : celui-ci ne porte que `m.relates_to`, et `encryptGroupMessagePayload` retire
/// ce champ avant de regarder s'il reste quoi que ce soit à chiffrer — un contenu vide à ce
/// stade (exactement le cas d'une réaction pure) ressort donc tel quel, en clair, sans jamais
/// atteindre le chiffrement Megolm. Et même pour un événement de type différent qui serait
/// chiffré, `m.relates_to` est de toute façon toujours recopié EN CLAIR dans l'enveloppe
/// `m.room.encrypted` (nécessaire au serveur pour l'agrégation des relations). Le serveur voit
/// donc, pour chaque réaction : l'emoji, le message visé (son identifiant) et l'auteur. Seul le
/// CONTENU des messages reste chiffré de bout en bout. Conséquences dans l'appli : l'écran
/// « Sécurité et limites » le signale ; dans une conversation à messages éphémères, l'ajout de
/// réactions est désactivé et les réactions ne sont pas affichées ; le balayage éphémère rédige
/// aussi les réactions expirées de l'utilisateur.
library;

/// Émojis proposés par Murmure lors d'un appui long sur un message. Volontairement restreint à
/// une poignée de choix fréquents plutôt qu'un clavier emoji complet : garde l'action rapide (un
/// seul appui après l'appui long) sans ouvrir un sélecteur distinct.
const List<String> kQuickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Une réaction, réduite à ce dont la logique ci-dessous a besoin (expéditeur + emoji), plutôt
/// qu'un objet `Event` du SDK — pour que cette logique soit testable avec de simples valeurs
/// construites à la main, sans Room ni Client Matrix.
typedef ReactionEntry = ({String senderId, String key});

/// Extrait la clé emoji (`m.relates_to.key`) du CONTENU JSON d'un événement de réaction — reçoit
/// directement ce contenu plutôt qu'un `Event` SDK, pour rester testable sans objet Matrix. `null`
/// si absent, mal formé, ou vide (événement malformé envoyé par un autre client ou un tiers).
String? reactionKeyOf(Map<String, Object?>? content) {
  final relatesTo = content?['m.relates_to'];
  if (relatesTo is! Map) return null;
  final key = relatesTo['key'];
  return key is String && key.isNotEmpty ? key : null;
}

/// Regroupe des réactions par emoji, dans l'ordre de PREMIÈRE apparition parmi [reactions] plutôt
/// que par fréquence : un ordre stable d'un rafraîchissement à l'autre (l'appelant passe les
/// réactions déjà triées par horodatage), moins déroutant qu'un tri qui déplacerait les chips à
/// chaque nouvelle réaction.
Map<String, List<String>> groupReactionsBySenders(Iterable<ReactionEntry> reactions) {
  final map = <String, List<String>>{};
  for (final r in reactions) {
    map.putIfAbsent(r.key, () => <String>[]).add(r.senderId);
  }
  return map;
}

/// Vrai si [myId] a déjà réagi avec [key] parmi [reactions]. Détermine si un appui sur cet emoji
/// doit RETIRER la réaction existante plutôt que d'en envoyer une nouvelle — bascule, comme
/// Telegram/Signal : réagir deux fois avec le même emoji annule la réaction.
bool hasOwnReaction(Iterable<ReactionEntry> reactions, String myId, String key) =>
    reactions.any((r) => r.senderId == myId && r.key == key);

/// Vrai si [content] (contenu en clair d'un `m.reaction`, ou enveloppe `m.room.encrypted` dont le
/// `m.relates_to` reste en clair) porte une relation de type réaction
/// (`m.relates_to.rel_type == "m.annotation"`). Utilisé par lib/message_notifier.dart pour ne pas
/// notifier une réaction comme un nouveau message.
bool isAnnotationRelation(Object? content) {
  if (content is! Map) return false;
  final rel = content['m.relates_to'];
  return rel is Map && rel['rel_type'] == 'm.annotation';
}
