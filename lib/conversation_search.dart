/// Logique pure de la recherche dans une conversation (voir `ui/search_screen.dart` pour l'écran),
/// séparée de l'UI et du SDK Matrix pour rester testable sans `Client`, `Room` ni `Event` — même
/// principe que `lib/moderation.dart` et `lib/reactions.dart`.
library;

/// Vrai si [text] contient [query], recherche insensible à la casse. Une requête vide ou blanche
/// (espaces seuls) ne correspond à RIEN — c'est à l'appelant de ne même pas lancer de recherche
/// sur une requête vide (voir `ui/search_screen.dart`), mais cette fonction reste sûre dans ce cas
/// plutôt que de faire correspondre tous les messages d'une conversation à une recherche vide.
bool matchesSearchQuery(String text, String query) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return false;
  return text.toLowerCase().contains(trimmed.toLowerCase());
}
