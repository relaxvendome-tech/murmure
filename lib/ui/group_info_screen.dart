import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../account.dart';
import '../network.dart';
import '../verification/device_verification_status.dart';
import 'device_verification_screen.dart';

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
  bool _loadingKeys = false;
  bool _keysError = false;

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
    await _loadDeviceKeys();
  }

  /// `Client.userDeviceKeys` peut être incomplet avant la sync : on demande explicitement les
  /// clés des membres affichés (`updateUserDeviceKeys(additionalUsers:)`). En cas d'échec on
  /// garde ce qui est déjà connu et on le signale (les boucliers restent gris).
  Future<void> _loadDeviceKeys() async {
    if (!mounted || _loadingKeys) return;
    final ids = _participants.map((u) => u.id).toSet();
    if (ids.isEmpty) return;
    setState(() {
      _loadingKeys = true;
      _keysError = false;
    });
    try {
      await widget.room.client.updateUserDeviceKeys(additionalUsers: ids);
      if (mounted) setState(() => _loadingKeys = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingKeys = false;
          _keysError = true;
        });
      }
    }
  }

  /// La vérification par émojis (SAS) d'un AUTRE utilisateur passe par une conversation directe
  /// (SDK v0.29.0, `DeviceKeysList.startVerification` → `Client.startDirectChat`) : elle est créée
  /// si elle n'existe pas encore. On prévient avant d'ouvrir l'écran ; la comparaison d'empreinte
  /// seule n'ouvre rien.
  Future<void> _openVerification(User u) async {
    if (widget.room.client.getDirectChatFromUserId(u.id) == null) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Vérifier ce membre'),
          content: Text(
            'La vérification par émojis ouvre une conversation directe avec '
            '${u.calcDisplayname()} (elle sera créée et la personne y sera invitée). '
            'La comparaison d\'empreinte, elle, ne crée aucune conversation.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continuer'),
            ),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DeviceVerificationScreen(
        client: widget.room.client,
        userId: u.id,
        displayName: u.calcDisplayname(),
      ),
    ));
    // L'état a pu changer pendant l'écran ouvert.
    if (mounted) setState(() {});
  }

  /// Après `invite`/`kick`, l'état local du salon n'est mis à jour qu'à la sync SUIVANTE :
  /// relire la liste tout de suite afficherait l'ancienne composition. On attend (15 s max) une
  /// sync où l'appartenance de [userId] vaut [expected], puis on recharge la liste.
  Future<void> _reloadAfterMembership(String userId, Membership expected) async {
    bool applied() =>
        widget.room.getState(EventTypes.RoomMember, userId)?.content['membership'] ==
        expected.name;
    if (!applied()) {
      try {
        await widget.room.client.onSync.stream
            .firstWhere((_) => applied())
            .timeout(const Duration(seconds: 15));
      } catch (_) {
        // Délai dépassé ou hors ligne : on recharge quand même ce qui est connu.
      }
    }
    if (mounted) await _loadParticipants();
  }

  Widget _shield(bool? status) {
    if (status == null) {
      return const Icon(Icons.shield_outlined, color: Colors.grey, semanticLabel: 'Aucune clé connue');
    }
    return Icon(
      status ? Icons.verified_user : Icons.gpp_maybe_outlined,
      color: status ? Colors.green : Colors.orange,
      semanticLabel: status ? 'Tous les appareils vérifiés' : 'Appareil non vérifié',
    );
  }

  Widget _summary(String? myId) {
    final scheme = Theme.of(context).colorScheme;
    final others = _participants
        .where((u) => u.id != myId && (u.membership == Membership.join || u.membership == Membership.invite))
        .toList();
    final verified = others
        .where((u) => userVerificationStatus(widget.room.client, u.id) == true)
        .length;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$verified membres sur ${others.length} vérifiés',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (_loadingKeys)
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Les messages restent envoyés à tous les appareils des membres, y compris ceux qui ne '
            'sont pas vérifiés : la vérification n\'affiche que l\'état de confiance, elle ne '
            'bloque personne. Vérifier un membre par émojis ouvre une conversation directe avec '
            'lui.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          if (_keysError) ...[
            const SizedBox(height: 6),
            Text(
              'Impossible de récupérer les clés de certains membres pour l\'instant.',
              style: TextStyle(color: scheme.error, fontSize: 13),
            ),
            TextButton(onPressed: _loadingKeys ? null : _loadDeviceKeys, child: const Text('Réessayer')),
          ],
        ],
      ),
    );
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
      await _reloadAfterMembership(userId, Membership.invite);
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
      // Retrait local immédiat (le serveur a accepté), puis relecture après la sync suivante.
      if (mounted) {
        setState(() => _participants = _participants.where((p) => p.id != user.id).toList());
      }
      await _reloadAfterMembership(user.id, Membership.leave);
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
          _summary(myId),
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
                onTap: u.id == myId ? null : () => _openVerification(u),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (u.id != myId) _shield(userVerificationStatus(room.client, u.id)),
                    if (room.canKick && u.id != myId)
                      IconButton(
                        icon: const Icon(Icons.person_remove_outlined),
                        tooltip: 'Retirer',
                        onPressed: _busyMembers ? null : () => _removeMember(u),
                      ),
                  ],
                ),
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
