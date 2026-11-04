import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../account.dart';
import '../network.dart';

/// Trouvé en audit interne (revue multi-IA croisée, recoupée par Qwen : « une fois le groupe
/// créé, il n'y a aucun moyen de l'administrer »). `NewGroupScreen` (group_screen.dart) crée un
/// salon chiffré via `Client.createGroupChat`, mais rien dans ce dépôt n'exposait ensuite
/// `Room.invite`/`Room.kick`/`Room.setName` — tous déjà présents dans le SDK matrix-dart pinné.
/// Un groupe mal composé (faute de frappe sur un identifiant, oubli d'un membre) restait figé
/// tel que créé, sans recours autre que le quitter et en recréer un.
///
/// Accessible depuis `ChatScreen` (rooms_screen.dart) uniquement pour un salon qui n'est PAS une
/// conversation directe — un groupe au sens Matrix du terme, voir `Room.isDirectChat`.
class GroupInfoScreen extends StatefulWidget {
  const GroupInfoScreen({super.key, required this.room});
  final Room room;

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.room.getLocalizedDisplayname());
  bool _editingName = false;
  bool _busyName = false;
  bool _busyMembers = false;
  String? _error;
  List<User> _participants = [];

  @override
  void initState() {
    super.initState();
    _loadParticipants();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  /// `Room.getParticipants()` (synchrone) peut être incomplet avec le lazy loading des membres
  /// (voir sa documentation dans le SDK pinné) : `requestParticipants()` complète depuis la base
  /// locale, puis le serveur si besoin, avant qu'on affiche la liste — sinon un membre réellement
  /// présent pourrait manquer silencieusement à l'affichage (et donc au choix de qui retirer).
  Future<void> _loadParticipants() async {
    try {
      final users = await widget.room.requestParticipants();
      if (mounted) setState(() => _participants = users);
    } catch (_) {
      if (mounted) setState(() => _participants = widget.room.getParticipants());
    }
  }

  Future<void> _saveName() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Le nom ne peut pas être vide');
      return;
    }
    setState(() {
      _busyName = true;
      _error = null;
    });
    try {
      await widget.room.setName(name);
      if (!mounted) return;
      setState(() {
        _busyName = false;
        _editingName = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busyName = false;
        _error = describeMatrixError('$e');
      });
    }
  }

  Future<void> _addMember() async {
    final ctrl = TextEditingController();
    final id = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ajouter un membre'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Identifiant Matrix',
            hintText: '@nom:serveur',
          ),
          onSubmitted: (_) => Navigator.of(context).pop(ctrl.text.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
            child: const Text('Inviter'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (id == null || id.isEmpty || !mounted) return;
    final userId = parseUserId(id) ?? (id.startsWith('@') ? id : null);
    if (userId == null) {
      setState(() => _error = 'Identifiant invalide (attendu : @nom:serveur)');
      return;
    }
    setState(() {
      _busyMembers = true;
      _error = null;
    });
    try {
      await widget.room.invite(userId);
      await _loadParticipants();
      if (!mounted) return;
      setState(() => _busyMembers = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busyMembers = false;
        _error = describeMatrixError('$e');
      });
    }
  }

  Future<void> _removeMember(User user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Retirer ce membre ?'),
        content: Text('${user.calcDisplayname()} ne pourra plus lire les nouveaux messages.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Retirer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busyMembers = true;
      _error = null;
    });
    try {
      await widget.room.kick(user.id);
      await _loadParticipants();
      if (!mounted) return;
      setState(() => _busyMembers = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busyMembers = false;
        _error = describeMatrixError('$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final myId = room.client.userID;
    return Scaffold(
      appBar: AppBar(title: const Text('Infos du groupe')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: _editingName
                    ? TextField(
                        controller: _nameCtrl,
                        autofocus: true,
                        decoration: const InputDecoration(labelText: 'Nom du groupe'),
                        onSubmitted: (_) => _saveName(),
                      )
                    : Text(
                        room.getLocalizedDisplayname(),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
              ),
              if (room.canChangeStateEvent(EventTypes.RoomName))
                _busyName
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : IconButton(
                        icon: Icon(_editingName ? Icons.check : Icons.edit),
                        tooltip: _editingName ? 'Enregistrer' : 'Renommer',
                        onPressed: _editingName
                            ? _saveName
                            : () => setState(() => _editingName = true),
                      ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Membres (${_participants.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          ..._participants.map((u) => ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: Text(u.calcDisplayname()),
                subtitle: u.membership == Membership.invite ? const Text('Invitation en attente') : null,
                trailing: (room.canKick && u.id != myId)
                    ? IconButton(
                        icon: const Icon(Icons.person_remove_outlined),
                        tooltip: 'Retirer',
                        onPressed: _busyMembers ? null : () => _removeMember(u),
                      )
                    : null,
              )),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 16),
          if (room.canInvite)
            OutlinedButton.icon(
              onPressed: _busyMembers ? null : _addMember,
              icon: const Icon(Icons.person_add_outlined),
              label: const Text('Ajouter un membre'),
            ),
        ],
      ),
    );
  }
}
