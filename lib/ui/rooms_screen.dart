import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';

import '../account.dart';
import '../calls/call_policy.dart';
import '../calls/services/call_manager.dart';
import '../calls/ui/missed_calls_screen.dart';
import '../network.dart';
import '../stealth.dart';
import 'device_verification_screen.dart';
import 'group_screen.dart';
import 'lock_screens.dart';
import 'mesh_screen.dart';
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
    return '${r.id}\u0000${r.getLocalizedDisplayname()}\u0000${last?.eventId ?? ''}\u0000'
        '${last?.originServerTs.millisecondsSinceEpoch ?? 0}';
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
                onToggleCalcMode: Stealth.setStealth,
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
          final rooms = client.rooms.where((r) => !r.isSpace).toList()
            ..sort((a, b) => (b.lastEvent?.originServerTs ?? DateTime(0))
                .compareTo(a.lastEvent?.originServerTs ?? DateTime(0)));
          if (rooms.isEmpty) {
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
            itemCount: rooms.length,
            itemBuilder: (context, i) {
              final room = rooms[i];
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

/// Conversation chiffrée (Olm/Megolm via vodozemac, géré en interne par le SDK Matrix).
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

  @override
  void initState() {
    super.initState();
    widget.room.getTimeline(onUpdate: () {
      if (mounted) setState(() {});
    }).then((t) {
      if (mounted) setState(() => _timeline = t);
    });
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
  Future<void> _call() async {
    final net = await NetConfig.load();
    if (!CallPolicy.isAllowed(net.mode)) {
      _showCallDisabledDialog(
        'Les appels audio/vidéo sont désactivés en mode Tor/proxy : le flux audio/vidéo ne '
        'peut pas être protégé par ce mode. Voir docs/CALLS_ARCHITECTURE.md.',
      );
      return;
    }
    final session = await widget.callManager.startCall(widget.room, type: CallType.kVoice);
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

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();
    await widget.room.sendTextEvent(text);
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
            tooltip: 'Appeler',
            onPressed: _call,
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
                      return Align(
                        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
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
                              Text(e.text, style: TextStyle(color: textColor)),
                              const SizedBox(height: 2),
                              Text(
                                DateFormat.Hm().format(e.originServerTs),
                                style: TextStyle(color: metaColor, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      decoration: const InputDecoration(hintText: 'Message…'),
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
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
