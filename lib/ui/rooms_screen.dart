import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';

import '../account.dart';
import '../calls/call_policy.dart';
import '../calls/services/call_manager.dart';
import '../calls/ui/missed_calls_screen.dart';
import '../media.dart';
import '../network.dart';
import 'device_verification_screen.dart';
import 'group_info_screen.dart';
import 'group_screen.dart';
import 'lock_screens.dart';
import 'mesh_screen.dart';
import 'profile_screen.dart';
import 'qr_screens.dart';
import 'theme.dart';

/// Horodatage court pour une liste de conversations ou une bulle de message : heure seule
/// aujourd'hui, jour+mois au-delà — jamais la date complète, qui prendrait trop de place dans la
/// liste. `DateFormat` vient de `intl`, déjà déclaré dans pubspec.yaml (dépendance transitive de
/// matrix-dart-sdk pour ses traductions) mais jusqu'ici jamais importé directement dans ce dépôt.
String _formatTimestamp(DateTime dt) {
  final now = DateTime.now();
  final sameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;
  return sameDay ? DateFormat.Hm().format(dt) : DateFormat('d MMM').format(dt);
}

/// Retire le fallback texte que `Room.sendEvent` (matrix-dart-sdk pinné, lib/src/room.dart,
/// `_stripBodyFallback`) insère automatiquement dans `body` pour un message envoyé avec
/// `inReplyTo` (lignes préfixées par `> `, jusqu'à la première ligne vide) — pensé pour les
/// clients qui ne savent pas afficher la citation autrement. Cette appli l'affiche elle-même (voir
/// [_ReplyQuote] ci-dessous) : sans ce retrait, le texte du message répété deux fois (la citation
/// brute en tête du corps, puis la vraie réponse, puis à nouveau le widget de citation construit à
/// partir de la relation `m.in_reply_to`).
///
/// Port direct de la méthode du SDK (privée, donc non réutilisable depuis l'UI) — même logique,
/// pas de dépendance cachée à son implémentation interne.
String _stripReplyFallback(String body) {
  if (!body.startsWith('> <@')) return body;
  var out = '';
  var inPrefix = true;
  for (final line in body.split('\n')) {
    if (inPrefix && (line.isEmpty || line.startsWith('> '))) continue;
    inPrefix = false;
    out += out.isEmpty ? line : '\n$line';
  }
  return out;
}

/// Résume tout ce qui peut changer l'affichage de la liste des conversations (ordre, nom, dernier
/// message) — voir son usage avec `distinct()` dans [RoomsScreen.build].
///
/// Trouvé en audit interne — un vrai défaut de réactivité, pas une optimisation de principe :
/// `client.onSync.stream` émet à CHAQUE synchronisation avec le homeserver, y compris pour des
/// événements qui n'ont rien à voir avec cette liste (un accusé de lecture, une notification de
/// frappe dans une conversation ouverte ailleurs, une mise à jour de présence d'un contact...).
/// Avant cette correction, un tel événement reconstruisait pourtant TOUTE la liste — filtrage, tri,
/// et pour chaque salon la couleur d'avatar, le nom localisé et le texte du dernier message —
/// aussi souvent que ces événements arrivent, même quand rien de visible n'avait réellement changé.
/// `distinct()` sur cette signature fait que seul un changement qui affecte vraiment ce qui est
/// affiché déclenche cette reconstruction.
String _roomsSignature(Client client) {
  final rooms = client.rooms.where((r) => !r.isSpace);
  final parts = rooms.map((r) {
    final last = r.lastEvent;
    // Trouvé en audit interne : `membership` doit faire partie de la signature, sinon accepter ou
    // refuser une invitation (Room.join()/Room.leave(), voir plus bas) ne faisait pas réafficher
    // la liste — l'id, le nom et le dernier événement du salon ne changent pas forcément à cette
    // occasion, seule son statut d'adhésion change.
    return '${r.id}\u0000${r.getLocalizedDisplayname()}\u0000${last?.eventId ?? ''}\u0000'
        '${last?.originServerTs.millisecondsSinceEpoch ?? 0}\u0000${r.membership}';
  });
  return parts.join('\u0001');
}

/// Liste des conversations. Point d'entrée vers une discussion, l'ajout d'un contact, et les
/// réglages (verrou, mode Bluetooth, réseau).
class RoomsScreen extends StatelessWidget {
  const RoomsScreen({super.key, required this.client, required this.callManager});
  final Client client;
  final CallManager callManager;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Murmure'),
        actions: [
          IconButton(
            icon: const Icon(Icons.badge_outlined),
            tooltip: 'Mon profil',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ProfileScreen(client: client),
            )),
          ),
          IconButton(
            icon: const Icon(Icons.qr_code),
            tooltip: 'Mon code',
            onPressed: () {
              final id = client.userID;
              if (id == null) return;
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => MyQrScreen(shareableId: shareableId(id)),
              ));
            },
          ),
          IconButton(
            icon: const Icon(Icons.bluetooth),
            tooltip: 'Mode hors-ligne',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const MeshScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.phone_missed_outlined),
            tooltip: 'Appels manqués',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => MissedCallsScreen(client: client),
            )),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Réglages',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => LockSettingsScreen(
                client: client,
                // Comme pour l'effacement d'urgence (Account.panic), on ferme l'appli juste
                // après : plus simple et plus sûr que de reconstruire l'état en mémoire d'un
                // client Matrix dont la base locale vient d'être supprimée sous ses pieds.
                // Au prochain lancement, l'appli redémarre comme neuve (écran d'onboarding).
                onDeleteAccount: () async {
                  await Account.deleteEverything(client);
                  exit(0);
                },
              ),
            )),
          ),
        ],
      ),
      body: StreamBuilder<String>(
        stream: client.onSync.stream.map((_) => _roomsSignature(client)).distinct(),
        initialData: _roomsSignature(client),
        builder: (context, _) {
          // Trouvé en audit interne (revue indépendante), confirmé contre le code réel du SDK
          // (tag v0.29.13) : `client.rooms` inclut aussi bien les salons rejoints que les
          // invitations en attente (`Membership.invite`) — sans distinction ici, une invitation
          // (premier contact qui vous ajoute, ou invitation à un groupe) s'affichait exactement
          // comme une conversation normale, mais taper dessus ouvrait un `ChatScreen` où
          // envoyer un message échouait silencieusement : rien dans ce dépôt n'appelait jamais
          // `Room.join()`, qui existe pourtant bel et bien dans le SDK (`room.dart`). Un contact
          // invité n'avait donc tout simplement AUCUN moyen de répondre, ni via cette liste ni
          // ailleurs — seul l'auteur de `startDirectChat`/l'invitation (qui rejoint lui-même
          // automatiquement) pouvait écrire. On sépare donc les invitations, affichées avec
          // Accepter/Refuser (`Room.join()` / `Room.leave()`), des conversations déjà actives.
          final allRooms = client.rooms.where((r) => !r.isSpace).toList();
          final invites = allRooms.where((r) => r.membership == Membership.invite).toList()
            ..sort((a, b) => (b.lastEvent?.originServerTs ?? DateTime(0))
                .compareTo(a.lastEvent?.originServerTs ?? DateTime(0)));
          final rooms = allRooms.where((r) => r.membership != Membership.invite).toList()
            ..sort((a, b) => (b.lastEvent?.originServerTs ?? DateTime(0))
                .compareTo(a.lastEvent?.originServerTs ?? DateTime(0)));
          if (rooms.isEmpty && invites.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.chat_bubble_outline,
                      size: 56,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Aucune conversation pour l\'instant',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Ajoutez un contact ou créez un groupe avec le bouton + ci-dessous.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: invites.length + rooms.length,
            itemBuilder: (context, i) {
              if (i < invites.length) {
                return _InviteTile(room: invites[i]);
              }
              final room = rooms[i - invites.length];
              final name = room.getLocalizedDisplayname();
              final lastTs = room.lastEvent?.originServerTs;
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: murmureAvatarColor(room.id),
                  foregroundColor: Colors.white,
                  child: Text(name.isEmpty ? '?' : name[0].toUpperCase()),
                ),
                title: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  room.lastEvent?.text ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: lastTs == null
                    ? null
                    : Text(
                        _formatTimestamp(lastTs),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ChatScreen(room: room, callManager: callManager),
                )),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showNewConversationSheet(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _showNewConversationSheet(BuildContext context) async {
    final choice = await showModalBottomSheet<_NewConversationKind>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_add_alt_1),
              title: const Text('Ajouter un contact'),
              onTap: () => Navigator.of(sheetContext).pop(_NewConversationKind.contact),
            ),
            ListTile(
              leading: const Icon(Icons.group_add),
              title: const Text('Créer un groupe'),
              onTap: () => Navigator.of(sheetContext).pop(_NewConversationKind.group),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case _NewConversationKind.contact:
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AddContactScreen(client: client, callManager: callManager),
        ));
      case _NewConversationKind.group:
        final room = await Navigator.of(context)
            .push<Room>(MaterialPageRoute(builder: (_) => NewGroupScreen(client: client)));
        if (room != null && context.mounted) {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ChatScreen(room: room, callManager: callManager),
          ));
        }
    }
  }
}

enum _NewConversationKind { contact, group }

/// Ligne d'invitation en attente (contact ou groupe) : `Room.join()`/`Room.leave()` sont les
/// deux seuls appels qui existaient déjà dans le SDK pour ça — voir le commentaire au-dessus de
/// `allRooms`/`invites` dans [RoomsScreen.build].
class _InviteTile extends StatefulWidget {
  const _InviteTile({required this.room});
  final Room room;

  @override
  State<_InviteTile> createState() => _InviteTileState();
}

class _InviteTileState extends State<_InviteTile> {
  bool _busy = false;

  Future<void> _respond(bool accept) async {
    setState(() => _busy = true);
    try {
      if (accept) {
        await widget.room.join();
      } else {
        await widget.room.leave();
      }
      // Pas de setState ici : `Room.join()`/`leave()` déclenchent une synchro dont le résultat
      // met déjà à jour `client.rooms` — c'est `_roomsSignature` (voir plus haut, qui inclut
      // désormais `membership`) qui fera disparaître cette ligne au prochain `onSync`.
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Échec : $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.room.getLocalizedDisplayname();
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: murmureAvatarColor(widget.room.id),
        foregroundColor: Colors.white,
        child: Text(name.isEmpty ? '?' : name[0].toUpperCase()),
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: const Text('Vous a invité·e à discuter'),
      trailing: _busy
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Refuser',
                  onPressed: () => _respond(false),
                ),
                IconButton(
                  icon: const Icon(Icons.check),
                  tooltip: 'Accepter',
                  onPressed: () => _respond(true),
                ),
              ],
            ),
    );
  }
}

/// Ajout d'un contact par identifiant Matrix (collé ou scanné par QR) ; ouvre ou crée la
/// conversation directe chiffrée (Megolm) avec lui.
class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key, required this.client, required this.callManager});
  final Client client;
  final CallManager callManager;

  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen> {
  final _idCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  // Trouvé en audit interne (revue croisée IA, vérifiée contre le code réel) : ce contrôleur
  // n'était jamais libéré — aucun dispose() sur cet état. Une fuite mineure par passage sur cet
  // écran (il n'est affiché qu'un court instant avant navigation ou fermeture), mais sans raison
  // de la laisser : TextEditingController alloue des ressources natives qui doivent être rendues.
  @override
  void dispose() {
    _idCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final raw = _idCtrl.text.trim();
    final id = parseUserId(raw) ?? (raw.startsWith('@') ? raw : null);
    if (id == null) {
      setState(() => _error = 'Identifiant invalide (attendu : @nom:serveur)');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // startDirectChat retrouve lui-même une conversation existante avec ce contact
      // (via Client.getDirectChatFromUserId) avant d'en créer une nouvelle.
      final roomId = await widget.client.startDirectChat(id, enableEncryption: true);
      final room = widget.client.getRoomById(roomId);
      if (room == null) throw Exception('Conversation introuvable après création');
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ChatScreen(room: room, callManager: widget.callManager),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ajouter un contact')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Text('Collez l\'identifiant Murmure de votre contact, ou scannez le code qu\'il '
                'vous montre depuis l\'icône code en haut de l\'écran.'),
            const SizedBox(height: 16),
            TextField(
              controller: _idCtrl,
              decoration: InputDecoration(
                labelText: 'Identifiant',
                hintText: '@abc123:serveur',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.qr_code_scanner),
                  tooltip: 'Scanner un code',
                  onPressed: () async {
                    final scanned = await Navigator.of(context)
                        .push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
                    if (scanned == null || !mounted) return;
                    setState(() => _idCtrl.text = scanned);
                    // Trouvé en audit interne (demande de simplicité comparable à Signal/Telegram) :
                    // un scan réussi exigeait ensuite une seconde action manuelle ("Démarrer la
                    // conversation") pour un identifiant déjà complet et déjà validé par le format du
                    // QR — une étape de confirmation utile pour un identifiant COLLÉ ou tapé à la
                    // main (où une relecture avant envoi a du sens), mais superflue ici : l'action
                    // physique de scanner le code d'un contact EST déjà la confirmation délibérée.
                    // On démarre directement si le texte scanné est un identifiant reconnu ; sinon on
                    // laisse le champ rempli pour correction manuelle, comme avant.
                    if (parseUserId(scanned) != null) await _start();
                  },
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _start,
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Démarrer la conversation'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Conversation chiffrée (Olm/Megolm via libolm, géré en interne par le SDK Matrix — voir le
/// commentaire détaillé dans main.dart sur le choix libolm/flutter_olm à cette version du SDK).
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.room, required this.callManager});
  final Room room;
  final CallManager callManager;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textCtrl = TextEditingController();
  Timeline? _timeline;
  bool _sendingMedia = false;

  // Indicateur « en train d'écrire » — cité par plusieurs IA (revue croisée « niveau
  // Telegram/Signal ») comme absent de cette appli alors que le SDK matrix-dart pinné l'expose
  // déjà intégralement (vérifié dans /tmp/matrix_v : `Room.setTyping(bool, {int? timeout})`,
  // `Room.typingUsers`, lib/src/room.dart). Rien à ajouter côté protocole, seulement câbler l'UI.
  //
  // Émission : debattue par un minuteur d'inactivité plutôt qu'à chaque frappe, pour deux
  // raisons — éviter de spammer le homeserver d'un événement m.typing à chaque caractère, et
  // limiter la fenêtre pendant laquelle ce signal de métadonnée (« cette personne est en train
  // d'écrire ici, maintenant ») existe, cohérent avec le reste de l'OPSEC de cette appli. Le délai
  // de 20 secondes transmis au serveur est documenté par le SDK comme une durée de validité, pas
  // un engagement : on l'arrête nous-mêmes explicitement dès l'envoi ou le champ vidé plutôt que
  // de compter sur son expiration côté serveur.
  //
  // Réception : `Room.typingUsers` lit un état déjà tenu à jour par le SDK (`ephemerals['m.typing']`),
  // mais sans flux dédié — `client.onSync.stream` est le signal déjà utilisé ailleurs dans ce
  // fichier (voir `_roomsSignature` dans RoomsScreen) pour détecter ce genre de mise à jour
  // éphémère, donc même pattern ici plutôt qu'en introduire un nouveau.
  Timer? _typingStopTimer;
  StreamSubscription<SyncUpdate>? _typingSub;
  bool _typingActive = false;
  Set<String> _typingOtherUserIds = {};

  /// Message auquel la prochaine saisie va répondre (voir [_send], [_setReplyTarget],
  /// [_cancelReply]) — citée au-dessus du champ de texte tant que non envoyée ou annulée.
  Event? _replyingTo;

  /// Dernier événement pour lequel un accusé de lecture a déjà été envoyé (voir
  /// [_maybeSendReadMarker]) : évite de rappeler `Room.setReadMarker` — donc de renvoyer un
  /// événement de réception au homeserver — à chaque reconstruction de cet écran (frappe d'un
  /// autre participant, statut d'envoi d'un message, etc.) alors que rien de nouveau n'a été lu.
  String? _lastReadMarkerEventId;

  @override
  void initState() {
    super.initState();
    widget.room.getTimeline(onUpdate: () {
      if (mounted) setState(() {});
      _maybeSendReadMarker();
    }).then((t) {
      if (mounted) setState(() => _timeline = t);
      _maybeSendReadMarker();
    });
    _refreshTypingUsers();
    _typingSub = widget.room.client.onSync.stream.listen((_) => _refreshTypingUsers());
  }

  /// Signale au homeserver (et donc, potentiellement, à l'interlocuteur — voir l'indicateur
  /// « Vu » dans les bulles ci-dessous) que les messages jusqu'au plus récent visible dans cet
  /// écran ont été lus. Trouvé en audit interne (revue croisée IA, « niveau Telegram/Signal ») :
  /// jamais implémenté jusqu'ici, alors que `Room.setReadMarker` est déjà exposé par le SDK pinné.
  ///
  /// Appelé uniquement tant que cet écran de conversation est effectivement ouvert — jamais en
  /// arrière-plan — pour rester cohérent avec le reste de l'OPSEC de cette appli (même esprit que
  /// l'indicateur de frappe juste au-dessus) : on ne signale pas la lecture d'une conversation que
  /// l'utilisateur n'a pas réellement sous les yeux. Best-effort, comme tout le reste des accusés
  /// de ce fichier : un échec réseau ne doit jamais interrompre la lecture elle-même.
  void _maybeSendReadMarker() {
    final latest = _timeline?.events
        .where((e) => e.type == EventTypes.Message)
        .fold<Event?>(null, (latest, e) =>
            latest == null || e.originServerTs.isAfter(latest.originServerTs) ? e : latest);
    if (latest == null || latest.eventId == _lastReadMarkerEventId) return;
    _lastReadMarkerEventId = latest.eventId;
    unawaited(widget.room.setReadMarker(latest.eventId, mRead: latest.eventId).catchError((_) {}));
  }

  void _setReplyTarget(Event e) => setState(() => _replyingTo = e);

  void _cancelReply() => setState(() => _replyingTo = null);

  void _refreshTypingUsers() {
    final myId = widget.room.client.userID;
    final ids = widget.room.typingUsers.map((u) => u.id).where((id) => id != myId).toSet();
    if (ids.length == _typingOtherUserIds.length && ids.containsAll(_typingOtherUserIds)) {
      return;
    }
    if (mounted) setState(() => _typingOtherUserIds = ids);
  }

  void _onComposingChanged(String text) {
    if (text.isEmpty) {
      _stopTyping();
      return;
    }
    _typingStopTimer?.cancel();
    _typingStopTimer = Timer(const Duration(seconds: 4), _stopTyping);
    if (_typingActive) return;
    _typingActive = true;
    // Best-effort : une notification de frappe manquée ou en échec (réseau coupé) n'a aucun
    // impact fonctionnel, contrairement à l'envoi d'un message — pas de SnackBar ici.
    unawaited(widget.room.setTyping(true, timeout: 20000).catchError((_) {}));
  }

  void _stopTyping() {
    _typingStopTimer?.cancel();
    _typingStopTimer = null;
    if (!_typingActive) return;
    _typingActive = false;
    unawaited(widget.room.setTyping(false).catchError((_) {}));
  }

  // Trouvé en audit interne (revue croisée IA, vérifiée contre le code réel) : cette classe
  // n'avait aucun dispose() — _textCtrl n'était jamais libéré, contrairement à toutes les autres
  // vues à TextEditingController de cette appli (voir AddContactScreen, NewGroupScreen,
  // ProfileScreen). Cet écran étant celui qu'on ouvre et referme le plus souvent (chaque
  // conversation), la fuite ici est la plus significative des deux trouvées sur ce fichier.
  //
  // Deuxième fuite trouvée dans la même classe, après une remarque d'une IA externe sur ce point
  // précis (vérifiée directement dans le SDK matrix-dart pinné, lib/src/timeline.dart) : `Timeline`
  // s'abonne en interne aux mises à jour de la timeline du salon et expose explicitement
  // `cancelSubscriptions()` pour s'en désabonner — jamais appelé ici. Sans ce correctif, chaque
  // conversation ouverte puis fermée laissait son Timeline continuer à écouter indéfiniment les
  // événements du salon en arrière-plan.
  @override
  void dispose() {
    _textCtrl.dispose();
    _timeline?.cancelSubscriptions();
    _typingStopTimer?.cancel();
    _typingSub?.cancel();
    // Fire-and-forget : on quitte l'écran, pas la peine d'attendre la réponse du serveur, mais on
    // prévient quand même les autres participants qu'on a arrêté d'écrire plutôt que de laisser
    // l'indicateur expirer silencieusement après les 20 secondes annoncées.
    if (_typingActive) {
      unawaited(widget.room.setTyping(false).catchError((_) {}));
    }
    super.dispose();
  }

  /// Lance un appel audio. Vérifie la politique réseau ICI, de façon à afficher un message
  /// explicite (voir docs/CALLS_ARCHITECTURE.md, « Comportement par défaut ») plutôt que de
  /// laisser l'utilisateur appuyer sur un bouton qui échoue silencieusement — même si, de toute
  /// façon, `CallManager.startCall` et `MurmureWebRTCDelegate.createPeerConnection` referont
  /// chacun cette vérification et refuseraient l'appel à leur tour (fail-closed en profondeur,
  /// pas seulement ici).
  ///
  /// Trouvé en audit interne : ce contrôle préalable ne couvre que le refus lié au MODE réseau
  /// (Tor/proxy). `CallManager.startCall` peut aussi refuser l'appel (retour `null`) même en mode
  /// direct, si le homeserver ne fournit aucun TURN exploitable — ce code ignorait jusqu'ici sa
  /// valeur de retour : aucun message ne s'affichait alors, le bouton d'appel ne faisant
  /// littéralement rien de visible. Corrigé en vérifiant le résultat et en affichant le même
  /// message explicite dans ce cas-là aussi.
  /// Trouvé en audit interne (revue croisée IA, recoupée par Grok et Qwen indépendamment,
  /// vérifiée contre le code réel) : `CallManager.startCall` et `CallSession` (matrix-dart-sdk)
  /// gèrent déjà un appel vidéo de bout en bout dès que `type: CallType.kVideo` leur est passé
  /// (`voip.inviteToCall(room, type)` transmet tel quel ; `CallSessionScreen` affiche déjà deux
  /// `RTCVideoView`, local et distant, quel que soit le type d'appel) — seul ce bouton, qui
  /// n'appelait jamais qu'avec `CallType.kVoice`, manquait pour l'exposer à l'utilisateur.
  Future<void> _call(CallType type) async {
    final net = await NetConfig.load();
    if (!CallPolicy.isAllowed(net.mode)) {
      _showCallDisabledDialog(
        'Les appels audio/vidéo sont désactivés en mode Tor/proxy : le flux audio/vidéo ne '
        'peut pas être protégé par ce mode. Voir docs/CALLS_ARCHITECTURE.md.',
      );
      return;
    }
    final session = await widget.callManager.startCall(widget.room, type: type);
    if (session == null) {
      _showCallDisabledDialog(
        "L'appel n'a pas pu démarrer : aucun serveur TURN exploitable n'a été fourni par le "
        'homeserver (voir docs/CALLS_ARCHITECTURE.md). Réessayez plus tard ou contactez '
        "l'administrateur du serveur.",
      );
    }
    // Sinon, la navigation vers CallSessionScreen est faite par MurmureWebRTCDelegate.handleNewCall
    // (voir lib/calls/services/call_manager.dart), pas ici : c'est le même chemin que pour un
    // appel entrant, donc un seul endroit à maintenir pour l'UI d'appel.
  }

  /// Résume l'état de vérification des appareils du contact d'une conversation directe, pour
  /// l'icône d'app bar — voir `device_verification_screen.dart` et
  /// `docs/E2EE_VERIFICATION.md`. `null` pour un groupe (plusieurs contacts, hors scope de cette
  /// première passe) ou tant qu'aucune clé d'appareil n'est encore connue pour ce contact.
  bool? _deviceVerificationStatus() {
    if (!widget.room.isDirectChat) return null;
    final otherId = widget.room.directChatMatrixID;
    if (otherId == null) return null;
    final devices = widget.room.client.userDeviceKeys[otherId]?.deviceKeys.values;
    if (devices == null || devices.isEmpty) return null;
    return devices.every((d) => d.verified);
  }

  Future<void> _openDeviceVerification() async {
    final otherId = widget.room.directChatMatrixID;
    if (otherId == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DeviceVerificationScreen(
        client: widget.room.client,
        userId: otherId,
        displayName: widget.room.getLocalizedDisplayname(),
      ),
    ));
    // L'état "vérifié" a pu changer pendant l'écran ouvert : on reconstruit pour mettre à jour
    // l'icône de l'app bar (voir _deviceVerificationStatus).
    if (mounted) setState(() {});
  }

  void _showCallDisabledDialog(String message) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Appel désactivé'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  /// Trouvé par Grok (revue croisée IA) sous la forme « le texte est effacé avant que l'envoi
  /// réussisse, donc perdu en cas d'échec » — vérifié ensuite contre le SDK matrix-dart pinné
  /// (lib/src/room.dart, Room.sendEvent) avant d'agir : ce n'est pas tout à fait ça. Le texte
  /// n'est PAS perdu — le SDK insère immédiatement un écho local dans la timeline (statut
  /// `sending`, devenant `error` en cas d'échec), donc la bulle reste visible et récupérable.
  /// Le vrai problème, confirmé en lisant cet écran : aucun endroit du fichier ne lit jamais ce
  /// statut (`EventStatus`) — un message qui échoue silencieusement à partir prend l'apparence
  /// EXACTE d'un message envoyé avec succès, sans aucun indice. Pour l'usage visé par cette appli
  /// (réseau coupé ou dégradé en manifestation), c'est le scénario le plus probable, pas un cas
  /// limite. `sendTextEvent` retourne `null` précisément dans ce cas (voir le SDK) ; on l'utilise
  /// ici pour au moins prévenir explicitement plutôt que de laisser croire que c'est parti.
  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    final replyTo = _replyingTo;
    _textCtrl.clear();
    if (replyTo != null) _cancelReply();
    _stopTyping();
    final eventId = await widget.room.sendTextEvent(text, inReplyTo: replyTo);
    if (eventId == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "Message non envoyé (réseau indisponible ou serveur injoignable) — il reste visible ci-dessus, en attente"),
        ),
      );
    }
  }

  /// Suite à la revue croisée IA (« niveau Telegram/Signal ») notant l'absence d'envoi de
  /// photo/vidéo — jamais implémentée jusqu'ici dans ce dépôt (voir `lib/media.dart`).
  ///
  /// Trouvé en audit interne (revue croisée IA, recoupée par Grok et Qwen indépendamment) :
  /// seule la galerie était proposée, jamais la prise de photo directe — `CAMERA` est pourtant
  /// déjà déclarée dans AndroidManifest.xml (pour les appels WebRTC), rien à y ajouter. [source]
  /// vient du menu affiché par le bouton appareil photo de la barre de saisie, ci-dessous.
  ///
  /// [stripExifAndReencode] est appelée AVANT tout chiffrement/envoi, jamais après, QUELLE QUE
  /// SOIT la source — voir le threat model documenté dans `lib/media.dart` (GPS, horodatage
  /// précis, modèle d'appareil survivraient sinon au chiffrement de bout en bout) : une photo
  /// prise à l'instant par l'appareil contient exactement les mêmes métadonnées EXIF qu'une photo
  /// choisie dans la galerie, le même retrait s'applique donc sans distinction de source.
  /// `MatrixImageFile` + `Room.sendFileEvent` chiffrent automatiquement la pièce jointe pour un
  /// salon chiffré (vérifié contre le SDK matrix-dart pinné : `Room.sendFileEvent` chiffre dès que
  /// `encrypted && client.fileEncryptionEnabled`, ce qui est le cas ici — ce dépôt appelle
  /// `vod.init()` au démarrage).
  Future<void> _pickAndSendImage(ImageSource source) async {
    if (_sendingMedia) return;
    final XFile? picked = await ImagePicker().pickImage(source: source, imageQuality: 90);
    if (picked == null) return;
    if (!mounted) return;
    setState(() => _sendingMedia = true);
    try {
      final rawBytes = await picked.readAsBytes();
      final Uint8List clean;
      try {
        clean = stripExifAndReencode(rawBytes);
      } on FormatException {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Image illisible : fichier non reconnu, envoi annulé')),
          );
        }
        return;
      }
      final file = MatrixImageFile(bytes: clean, name: 'photo.jpg');
      final eventId = await widget.room.sendFileEvent(file);
      if (eventId == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                "Photo non envoyée (réseau indisponible ou serveur injoignable) — réessayez plus tard"),
          ),
        );
      }
    } finally {
      // Trouvé en audit interne : `ImagePicker` écrit sa propre copie recompressée
      // (`imageQuality: 90`) dans le cache de l'appli, en dehors de `MediaCache`
      // (lib/media.dart) — ni purgée au démarrage, ni effacée par le wipe d'urgence
      // (Account.wipeLocal/panic, qui ne connaît que son propre répertoire `murmure_media`).
      // `image_picker` ne garantit pas le retrait de l'EXIF (GPS, horodatage, modèle
      // d'appareil) lors de sa recompression : exactement la donnée que
      // [stripExifAndReencode] existe pour retirer avant tout envoi pouvait donc rester en
      // clair sur le disque, hors de toute garantie d'effacement d'urgence documentée
      // ailleurs dans ce dépôt.
      //
      // Un simple `delete()` ne fait que désindexer le fichier : les données restent lisibles
      // sur la mémoire flash jusqu'à réécriture par le système (même threat model que documenté
      // dans `MediaCache` — vol/saisie de l'appareil juste après l'envoi d'une photo prise à
      // l'instant, GPS/horodatage inclus). [MediaCache.wipe] applique ici le même traitement
      // (écrasement à zéro puis suppression) que pour les médias reçus, bien que ce fichier ne
      // vive pas dans le répertoire `murmure_media` — [MediaCache.wipe] opère sur un [File]
      // quelconque, peu importe son emplacement. Toujours best-effort : ne bloque jamais l'envoi
      // sur ce nettoyage.
      try {
        await MediaCache.wipe(File(picked.path));
      } catch (_) {}
      if (mounted) setState(() => _sendingMedia = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = _timeline?.events.where((e) => e.type == EventTypes.Message).toList() ?? [];
    final verificationStatus = _deviceVerificationStatus();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.room.getLocalizedDisplayname()),
        actions: [
          if (verificationStatus != null)
            IconButton(
              icon: Icon(
                verificationStatus ? Icons.verified_user : Icons.gpp_maybe_outlined,
                color: verificationStatus
                    ? Colors.green
                    : Theme.of(context).colorScheme.error,
              ),
              tooltip: verificationStatus
                  ? 'Appareils vérifiés'
                  : 'Appareils non vérifiés — appuyez pour vérifier',
              onPressed: _openDeviceVerification,
            ),
          IconButton(
            icon: const Icon(Icons.call),
            tooltip: 'Appel audio',
            onPressed: () => _call(CallType.kVoice),
          ),
          IconButton(
            icon: const Icon(Icons.videocam),
            tooltip: 'Appel vidéo',
            onPressed: () => _call(CallType.kVideo),
          ),
          // Trouvé en audit interne (revue croisée IA) : une fois un groupe créé
          // (NewGroupScreen, group_screen.dart), aucun moyen de l'administrer — ni ajouter ni
          // retirer un membre, ni le renommer. N'a de sens que pour un groupe au sens Matrix
          // (plusieurs membres), jamais pour une conversation directe à deux.
          if (!widget.room.isDirectChat)
            IconButton(
              icon: const Icon(Icons.group_outlined),
              tooltip: 'Infos du groupe',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => GroupInfoScreen(room: widget.room)),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _timeline == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    reverse: true,
                    itemCount: events.length,
                    itemBuilder: (context, i) {
                      final e = events[i];
                      final mine = e.senderId == widget.room.client.userID;
                      final scheme = Theme.of(context).colorScheme;
                      final bubbleColor =
                          mine ? scheme.primaryContainer : scheme.surfaceContainerHighest;
                      final textColor = mine ? scheme.onPrimaryContainer : scheme.onSurface;
                      final metaColor =
                          (mine ? scheme.onPrimaryContainer : scheme.onSurfaceVariant)
                              .withValues(alpha: 0.7);
                      // Nom de l'expéditeur affiché uniquement dans un groupe (jamais pour une
                      // conversation directe à deux, où il serait redondant avec le titre de
                      // l'écran) et jamais pour ses propres messages.
                      final showSenderName = !mine && !widget.room.isDirectChat;
                      // Trouvé en audit interne (revue croisée IA) : citer un message précis en
                      // répondant n'existait pas du tout. `inReplyTo` (voir [_send]) ajoute une
                      // relation `m.in_reply_to` que le SDK reconnaît ici via `relationshipType` —
                      // on résout l'événement cité pour l'afficher au-dessus de la réponse.
                      final isReply = e.relationshipType == RelationshipTypes.reply;
                      // Trouvé en audit interne (revue croisée IA, « niveau Telegram/Signal ») :
                      // aucun accusé de lecture visible — [_maybeSendReadMarker] envoie le marqueur,
                      // `Event.receipts` (SDK pinné) donne qui a lu CET événement précisément.
                      final seenByOther =
                          mine && e.receipts.any((r) => r.user.id != widget.room.client.userID);
                      return GestureDetector(
                        onLongPress: () => _setReplyTarget(e),
                        child: Align(
                          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            constraints:
                                BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                            decoration: BoxDecoration(
                              color: bubbleColor,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (showSenderName)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 2),
                                    child: Text(
                                      e.senderFromMemoryOrFallback.calcDisplayname(),
                                      style: TextStyle(
                                        color: murmureAvatarColor(e.senderId),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                if (isReply)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: _ReplyQuote(event: e, timeline: _timeline!, metaColor: metaColor),
                                  ),
                                if (e.messageType == MessageTypes.Image)
                                  _MessageImage(event: e)
                                else
                                  Text(
                                    isReply ? _stripReplyFallback(e.text) : e.text,
                                    style: TextStyle(color: textColor),
                                  ),
                                const SizedBox(height: 2),
                                // Trouvé en audit interne, suite à la revue croisée IA sur l'écart avec
                                // Telegram/Signal : `_send()` lit déjà `EventStatus` (voir plus haut)
                                // pour prévenir une fois en cas d'échec, mais rien n'affichait ensuite
                                // l'état du message DANS la bulle elle-même — un message resté en
                                // `sending` (réseau coupé juste après l'envoi, cas normal pour l'usage
                                // visé par cette appli) ou passé en `error` reprenait l'apparence
                                // exacte d'un message bien parti dès que le SnackBar disparaissait.
                                // `Event.status` (matrix-dart-sdk, event_status.dart) est vérifié ici
                                // contre le SDK pinné : `.isSending`/`.isError` existent tels quels.
                                if (mine && (e.status.isSending || e.status.isError))
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        e.status.isError ? Icons.error_outline : Icons.schedule,
                                        size: 12,
                                        color: e.status.isError ? scheme.error : metaColor,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        e.status.isError ? 'Échec de l\'envoi' : 'En attente…',
                                        style: TextStyle(
                                          color: e.status.isError ? scheme.error : metaColor,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  )
                                else
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        DateFormat.Hm().format(e.originServerTs),
                                        style: TextStyle(color: metaColor, fontSize: 11),
                                      ),
                                      if (seenByOther) ...[
                                        const SizedBox(width: 4),
                                        Icon(Icons.done_all, size: 13, color: metaColor),
                                      ],
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_replyingTo != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Réponse à ${_replyingTo!.senderFromMemoryOrFallback.calcDisplayname()}',
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                          ),
                          Text(
                            _stripReplyFallback(_replyingTo!.text),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: 'Annuler la réponse',
                      onPressed: _cancelReply,
                    ),
                  ],
                ),
              ),
            ),
          if (_typingOtherUserIds.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                widget.room.isDirectChat
                    ? 'En train d\'écrire…'
                    : _typingOtherUserIds.length == 1
                        ? '${widget.room.unsafeGetUserFromMemoryOrFallback(_typingOtherUserIds.first).calcDisplayname()} est en train d\'écrire…'
                        : 'Plusieurs personnes écrivent…',
                style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _sendingMedia
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : PopupMenuButton<ImageSource>(
                          icon: const Icon(Icons.image_outlined),
                          tooltip: 'Envoyer une photo',
                          onSelected: _pickAndSendImage,
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: ImageSource.camera,
                              child: ListTile(
                                leading: Icon(Icons.photo_camera_outlined),
                                title: Text('Prendre une photo'),
                              ),
                            ),
                            PopupMenuItem(
                              value: ImageSource.gallery,
                              child: ListTile(
                                leading: Icon(Icons.photo_library_outlined),
                                title: Text('Choisir dans la galerie'),
                              ),
                            ),
                          ],
                        ),
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      decoration: const InputDecoration(hintText: 'Message…'),
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      onChanged: _onComposingChanged,
                      onSubmitted: (_) => _send(),
                      textInputAction: TextInputAction.send,
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    icon: const Icon(Icons.send),
                    tooltip: 'Envoyer',
                    onPressed: _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Citation affichée au-dessus d'un message qui répond à un autre (`m.in_reply_to`, voir
/// [_ChatScreenState._send] et `_stripReplyFallback`). `Event.getReplyEvent` (SDK pinné) est
/// asynchrone — il consulte d'abord la timeline déjà chargée en mémoire avant toute requête
/// réseau — donc un `FutureBuilder` plutôt qu'une lecture synchrone ; le texte cité reste vide un
/// court instant plutôt que de bloquer l'affichage du message lui-même.
class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.event, required this.timeline, required this.metaColor});
  final Event event;
  final Timeline timeline;
  final Color metaColor;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Event?>(
      future: event.getReplyEvent(timeline),
      builder: (context, snapshot) {
        final quoted = snapshot.data;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: metaColor, width: 2)),
          ),
          child: Text(
            quoted == null
                ? '…'
                : '${quoted.senderFromMemoryOrFallback.calcDisplayname()} : '
                    '${_stripReplyFallback(quoted.text)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: metaColor, fontSize: 12, fontStyle: FontStyle.italic),
          ),
        );
      },
    );
  }
}

/// Affiche une image reçue : télécharge et déchiffre la pièce jointe via le SDK matrix-dart
/// (`Event.downloadAndDecryptAttachment`, vérifié contre le SDK pinné — gère aussi bien les
/// pièces jointes chiffrées, avec `file`/`key`/`iv`, que non chiffrées), puis l'affiche
/// directement depuis la mémoire (`Image.memory`) sans jamais l'écrire sur le disque de
/// l'appareil : pour une vignette de conversation, garder les octets déchiffrés uniquement en
/// mémoire — jamais même brièvement en clair sur le disque — est une protection plus stricte que
/// le couple écriture-puis-effacement de [MediaCache] (réservé à un futur écran plein cadre/
/// sauvegarde explicite, pas à l'affichage courant de la liste de messages).
///
/// Le futur de téléchargement est calculé une seule fois dans [initState] (jamais reconstruit à
/// chaque frame de la liste, qui se reconstruit souvent — nouveaux messages, changement de statut
/// d'envoi) et mis en cache par événement grâce à la [Key] stable passée par l'appelant
/// (`event.eventId`), pour qu'un nouveau widget ne soit créé, et donc qu'un nouveau téléchargement
/// ne soit relancé, que pour un événement réellement différent.
class _MessageImage extends StatefulWidget {
  _MessageImage({required this.event}) : super(key: ValueKey(event.eventId));
  final Event event;

  @override
  State<_MessageImage> createState() => _MessageImageState();
}

class _MessageImageState extends State<_MessageImage> {
  late final Future<MatrixFile> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.event.downloadAndDecryptAttachment();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: FutureBuilder<MatrixFile>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Container(
              width: 180,
              height: 120,
              alignment: Alignment.center,
              color: Theme.of(context).colorScheme.errorContainer,
              child: Icon(Icons.broken_image_outlined,
                  color: Theme.of(context).colorScheme.onErrorContainer),
            );
          }
          final file = snapshot.data;
          if (file == null) {
            return const SizedBox(
              width: 180,
              height: 120,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          return Image.memory(
            file.bytes,
            width: 240,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => Container(
              width: 180,
              height: 120,
              alignment: Alignment.center,
              color: Theme.of(context).colorScheme.errorContainer,
              child: Icon(Icons.broken_image_outlined,
                  color: Theme.of(context).colorScheme.onErrorContainer),
            ),
          );
        },
      ),
    );
  }
}
