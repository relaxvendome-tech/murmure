import 'dart:io';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../account.dart';
import '../calls/call_policy.dart';
import '../calls/services/call_manager.dart';
import '../network.dart';
import '../stealth.dart';
import 'group_screen.dart';
import 'lock_screens.dart';
import 'mesh_screen.dart';
import 'qr_screens.dart';

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
      body: StreamBuilder<Object?>(
        stream: client.onSync.stream,
        builder: (context, _) {
          final rooms = client.rooms.where((r) => !r.isSpace).toList()
            ..sort((a, b) => (b.lastEvent?.originServerTs ?? DateTime(0))
                .compareTo(a.lastEvent?.originServerTs ?? DateTime(0)));
          if (rooms.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Aucune conversation. Ajoutez un contact pour commencer.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: rooms.length,
            itemBuilder: (context, i) {
              final room = rooms[i];
              return ListTile(
                leading: CircleAvatar(child: Text(room.getLocalizedDisplayname()[0].toUpperCase())),
                title: Text(room.getLocalizedDisplayname()),
                subtitle: Text(
                  room.lastEvent?.text ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
                    if (scanned != null && mounted) {
                      setState(() => _idCtrl.text = scanned);
                    }
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
              child: _busy ? const CircularProgressIndicator() : const Text('Démarrer la conversation'),
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
  Future<void> _call() async {
    final net = await NetConfig.load();
    if (!CallPolicy.isAllowed(net.mode)) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Appel désactivé'),
          content: const Text(
            'Les appels audio/vidéo sont désactivés en mode Tor/proxy : le flux audio/vidéo ne '
            'peut pas être protégé par ce mode. Voir docs/CALLS_ARCHITECTURE.md.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    await widget.callManager.startCall(widget.room, type: CallType.kVoice);
    // La navigation vers CallSessionScreen est faite par MurmureWebRTCDelegate.handleNewCall
    // (voir lib/calls/services/call_manager.dart), pas ici : c'est le même chemin que pour un
    // appel entrant, donc un seul endroit à maintenir pour l'UI d'appel.
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.room.getLocalizedDisplayname()),
        actions: [
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
                      return Align(
                        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                          decoration: BoxDecoration(
                            color: mine
                                ? Theme.of(context).colorScheme.primaryContainer
                                : Theme.of(context).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(e.text),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      decoration: const InputDecoration(hintText: 'Message…'),
                      onSubmitted: (_) => _send(),
                      textInputAction: TextInputAction.send,
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.send), onPressed: _send),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
