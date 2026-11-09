/// Réactions (emoji) à un message — logique d'agrégation et de bascule, séparée du SDK Matrix et
/// de l'UI pour rester testable sans serveur ni objet `Event` (voir test/reactions_test.dart).
///
/// Mécanique Matrix (vérifiée contre le SDK épinglé, tag v0.29.13) : une réaction est un événement
/// `m.reaction` dont le contenu porte `m.relates_to: {rel_type: "m.annotation", event_id, key}` —
/// `Room.sendReaction(eventId, key)` l'envoie, et le SDK l'agrège lui-même dans
/// `Event.aggregatedEvents(timeline, RelationshipTypes.reaction)` ; une réaction retirée est une
/// REDACTION de cet événement (`Event.redactEvent()`), que le SDK retire alors de cette même
/// agrégation (`Timeline.removeAggregatedEvent`, vérifié dans timeline.dart). Rien ici ne touche au
/// chiffrement : comme tout événement de salon chiffré, une réaction est chiffrée de bout en bout
/// comme n'importe quel autre message (le SDK l'agrège une fois déchiffrée).
///
/// CONFIDENTIALITÉ : qui a réagi, et avec quel emoji, est visible de tous les membres du salon
/// (comme sur Telegram/Signal) — jamais du serveur seul, qui ne voit que l'événement chiffré.
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
