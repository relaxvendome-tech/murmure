import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';

import '../account.dart';
import '../calls/call_policy.dart';
import '../calls/services/call_manager.dart';
import '../calls/ui/missed_calls_screen.dart';
import '../ephemeral.dart';
import '../lock.dart';
import '../media.dart';
import '../message_notifier.dart';
import '../moderation.dart';
import '../network.dart';
import '../privacy_settings.dart';
import '../reactions.dart';
import '../verification/device_verification_status.dart';
import 'device_verification_screen.dart';
import 'group_info_screen.dart';
import 'group_screen.dart';
import 'lock_screens.dart';
import 'network_status_chip.dart';
import 'mesh_screen.dart';
import 'profile_screen.dart';
import 'search_screen.dart';
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
/// Inclut aussi, pour le dernier événement, son état rédigé et expiré (messages éphémères), ainsi
/// que la liste des utilisateurs bloqués : ces trois éléments changent l'aperçu affiché sans
/// forcément changer l'identifiant du dernier événement. L'expiration dépendant de l'heure, l'écran
/// se rafraîchit en plus toutes les 30 s (voir [_RoomsScreenState]).
String _roomsSignature(Client client) {
  final rooms = client.rooms.where((r) => !r.isSpace);
  final ignored = client.ignoredUsers.join(',');
  final parts = rooms.map((r) {
    final last = r.lastEvent;
    final expired = last != null && isExpired(last, r);
    // Trouvé en audit interne : `membership` doit faire partie de la signature, sinon accepter ou
    // refuser une invitation (Room.join()/Room.leave(), voir plus bas) ne faisait pas réafficher
    // la liste — l'id, le nom et le dernier événement du salon ne changent pas forcément à cette
    // occasion, seule son statut d'adhésion change.
    return '${r.id}\u0000${r.getLocalizedDisplayname()}\u0000${last?.eventId ?? ''}\u0000'
        '${last?.originServerTs.millisecondsSinceEpoch ?? 0}\u0000${r.membership}\u0000'
        '${last?.redacted ?? false}\u0000$expired';
  });
  return '$ignored\u0002${parts.join('\u0001')}';
}

/// Liste des conversations. Point d'entrée vers une discussion, l'ajout d'un contact, et les
/// réglages (verrou, mode Bluetooth, réseau).
class RoomsScreen extends StatefulWidget {
  const RoomsScreen({super.key, required this.client, required this.callManager});
  final Client client;
  final CallManager callManager;

  @override
  State<RoomsScreen> createState() => _RoomsScreenState();
}

/// Aperçu du dernier message d'une conversation dans la liste : vide s'il est rédigé, expiré ou
/// envoyé par un utilisateur bloqué (voir `hideRoomPreview`, lib/moderation.dart).
String _roomPreview(Room room) {
  final last = room.lastEvent;
  if (last == null) return '';
  if (hideRoomPreview(
    redacted: last.redacted,
    expired: isExpired(last, room),
    senderBlocked: isSenderBlocked(last.senderId, room.client.ignoredUsers),
  )) {
    return '';
  }
  // Une demande de vérification d'appareil n'est pas un message de conversation : jamais
  // affichée comme aperçu du dernier message. Une réaction non plus.
  if (last.messageType == EventTypes.KeyVerificationRequest) return '';
  if (last.type == EventTypes.Reaction) return '';
  if (last.type == EventTypes.Encrypted) return 'Message illisible sur cet appareil';
  return last.text;
}

enum _DeleteFailedChoice { retry, wipeLocalOnly, cancel }

class _RoomsScreenState extends State<RoomsScreen> {
  Client get client => widget.client;
  CallManager get callManager => widget.callManager;

  /// Flux créé une seule fois (et non à chaque `build`), pour que le rafraîchissement périodique
  /// ne réabonne pas le `StreamBuilder`.
  late final Stream<String> _signatures =
      client.onSync.stream.map((_) => _roomsSignature(client)).distinct();

  /// Rafraîchit la liste toutes les 30 s : un message éphémère peut expirer sans aucune synchro.
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// « Supprimer mon compte » : suppression côté serveur d'abord (dialogue de progression), puis
  /// effacement local + fermeture. En cas d'échec (hors ligne…), le téléphone n'est PAS effacé sans
  /// prévenir : l'utilisateur choisit entre réessayer, n'effacer que ce téléphone (le compte reste
  /// alors sur le serveur) ou annuler. [Account.panic] reste l'effacement inconditionnel.
  Future<void> _deleteAccount() async {
    while (true) {
      if (!mounted) return;
      BuildContext? progressCtx;
      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dctx) {
          progressCtx = dctx;
          return const PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(children: [
              SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
              SizedBox(width: 20),
              Expanded(child: Text('Suppression du compte sur le serveur…')),
            ]),
          ),
        );
        },
      ));
      Object? failure;
      try {
        await Account.deactivateRemote(client).timeout(const Duration(seconds: 45));
      } catch (e) {
        failure = e;
      }
      // Ferme CE dialogue précisément : un écran d'appel ou un reverrouillage a pu se poser
      // au-dessus pendant l'attente, et pop() aurait fermé le mauvais écran.
      final pc = progressCtx;
      if (pc != null && pc.mounted) {
        final r = ModalRoute.of(pc);
        if (r != null && r.isActive) Navigator.of(pc).removeRoute(r);
      }
      if (failure == null) {
        try {
          await Account.wipeLocal(client);
        } catch (_) {}
        exit(0);
      }
      if (!mounted) return;
      final choice = await showDialog<_DeleteFailedChoice>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Suppression impossible'),
          content: const Text('Suppression sur le serveur impossible (pas de connexion ?). '
              'Votre compte existe toujours sur le serveur.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(_DeleteFailedChoice.cancel),
              child: const Text('Annuler'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(_DeleteFailedChoice.wipeLocalOnly),
              child: const Text('Effacer seulement ce téléphone (le compte restera sur le serveur)'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(_DeleteFailedChoice.retry),
              child: const Text('Réessayer'),
            ),
          ],
        ),
      );
      switch (choice) {
        case _DeleteFailedChoice.retry:
          continue;
        case _DeleteFailedChoice.wipeLocalOnly:
          try {
            await Account.wipeLocal(client);
          } catch (_) {}
          exit(0);
        case _DeleteFailedChoice.cancel:
        case null:
          return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Text('Murmure'),
          const SizedBox(width: 8),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: NetworkStatusChip(client: client),
            ),
          ),
        ]),
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
                // Le téléphone n'est effacé qu'après la suppression CÔTÉ SERVEUR, ou sur choix
                // explicite de l'utilisateur si elle échoue (voir [_deleteAccount]).
                onDeleteAccount: _deleteAccount,
              ),
            )),
          ),
        ],
      ),
      body: StreamBuilder<String>(
        stream: _signatures,
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
          final ignoredUsers = client.ignoredUsers;
          // Invitation dont l'expéditeur est bloqué : exclue (voir `isInviteHidden`).
          final invites = allRooms
              .where((r) =>
                  r.membership == Membership.invite &&
                  !isInviteHidden(
                      r.getState(EventTypes.RoomMember, client.userID ?? '')?.senderId,
                      ignoredUsers))
              .toList()
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
              final preview = _roomPreview(room);
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
                  preview,
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

/// Conversation chiffrée (Olm/Megolm via vodozemac, géré en interne par le SDK Matrix — voir le
/// commentaire détaillé dans main.dart sur vodozemac et le refus de démarrer sans chiffrement).
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.room, required this.callManager});
  final Room room;
  final CallManager callManager;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _textCtrl = TextEditingController();
  Timeline? _timeline;
  bool _sendingMedia = false;

  /// Pagination arrière : la liste est `reverse`, donc le « haut » (messages les plus anciens)
  /// correspond à `maxScrollExtent`. [_loadingHistory] empêche toute réentrance.
  final ScrollController _scrollCtrl = ScrollController();
  bool _loadingHistory = false;

  /// Reconstruit périodiquement l'écran pour masquer les messages éphémères qui viennent
  /// d'expirer, même sans nouvel événement dans la timeline.
  Timer? _expiryTimer;

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

  /// Réglages de confidentialité (désactivés par défaut, voir PrivacySettings), chargés une fois
  /// à l'ouverture. [_settingsReady] est attendu avant tout envoi pour ne jamais émettre avant
  /// d'avoir lu le réglage.
  bool _sendReceipts = false;
  bool _sendTyping = false;
  late final Future<void> _settingsReady = () async {
    _sendReceipts = await PrivacySettings.sendReadReceipts();
    _sendTyping = await PrivacySettings.sendTyping();
  }();

  @override
  void initState() {
    super.initState();
    unawaited(_settingsReady); // déclenche le chargement des réglages (late final paresseux)
    MessageNotifier.activeRoomId = widget.room.id;
    WidgetsBinding.instance.addObserver(this);
    _scrollCtrl.addListener(_onScroll);
    _expiryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() {});
      // Le dernier message lisible a pu changer (expiration) sans nouvel événement.
      _maybeSendReadMarker();
    });
    // Plancher local et horodatage de l'état précédent du réglage éphémère (lib/ephemeral.dart).
    unawaited(refreshEphemeralState(widget.room).then((_) {
      if (mounted) setState(() {});
    }));
    widget.room.getTimeline(onUpdate: () {
      if (!mounted) return;
      setState(() {});
      _maybeSendReadMarker();
    }).then((t) {
      // Écran fermé avant la fin du chargement : dispose() n'a pas pu désabonner cette timeline
      // (encore nulle à ce moment-là), on le fait ici pour ne pas la laisser écouter le salon.
      if (!mounted) {
        t.cancelSubscriptions();
        return;
      }
      setState(() => _timeline = t);
      _maybeSendReadMarker();
      // Si la première page ne remplit pas l'écran, aucun défilement ne déclenchera la
      // pagination : on vérifie une fois après le premier rendu.
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    }).catchError((_) {
      // Échec de chargement : l'indicateur reste affiché, sans journaliser de contenu.
    });
    EphemeralService.instance.start(widget.room.client);
    unawaited(EphemeralService.instance.sweepRoom(widget.room));
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
    // Jamais d'accusé si l'appli n'est pas au premier plan, si elle est verrouillée, ou si un
    // autre écran recouvre cette conversation : l'utilisateur ne lit pas réellement les messages.
    if (!mounted) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    if (!AppLock.isUnlocked) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    // Dernier message réellement affichable : envoyé (pas un écho local en attente ou en échec,
    // dont l'identifiant n'existe pas côté serveur), non expiré, d'un expéditeur non bloqué.
    final ignoredUsers = widget.room.client.ignoredUsers;
    final latest = _timeline?.events
        .where((e) =>
            e.type == EventTypes.Message &&
            // Voir le même filtre dans [build] : une édition n'est jamais un message affiché,
            // elle ne doit donc pas non plus faire avancer le marqueur de lecture.
            e.relationshipType != RelationshipTypes.edit &&
            e.status.isSent &&
            !isExpired(e, widget.room) &&
            !isSenderBlocked(e.senderId, ignoredUsers))
        .fold<Event?>(null, (latest, e) =>
            latest == null || e.originServerTs.isAfter(latest.originServerTs) ? e : latest);
    if (latest == null || latest.eventId == _lastReadMarkerEventId) return;
    _lastReadMarkerEventId = latest.eventId;
    // SDK v0.29.0 (room.dart:1394) : `setReadMarker` envoie TOUJOURS `m.fully_read` et
    // `m.read.private` (privé, invisible des autres) ; `m.read` (public) seulement si
    // `public ?? client.receiptsPublicByDefault` (défaut true). On passe donc `public`
    // explicitement : sans réglage activé, le compteur de non-lus se remet à zéro sans accusé public.
    final id = latest.eventId;
    unawaited(_settingsReady
        .then((_) => widget.room.setReadMarker(id, mRead: id, public: _sendReceipts))
        .catchError((_) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _maybeSendReadMarker();
  }

  void _onScroll() {
    if (!mounted || !_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 300) unawaited(_loadMoreHistory());
  }

  Future<void> _loadMoreHistory() async {
    final timeline = _timeline;
    if (timeline == null || _loadingHistory) return;
    if (timeline.isRequestingHistory || !timeline.canRequestHistory) return;
    setState(() => _loadingHistory = true);
    final before = timeline.events.length;
    try {
      await timeline.requestHistory();
    } catch (_) {
      // Réseau indisponible : on réessaiera au prochain défilement.
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
    // Une page peut ne contenir que des événements non affichés (états, réactions, messages
    // expirés ou d'un bloqué) : la liste ne grandit pas, aucun défilement ne relancerait la
    // pagination. On revérifie donc après le prochain rendu si des événements ont été ajoutés.
    if (mounted && timeline.events.length > before) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    }
  }

  /// Bouton « Réessayer » d'un message non déchiffrable : redemande la clé de session aux autres
  /// appareils (`Event.requestKey`, qui lève si la clé n'est pas demandable).
  Future<void> _requestKey(Event e) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await e.requestKey();
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
          content: Text('Clé demandée à vos autres appareils et aux participants')));
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
          content: Text('Impossible de demander la clé pour ce message')));
    }
  }

  void _setReplyTarget(Event e) => setState(() => _replyingTo = e);

  /// Vrai si les messages éphémères sont actifs : les réactions (non chiffrées, voir
  /// lib/reactions.dart) sont alors désactivées et masquées.
  bool get _ephemeralActive => ephemeralTtlSeconds(widget.room) > 0;

  /// Version à jour (depuis la timeline) du message cité en réponse, ou null s'il n'est plus
  /// utilisable : rédigé, expiré, ou expéditeur bloqué (voir `isReplyTargetUsable`).
  Event? _usableReplyTarget() {
    final target = _replyingTo;
    if (target == null) return null;
    var current = target;
    for (final e in _timeline?.events ?? const <Event>[]) {
      if (e.eventId == target.eventId) {
        current = e;
        break;
      }
    }
    final usable = isReplyTargetUsable(
      redacted: current.redacted,
      expired: isExpired(current, widget.room),
      senderBlocked: isSenderBlocked(current.senderId, widget.room.client.ignoredUsers),
    );
    return usable ? current : null;
  }

  void _cancelReply() => setState(() => _replyingTo = null);

  /// Réactions (emoji) actives sur [e] d'après la timeline chargée, réduites à ce dont
  /// lib/reactions.dart a besoin. `Event.aggregatedEvents` (SDK pinné) retire déjà lui-même une
  /// réaction redevenue redactée (voir `Timeline.removeAggregatedEvent`) ; `!r.redacted` reste une
  /// garde défensive bon marché plutôt qu'une correction d'un défaut connu du SDK.
  List<ReactionEntry> _reactionsOf(Event e) {
    final timeline = _timeline;
    if (timeline == null) return const [];
    // Salon éphémère : réactions non affichées (elles ne sont pas chiffrées).
    if (_ephemeralActive) return const [];
    final ignoredUsers = widget.room.client.ignoredUsers;
    final result = <ReactionEntry>[];
    for (final r in e.aggregatedEvents(timeline, RelationshipTypes.reaction)) {
      if (r.redacted) continue;
      // Réaction expirée : ignorée (garde défensive ; dans un salon éphémère, les réactions sont
      // de toute façon masquées ci-dessus).
      if (isExpired(r, widget.room)) continue;
      // Voir lib/moderation.dart : la réaction d'un expéditeur bloqué n'est pas plus filtrée par
      // le SDK ou le serveur que ses messages (section « events » de [build]) — même filtre ici.
      if (isSenderBlocked(r.senderId, ignoredUsers)) continue;
      final key = reactionKeyOf(r.content);
      if (key == null) continue;
      result.add((senderId: r.senderId, key: key));
    }
    return result;
  }

  /// Bascule la réaction [key] de l'utilisateur sur [target] : l'ajoute si absente, retire SES
  /// propres réactions portant ce même emoji si déjà présente (plusieurs appareils du même compte
  /// pourraient en théorie en avoir posé plus d'une ; on les retire toutes par cohérence). Jamais
  /// de retour visuel bloquant en cas d'échec (hors ligne, droit insuffisant) : la timeline reste
  /// la seule source de vérité affichée, un nouvel appui retentera au prochain appui.
  Future<void> _toggleReaction(Event target, String key) async {
    final myId = widget.room.client.userID;
    if (myId == null) return;
    final timeline = _timeline;
    if (timeline == null) return;
    if (_ephemeralActive) return; // réactions désactivées (non chiffrées)
    final mine = target
        .aggregatedEvents(timeline, RelationshipTypes.reaction)
        .where((r) => !r.redacted && r.senderId == myId && reactionKeyOf(r.content) == key)
        .toList();
    try {
      if (mine.isNotEmpty) {
        for (final r in mine) {
          await r.redactEvent();
        }
      } else {
        await widget.room.sendReaction(target.eventId, key);
      }
    } catch (_) {
      // Best-effort : voir le commentaire ci-dessus.
    }
  }

  /// Menu d'appui long sur un message : réagir (emoji rapides) ou répondre. Remplace l'ancien
  /// comportement (appui long = répondre directement) par un choix explicite, pour ajouter les
  /// réactions sans perdre l'accès à la réponse.
  Future<void> _showMessageActions(Event e) async {
    final myId = widget.room.client.userID;
    final existing = _reactionsOf(e);
    final reactionsDisabled = _ephemeralActive;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reactionsDisabled)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 14, 20, 10),
                child: Text(
                  'Réactions désactivées dans cette conversation : les réactions ne sont pas '
                  'chiffrées (le serveur voit l\'emoji, le message visé et l\'auteur) et ne '
                  'conviennent pas aux messages éphémères.',
                  style: TextStyle(fontSize: 12),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    for (final emoji in kQuickReactions)
                      IconButton(
                        icon: Text(emoji, style: const TextStyle(fontSize: 22)),
                        tooltip: myId != null && hasOwnReaction(existing, myId, emoji)
                            ? 'Retirer cette réaction'
                            : 'Réagir avec $emoji',
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          unawaited(_toggleReaction(e, emoji));
                        },
                      ),
                  ],
                ),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.reply_outlined),
              title: const Text('Répondre'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _setReplyTarget(e);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Trouvé en audit interne : filtrait déjà `myId`, mais pas un expéditeur bloqué
  /// ([Client.ignoredUsers]) — un contact bloqué reste généralement membre de la conversation
  /// directe ([_blockContact] appelle `ignoreUser(leaveRooms: false)`, voir `lib/moderation.dart`)
  /// et peut donc continuer à émettre `m.typing`, que ni le SDK ni Synapse ne filtrent pour un
  /// salon déjà rejoint (même constat que pour les messages/réactions dans `lib/moderation.dart` :
  /// rien côté serveur ou SDK ne retire quoi que ce soit d'un expéditeur ignoré). Sans ce filtre,
  /// « X est en train d'écrire… » s'affichait quand même pour un contact qu'on a justement bloqué
  /// pour ne plus rien voir de lui — même classe de bug que celle déjà corrigée pour les messages
  /// et réactions, juste pas étendue à cet indicateur, ajouté dans une passe ultérieure.
  void _refreshTypingUsers() {
    final myId = widget.room.client.userID;
    final ignoredUsers = widget.room.client.ignoredUsers;
    final ids = widget.room.typingUsers
        .map((u) => u.id)
        .where((id) => id != myId && !isSenderBlocked(id, ignoredUsers))
        .toSet();
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
    if (_typingActive || !_sendTyping) return;
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
    if (MessageNotifier.activeRoomId == widget.room.id) MessageNotifier.activeRoomId = null;
    WidgetsBinding.instance.removeObserver(this);
    _expiryTimer?.cancel();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
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
      if (!mounted) return;
      _showCallDisabledDialog(widget.room.isDirectChat
          ? "L'appel n'a pas pu démarrer : serveur d'appels indisponible, ou micro/caméra "
              'refusé(e). Vérifiez les autorisations et réessayez plus tard.'
          : 'Les appels de groupe ne sont pas disponibles : appelez un contact en conversation '
              'directe.');
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
    return userVerificationStatus(widget.room.client, otherId);
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
    if (!mounted) return;
    setState(() {});
    _maybeSendReadMarker();
  }

  /// Bloque le contact d'une conversation directe (`Client.ignoreUser`, écrit
  /// `m.ignored_user_list`) : ses invitations futures sont déjà filtrées par le serveur
  /// (vérifié dans Synapse) ; ses messages et réactions dans CETTE conversation, eux, ne le sont
  /// ni par le SDK ni par le serveur (voir lib/moderation.dart) — c'est le filtre appliqué dans
  /// [build] et [_reactionsOf] qui les masque réellement. Il n'est pas averti du blocage. Aucun
  /// contenu journalisé.
  Future<void> _blockContact() async {
    final otherId = widget.room.directChatMatrixID;
    if (otherId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bloquer ce contact ?'),
        content: const Text(
            'Vous ne recevrez plus ses messages ni ses invitations. Il n\'en sera pas averti. '
            'Vous pourrez le débloquer à tout moment depuis Mon profil > Utilisateurs bloqués.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true), child: const Text('Bloquer')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      // `leaveRooms: false` : depuis matrix 3.0.0, `ignoreUser` QUITTE par défaut les
      // conversations directes avec ce contact (événement `leave` visible par lui) et refuse ses
      // invitations. On garde le comportement d'avant la migration (simple
      // `m.ignored_user_list`, rien de visible côté contact) : le texte « Il n'en sera pas
      // averti » reste exact et « Débloquer » rend la conversation intacte.
      await widget.room.client.ignoreUser(otherId, leaveRooms: false);
      messenger.showSnackBar(const SnackBar(content: Text('Contact bloqué')));
      navigator.pop();
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text(
              'Impossible de bloquer ce contact. Vérifiez votre connexion réseau et réessayez.')));
    }
  }

  /// Dialogue de choix de la durée des messages éphémères (événement d'état `fr.murmure.ephemeral`,
  /// voir lib/ephemeral.dart). L'événement d'état n'est pas chiffré : seule la durée est visible
  /// du serveur, jamais le contenu des messages.
  Future<void> _showEphemeralDialog() async {
    final current = ephemeralTtlSeconds(widget.room);
    final chosen = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Messages éphémères'),
        children: [
          for (final c in kEphemeralChoices)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(c.$2),
              child: Row(children: [
                Expanded(child: Text(c.$1)),
                if (c.$2 == current) const Icon(Icons.check, size: 18),
              ]),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Text(
              'L\'effacement est garanti sur les appareils Murmure, pas contre une capture '
              'd\'écran ou un client modifié.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
    if (chosen == null || chosen == current || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await setEphemeralTtl(widget.room, chosen);
      if (!mounted) return;
      setState(() {});
      unawaited(EphemeralService.instance.sweepRoom(widget.room));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text(
              'Impossible de modifier ce réglage. Vérifiez votre connexion et vos droits dans la conversation.')));
    }
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
    // Message cité devenu rédigé, expiré ou venant d'un bloqué : la réponse est annulée (le SDK
    // recopierait sinon son texte dans le corps de repli `> <@...>` de la réponse).
    final replyTo = _usableReplyTarget();
    final replyDropped = _replyingTo != null && replyTo == null;
    _textCtrl.clear();
    if (_replyingTo != null) _cancelReply();
    if (replyDropped && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Le message cité n\'est plus disponible : envoyé sans citation')));
    }
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
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: source,
        imageQuality: 90,
        maxWidth: 2560,
        maxHeight: 2560,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible d\'accéder aux photos ou à l\'appareil photo')),
        );
      }
      return;
    }
    if (picked == null) return;
    if (!mounted) {
      unawaited(MediaCache.wipe(File(picked.path)));
      return;
    }
    setState(() => _sendingMedia = true);
    try {
      final rawBytes = await picked.readAsBytes();
      final Uint8List clean;
      try {
        // Décodage/ré-encodage JPEG coûteux : hors du thread UI pour ne pas figer l'écran.
        clean = await compute(stripExifAndReencode, rawBytes);
      } catch (_) {
        // FormatException (image non reconnue) ou erreur de l'isolat : on n'envoie jamais les
        // octets bruts non nettoyés.
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
    } on FileTooBigMatrixException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo trop lourde pour le serveur')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Échec de l\'envoi')),
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
    // Trouvé en audit interne (voir lib/moderation.dart pour le constat complet, vérifié contre
    // le SDK Matrix pinné et Synapse) : ni le SDK ni le serveur ne retirent d'un salon déjà
    // rejoint les messages d'un expéditeur bloqué ; seul ce filtre côté client peut tenir la
    // promesse faite à l'écran de confirmation de blocage (`_blockContact`).
    final ignoredUsers = widget.room.client.ignoredUsers;
    final events = _timeline?.events
            .where((e) =>
                // Les messages non déchiffrables (type resté `m.room.encrypted`) sont affichés
                // avec un bouton « Réessayer » plutôt que silencieusement masqués.
                (e.type == EventTypes.Message || e.type == EventTypes.Encrypted) &&
                // Une demande de vérification d'appareil n'est pas un message de conversation.
                e.messageType != EventTypes.KeyVerificationRequest &&
                // Trouvé en audit interne (vérifié contre le SDK matrix-dart pinné, event.dart :
                // `relationshipType`/`getDisplayEvent`) : une édition (`m.relates_to.rel_type ==
                // "m.replace"`) est un événement `m.room.message` à PART ENTIÈRE, donc passait ce
                // filtre comme n'importe quel autre message — ce code l'affichait comme une
                // DEUXIÈME bulle distincte (texte préfixé « * » par le SDK), au lieu de remplacer
                // le contenu affiché du message original. Deux conséquences réelles, pas
                // seulement cosmétiques : (1) un message édité apparaît deux fois dans
                // l'historique ; (2) si l'édition RETIRE une information sensible, l'ancien texte
                // reste pleinement visible dans sa bulle d'origine — l'édition échoue alors
                // totalement à faire ce que l'utilisateur en attend. Le SDK agrège déjà ces
                // événements lui-même (`Timeline.aggregatedEvents`, le même mécanisme que les
                // réactions) ; `getDisplayEvent` plus bas résout le texte à afficher.
                e.relationshipType != RelationshipTypes.edit &&
                !isExpired(e, widget.room) &&
                !isSenderBlocked(e.senderId, ignoredUsers))
            .toList() ??
        [];
    // Trouvé en audit interne, vérifié contre le SDK matrix-dart pinné (tag v0.29.13,
    // `models/receipts.dart` : `LatestReceiptState.update` écrit `timeline.otherUsers[user] =
    // receiptData`, une AFFECTATION qui écrase l'entrée précédente de cet utilisateur — la carte
    // ne retient donc jamais que le DERNIER événement lu par chaque autre participant, jamais
    // l'historique de ce qu'il a lu avant) : `Event.receipts` (event.dart) ne fait que comparer
    // `entry.value.eventId == eventId`, donc ne renvoie un résultat non vide QUE pour l'événement
    // exact que cette carte retient à l'instant présent. Conséquence réelle pour `seenByOther`
    // plus bas (avant ce correctif, basé directement sur `e.receipts.any(...)`) : la coche
    // « vu » apparaissait bien sur le dernier message lu par le correspondant, mais DISPARAISSAIT
    // de ce message dès qu'il en lisait un plus récent — l'ancienne carte ayant alors été
    // remplacée par la nouvelle, plus aucun événement ne correspond à l'ancien `eventId`. Aucune
    // appli de référence (Signal, Telegram, Element lui-même) ne fait disparaître une coche "lu"
    // déjà affichée de cette façon. On calcule donc maintenant « vu » par POSITION dans la
    // timeline (newest-first, comme `events` ci-dessus) plutôt que par correspondance exacte
    // d'identifiant : un message est vu dès qu'il est à la même position ou plus ancien que le
    // point le plus récent que N'IMPORTE QUEL autre participant a atteint — exactement ce que la
    // mise à jour de `LatestReceiptStateForTimeline` documente elle-même viser (« the one furthest
    // down in the timeline »). Un identifiant de reçu introuvable dans `events` (timeline pas
    // encore chargée jusque là) est ignoré plutôt que deviné : on ne prétend jamais un « vu » qu'on
    // ne peut pas situer.
    //
    // `events` est du plus récent au plus ancien (index 0 = le plus récent — vérifié contre
    // `Timeline` dans le SDK pinné : un événement live s'insère en tête, l'historique en pagination
    // arrière s'ajoute en queue), donc un indice PLUS GRAND veut dire un message PLUS ANCIEN. Un
    // reçu « lu jusqu'à X » couvre X et tout ce qui est plus ancien que X, donc tout indice >= celui
    // de X. Pour « vu par au moins un autre participant », c'est l'indice de reçu le plus PETIT
    // (celui qui couvre le plus de messages, donc les plus récents) qui fixe le seuil.
    final otherReceiptIndices = <int>{};
    for (final receipt in widget.room.receiptState.global.otherUsers.values) {
      final idx = events.indexWhere((e) => e.eventId == receipt.eventId);
      if (idx != -1) otherReceiptIndices.add(idx);
    }
    final minOtherReceiptIndex =
        otherReceiptIndices.isEmpty ? null : otherReceiptIndices.reduce((a, b) => a < b ? a : b);
    final verificationStatus = _deviceVerificationStatus();
    // Message cité devenu inutilisable (rédigé, expiré, expéditeur bloqué) : la réponse en cours
    // est annulée (après ce rendu) et son texte n'est plus affiché au-dessus du champ de saisie.
    final replyTarget = _usableReplyTarget();
    if (_replyingTo != null && replyTarget == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _replyingTo != null && _usableReplyTarget() == null) _cancelReply();
      });
    }
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
            icon: const Icon(Icons.search),
            tooltip: 'Rechercher dans cette conversation',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SearchInRoomScreen(room: widget.room)),
            ),
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
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => GroupInfoScreen(room: widget.room)),
                );
                // Cet écran recouvrait la conversation : aucun accusé n'a pu partir entre-temps.
                if (!mounted) return;
                setState(() {});
                _maybeSendReadMarker();
              },
            ),
          if (ephemeralTtlSeconds(widget.room) > 0)
            IconButton(
              icon: const Icon(Icons.timer_outlined),
              tooltip:
                  'Messages éphémères : ${ephemeralLabel(ephemeralTtlSeconds(widget.room))}',
              onPressed: _showEphemeralDialog,
            ),
          PopupMenuButton<String>(
            tooltip: 'Plus d\'options',
            onSelected: (v) {
              if (v == 'block') _blockContact();
              if (v == 'ephemeral') _showEphemeralDialog();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'ephemeral', child: Text('Messages éphémères')),
              if (widget.room.isDirectChat)
                const PopupMenuItem(value: 'block', child: Text('Bloquer ce contact')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _timeline == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scrollCtrl,
                    reverse: true,
                    itemCount: events.length + (_loadingHistory ? 1 : 0),
                    itemBuilder: (context, i) {
                      // Liste inversée : le dernier indice est affiché tout en haut.
                      if (i >= events.length) {
                        return const Padding(
                          padding: EdgeInsets.all(12),
                          child: Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        );
                      }
                      final e = events[i];
                      final undecryptable = e.type == EventTypes.Encrypted;
                      // Message rédigé (supprimé) : bulle « Message supprimé », sans citation,
                      // sans réactions ni menu d'actions.
                      final redacted = e.redacted;
                      // Trouvé en audit interne : voir le commentaire sur le filtre `events`
                      // ci-dessus. `getDisplayEvent` (SDK pinné, event.dart) renvoie le contenu à
                      // jour si `e` a été édité, `e` lui-même sinon ; on garde `e` pour tout ce
                      // qui identifie le message (clé de widget, réactions, reçus, réponse, menu
                      // d'actions) et n'utilise `display` que pour le TEXTE affiché — l'édition ne
                      // change jamais l'identité du message, seulement son contenu.
                      final display =
                          (redacted || undecryptable) ? e : e.getDisplayEvent(_timeline!);
                      // Signalé à l'utilisateur plutôt que substitué en silence : dans une appli
                      // où une édition peut servir à retirer une information envoyée par erreur,
                      // masquer qu'un message a changé serait trompeur (voir aussi le commentaire
                      // ci-dessus sur le risque inverse — l'ancien texte qui resterait visible).
                      final edited = !redacted &&
                          !undecryptable &&
                          e.hasAggregatedEvents(_timeline!, RelationshipTypes.edit);
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
                      // relation `m.in_reply_to` que le SDK reconnaît ici via `inReplyToEventId()`
                      // (matrix >= 4.0.0 : `RelationshipTypes.reply` supprimé) — on résout
                      // l'événement cité pour l'afficher au-dessus de la réponse.
                      final isReply = !redacted && e.inReplyToEventId() != null;
                      // Trouvé en audit interne (revue croisée IA, « niveau Telegram/Signal ») :
                      // aucun accusé de lecture visible — [_maybeSendReadMarker] envoie le marqueur.
                      // Calculé par position (voir [otherReceiptIndices] ci-dessus), pas par
                      // correspondance exacte d'identifiant d'événement : vu si ce message est à
                      // la même position ou plus ancien (indice plus grand, liste du plus récent
                      // au plus ancien) que le point de lecture le plus permissif.
                      final seenByOther =
                          mine && minOtherReceiptIndex != null && i >= minOtherReceiptIndex;
                      final reactions = undecryptable || redacted
                          ? const <ReactionEntry>[]
                          : _reactionsOf(e);
                      return GestureDetector(
                        onLongPress: undecryptable || redacted
                            ? null
                            : () => _showMessageActions(e),
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
                                if (redacted)
                                  Text(
                                    'Message supprimé',
                                    style: TextStyle(color: metaColor, fontStyle: FontStyle.italic),
                                  )
                                else if (undecryptable) ...[
                                  Text(
                                    'Message illisible sur cet appareil (clé manquante)',
                                    style: TextStyle(color: textColor, fontStyle: FontStyle.italic),
                                  ),
                                  TextButton(
                                    onPressed: () => _requestKey(e),
                                    child: const Text('Réessayer'),
                                  ),
                                ] else if (e.messageType == MessageTypes.Image)
                                  _MessageImage(event: e)
                                else
                                  Text(
                                    isReply
                                        ? _stripReplyFallback(display.text)
                                        : display.text,
                                    style: TextStyle(color: textColor),
                                  ),
                                if (reactions.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Wrap(
                                      spacing: 4,
                                      runSpacing: 4,
                                      children: [
                                        for (final entry
                                            in groupReactionsBySenders(reactions).entries)
                                          _ReactionChip(
                                            emoji: entry.key,
                                            count: entry.value.length,
                                            mine: entry.value.contains(widget.room.client.userID),
                                            onTap: () => _toggleReaction(e, entry.key),
                                          ),
                                      ],
                                    ),
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
                                      if (edited)
                                        Padding(
                                          padding: const EdgeInsets.only(right: 4),
                                          child: Text(
                                            'modifié',
                                            style: TextStyle(
                                              color: metaColor,
                                              fontSize: 11,
                                              fontStyle: FontStyle.italic,
                                            ),
                                          ),
                                        ),
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
          if (replyTarget != null)
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
                            'Réponse à ${replyTarget.senderFromMemoryOrFallback.calcDisplayname()}',
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                          ),
                          Text(
                            _stripReplyFallback(replyTarget.text),
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

/// Une chip de réaction (emoji + nombre) sous un message — voir [_ChatScreenState._toggleReaction].
/// [mine] : au moins un appareil de l'utilisateur courant a posé cette réaction (mise en évidence
/// visuelle, comme Telegram/Signal) ; un appui bascule (ajoute si absente, retire la ou les
/// réactions de l'utilisateur courant portant ce même emoji si déjà présente).
class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.mine,
    required this.onTap,
  });
  final String emoji;
  final int count;
  final bool mine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: mine ? Border.all(color: scheme.primary) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 13)),
            if (count > 1) ...[
              const SizedBox(width: 3),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  color: mine ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
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
        final String label;
        if (quoted == null) {
          label = '…';
        } else if (quoted.redacted) {
          label = 'Message supprimé';
        } else if (isExpired(quoted, quoted.room)) {
          label = 'Message expiré';
        } else if (isSenderBlocked(quoted.senderId, quoted.room.client.ignoredUsers)) {
          // Ni le nom ni le texte d'un expéditeur bloqué (voir lib/moderation.dart).
          label = 'Message masqué (expéditeur bloqué)';
        } else if (quoted.type == EventTypes.Encrypted) {
          label = 'Message illisible sur cet appareil';
        } else {
          label = '${quoted.senderFromMemoryOrFallback.calcDisplayname()} : '
              '${_stripReplyFallback(quoted.text)}';
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: metaColor, width: 2)),
          ),
          child: Text(
            label,
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

/// Taille maximale acceptée pour une image reçue (déclarée ET réelle) : au-delà, on refuse de
/// télécharger/décoder pour éviter un épuisement mémoire provoqué par un expéditeur malveillant.
const int _kMaxIncomingImageBytes = 15 * 1024 * 1024;

class _ImageTooLarge implements Exception {
  const _ImageTooLarge();
}

class _MessageImageState extends State<_MessageImage> {
  late final Future<MatrixFile> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<MatrixFile> _load() async {
    final declared = widget.event.infoMap['size'];
    if (declared is num && declared > _kMaxIncomingImageBytes) throw const _ImageTooLarge();
    final file = await widget.event.downloadAndDecryptAttachment();
    // La taille déclarée n'est qu'une indication de l'expéditeur : on revérifie la taille réelle.
    if (file.bytes.lengthInBytes > _kMaxIncomingImageBytes) throw const _ImageTooLarge();
    return file;
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: FutureBuilder<MatrixFile>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            final tooLarge = snapshot.error is _ImageTooLarge;
            return Container(
              width: 180,
              height: 120,
              alignment: Alignment.center,
              padding: const EdgeInsets.all(8),
              color: Theme.of(context).colorScheme.errorContainer,
              child: tooLarge
                  ? Text(
                      'Image trop volumineuse (plus de 15 Mo), non affichée',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    )
                  : Icon(Icons.broken_image_outlined,
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
            // Limite la résolution décodée en mémoire (une photo 4000 px décodée en pleine taille
            // pèse ~64 Mo de RGBA) : largement suffisant pour une vignette de 240 dp.
            cacheWidth: 480,
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
