import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';

import '../conversation_search.dart';
import '../ephemeral.dart';
import '../moderation.dart';

/// Recherche dans l'historique d'UNE conversation (voir `ui/rooms_screen.dart`, icône de
/// recherche de la barre d'app) : charge l'historique déjà en cache plus quelques pages
/// supplémentaires ([_maxExtraPages]), puis filtre en mémoire à chaque frappe — aucune requête
/// réseau par caractère tapé.
///
/// Les mêmes filtres que la conversation elle-même s'appliquent, pour ne jamais faire apparaître
/// ici un message que `ChatScreen` elle-même masque : expéditeur bloqué (voir `lib/moderation.dart`),
/// message éphémère expiré (voir `lib/ephemeral.dart`), message rédigé, ou édition (événement
/// `m.room.message` à part — voir le commentaire du filtre équivalent dans `rooms_screen.dart`) ;
/// `getDisplayEvent` résout le texte le plus récent d'un message édité, exactement comme
/// `ChatScreen`.
///
/// LIMITE HONNÊTE : ne recherche que le texte des messages — jamais une pièce jointe (image,
/// fichier) ni un message illisible sur cet appareil (clé manquante : rien à chercher dans du
/// contenu non déchiffré). Ne « saute » pas non plus au message trouvé dans la conversation :
/// seuls un horodatage et un aperçu sont affichés, pour que cet ajout reste isolé du défilement
/// déjà en place dans `rooms_screen.dart`, plutôt que d'y toucher.
class SearchInRoomScreen extends StatefulWidget {
  const SearchInRoomScreen({super.key, required this.room});
  final Room room;

  @override
  State<SearchInRoomScreen> createState() => _SearchInRoomScreenState();
}

class _SearchInRoomScreenState extends State<SearchInRoomScreen> {
  /// Pages de 100 événements remontées en plus de ce qui est déjà en cache, pour que la recherche
  /// porte sur plus que la seule fenêtre déjà chargée par `ChatScreen` sans pour autant remonter
  /// tout l'historique d'une conversation ancienne en une fois.
  static const _maxExtraPages = 10;
  static const _pageSize = 100;

  final _queryCtrl = TextEditingController();
  Timeline? _timeline;
  bool _loading = true;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
    _queryCtrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  Future<void> _load() async {
    try {
      final timeline = await widget.room.getTimeline();
      for (var page = 0; page < _maxExtraPages && timeline.canRequestHistory; page++) {
        final before = timeline.events.length;
        await timeline.requestHistory(historyCount: _pageSize);
        if (timeline.events.length == before) break; // plus rien à charger
      }
      if (!mounted) return;
      setState(() {
        _timeline = timeline;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadFailed = true;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    _timeline?.cancelSubscriptions();
    super.dispose();
  }

  /// Logique du filtre identique à celle de `ChatScreen` (voir le commentaire de classe
  /// ci-dessus) pour ne jamais faire apparaître ici un message que la conversation masque.
  List<Event> _matches(String query) {
    final timeline = _timeline;
    if (timeline == null) return const [];
    final ignoredUsers = widget.room.client.ignoredUsers;
    return timeline.events.where((e) {
      if (e.type != EventTypes.Message) return false;
      if (e.relationshipType == RelationshipTypes.edit) return false;
      if (e.redacted) return false;
      if (isExpired(e, widget.room)) return false;
      if (isSenderBlocked(e.senderId, ignoredUsers)) return false;
      return matchesSearchQuery(e.getDisplayEvent(timeline).text, query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final query = _queryCtrl.text;
    final results = _loading || _loadFailed ? const <Event>[] : _matches(query);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _queryCtrl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Rechercher dans cette conversation',
            border: InputBorder.none,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadFailed
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      "Impossible de charger l'historique de cette conversation pour la "
                      'recherche. Réessayez plus tard.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : query.trim().isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Tapez un mot ou une phrase pour chercher dans les messages de cette '
                          'conversation.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  : results.isEmpty
                      ? Center(
                          child: Text('Aucun résultat',
                              style: TextStyle(color: scheme.onSurfaceVariant)),
                        )
                      : ListView.separated(
                          itemCount: results.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final e = results[i];
                            final text = e.getDisplayEvent(_timeline!).text;
                            return ListTile(
                              title: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
                              subtitle:
                                  Text(DateFormat('d MMM yyyy, HH:mm').format(e.originServerTs)),
                            );
                          },
                        ),
    );
  }
}
