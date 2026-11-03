import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../account.dart';
import 'qr_screens.dart';
import 'theme.dart';

/// Création d'un groupe chiffré (Megolm, comme toute conversation Murmure) à plusieurs membres.
/// Contrairement au canal Bluetooth hors-ligne (voir mesh_crypto.dart), la distribution des clés
/// de session de groupe est entièrement gérée par le SDK Matrix via des messages chiffrés de
/// l'appareil (to-device, Olm) — il n'y a pas de hachage de clé publique à faire circuler ici,
/// cette technique est propre au relais Bluetooth à l'aveugle, pas au protocole Matrix.
class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key, required this.client});
  final Client client;

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _nameCtrl = TextEditingController();
  final _memberCtrl = TextEditingController();
  final _members = <String>[];
  bool _busy = false;
  String? _error;

  void _addMember() {
    final raw = _memberCtrl.text.trim();
    final id = parseUserId(raw) ?? (raw.startsWith('@') ? raw : null);
    if (id == null) {
      setState(() => _error = 'Identifiant invalide (attendu : @nom:serveur)');
      return;
    }
    if (id == widget.client.userID) {
      setState(() => _error = 'C\'est votre propre identifiant');
      return;
    }
    if (_members.contains(id)) {
      setState(() => _error = 'Déjà ajouté');
      return;
    }
    setState(() {
      _members.add(id);
      _memberCtrl.clear();
      _error = null;
    });
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Choisissez un nom de groupe');
      return;
    }
    if (_members.length < 2) {
      setState(() => _error = 'Ajoutez au moins deux autres membres');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final roomId = await widget.client.createGroupChat(
        groupName: name,
        enableEncryption: true,
        invite: _members,
        preset: CreateRoomPreset.privateChat,
      );
      final room = widget.client.getRoomById(roomId);
      if (room == null) throw Exception('Groupe introuvable après création');
      if (!mounted) return;
      Navigator.of(context).pop(room);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _memberCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nouveau groupe')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Nom du groupe'),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _memberCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Ajouter un membre',
                      hintText: '@abc123:serveur',
                    ),
                    onSubmitted: (_) => _addMember(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.qr_code_scanner),
                  tooltip: 'Scanner un code',
                  onPressed: () async {
                    final scanned = await Navigator.of(context)
                        .push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
                    if (scanned != null && mounted) {
                      setState(() => _memberCtrl.text = scanned);
                      _addMember();
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle),
                  tooltip: 'Ajouter',
                  onPressed: _addMember,
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: _members.isEmpty
                  ? Center(
                      child: Text(
                        'Aucun membre ajouté pour l\'instant',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  : ListView.builder(
                      itemCount: _members.length,
                      itemBuilder: (context, i) => ListTile(
                        leading: CircleAvatar(
                          backgroundColor: murmureAvatarColor(_members[i]),
                          foregroundColor: Colors.white,
                          child: const Icon(Icons.person, size: 18),
                        ),
                        title: Text(_members[i]),
                        trailing: IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _members.removeAt(i)),
                        ),
                      ),
                    ),
            ),
            FilledButton(
              onPressed: _busy ? null : _create,
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Créer le groupe'),
            ),
          ],
        ),
      ),
    );
  }
}
