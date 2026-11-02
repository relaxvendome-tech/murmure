import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../account.dart';
import 'lock_screens.dart';
import 'mesh_screen.dart';
import 'qr_screens.dart';

/// Liste des conversations. Point d'entrée vers une discussion, l'ajout d'un contact, et les
/// réglages (verrou, mode Bluetooth, réseau).
class RoomsScreen extends StatelessWidget {
  const RoomsScreen({super.key, required this.client});
  final Client client;

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
              builder: (_) => LockSettingsScreen(onToggleCalcMode: (_) async {}),
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
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => ChatScreen(room: room))),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => AddContactScreen(client: client))),
        child: const Icon(Icons.person_add_alt_1),
      ),
    );
  }
}

/// Ajout d'un contact par identifiant Matrix (collé ou scanné par QR) ; ouvre ou crée la
/// conversation directe chiffrée (Megolm) avec lui.
class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key, required this.client});
  final Client client;

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
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen(room: room)));
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
  const ChatScreen({super.key, required this.room});
  final Room room;

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
      appBar: AppBar(title: Text(widget.room.getLocalizedDisplayname())),
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
