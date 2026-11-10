/// Filtrage des expéditeurs bloqués (« ignorés » au sens Matrix, `m.ignored_user_list` — voir
/// `lib/ui/blocked_users_screen.dart`), séparé de l'UI pour rester testable sans `Client` ni
/// `Event` (même logique que `lib/reactions.dart`).
///
/// Trouvé en audit interne (vérifié contre le SDK matrix-dart pinné, tag v0.29.13, et contre
/// Synapse à HEAD — jamais supposé) : `Client.ignoreUser` (appelé par `_blockContact` dans
/// `lib/ui/rooms_screen.dart`) n'écrit QUE le compte `m.ignored_user_list` de l'utilisateur.
/// Aucune référence à `ignoredUsers`/`ignored_user` n'existe dans `room.dart`, `timeline.dart` ou
/// `event.dart` du SDK épinglé : rien côté client ne retire les événements d'un expéditeur bloqué
/// de la timeline affichée. Côté serveur, `synapse/handlers/sync.py` (dépôt `element-hq/synapse`,
/// recherché et lu pour cet audit) ne filtre `ignored_users` QUE pour les invitations
/// (`Membership.INVITE`) ; `synapse/handlers/relations.py` ne le fait que pour les agrégations
/// bundlées exposées par l'API `/relations`. Aucun des deux ne retire les événements `m.room.message`
/// ou `m.reaction` d'un salon déjà rejoint — un expéditeur bloqué reste membre du salon direct et
/// ses envois continuent d'y être synchronisés normalement.
///
/// Conséquence réelle, avant ce correctif : l'écran de confirmation de blocage (`_blockContact`)
/// promet « Vous ne recevrez plus ses messages » — faux pour une conversation déjà ouverte, où ses
/// messages ET ses réactions continuaient de s'afficher normalement après le blocage. Seules les
/// notifications système étaient déjà filtrées (`message_notifier.dart`,
/// `client.ignoredUsers.contains(event.senderId)`) ; rien n'appliquait le même filtre à l'affichage
/// de la conversation elle-même. `lib/ui/rooms_screen.dart` applique maintenant [isSenderBlocked]
/// à la fois à la liste des messages affichés et aux réactions agrégées par message.
library;

bool isSenderBlocked(String senderId, List<String> ignoredUsers) => ignoredUsers.contains(senderId);

/// Logique pure : l'aperçu du dernier message d'une conversation (liste des conversations) est
/// masqué s'il a été rédigé (supprimé), s'il a expiré (messages éphémères) ou si son expéditeur
/// est bloqué — même règle que l'affichage de la conversation elle-même.
bool hideRoomPreview({
  required bool redacted,
  required bool expired,
  required bool senderBlocked,
}) =>
    redacted || expired || senderBlocked;

/// Logique pure : une invitation dont l'expéditeur ([inviterId], auteur de l'événement
/// `m.room.member` « invite » nous concernant) est bloqué n'est pas affichée. Synapse filtre déjà
/// ces invitations côté serveur, mais pas forcément tous les serveurs : filtre côté client.
bool isInviteHidden(String? inviterId, List<String> ignoredUsers) =>
    inviterId != null && isSenderBlocked(inviterId, ignoredUsers);

/// Logique pure : un message cité en réponse reste utilisable tant qu'il n'est ni rédigé, ni
/// expiré, ni envoyé par un expéditeur bloqué ; sinon la réponse est annulée avant l'envoi (le SDK
/// recopierait sinon le texte cité dans le corps de repli de la réponse).
bool isReplyTargetUsable({
  required bool redacted,
  required bool expired,
  required bool senderBlocked,
}) =>
    !redacted && !expired && !senderBlocked;
