import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

/// Liste des utilisateurs bloqués (« ignorés » au sens Matrix : `m.ignored_user_list`).
///
/// API SDK utilisées : `Client.ignoredUsers`, `Client.unignoreUser`, `Client.onSync`.
/// Aucun contenu de message n'est journalisé ici.
class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key, required this.client});
  final Client client;

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  final Set<String> _busy = {};

  Future<void> _unblock(String userId) async {
    setState(() => _busy.add(userId));
    try {
      await widget.client.unignoreUser(userId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Utilisateur débloqué')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Impossible de débloquer cet utilisateur. Vérifiez votre connexion réseau et réessayez.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(userId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Utilisateurs bloqués')),
      body: StreamBuilder<SyncUpdate>(
        stream: widget.client.onSync.stream,
        builder: (context, _) {
          final blocked = widget.client.ignoredUsers;
          if (blocked.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Aucun utilisateur bloqué', textAlign: TextAlign.center),
              ),
            );
          }
          return ListView.separated(
            itemCount: blocked.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final id = blocked[i];
              final busy = _busy.contains(id);
              return ListTile(
                leading: const Icon(Icons.block),
                title: Text(id, overflow: TextOverflow.ellipsis),
                trailing: busy
                    ? const SizedBox(
                        width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : TextButton(
                        onPressed: () => _unblock(id),
                        child: const Text('Débloquer'),
                      ),
              );
            },
          );
        },
      ),
    );
  }
}
