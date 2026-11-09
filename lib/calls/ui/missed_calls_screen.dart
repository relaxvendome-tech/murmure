import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../services/call_opsec_store.dart';

/// Écran d'historique des appels manqués : consomme ce que `CallSessionScreen` a archivé dans
/// `CallOpsecStore` (base SQLCipher dédiée, voir `lib/calls/services/call_opsec_store.dart`).
/// Comme tout l'intérieur de l'appli, cet écran n'est atteignable qu'après déverrouillage
/// (PIN ou calculatrice, voir `ui/lock_screens.dart`) — rien de spécifique à faire ici pour ça.
///
/// Remplace une proposition reçue dans cette conversation qui visait une classe `SecureStorage`
/// (`lib/infrastructure/secure_storage.dart`) et des champs (`sender_id`) qui n'existent pas dans
/// ce dépôt : l'historique réel vit dans [CallOpsecStore] (`list()`/`clear()`, champs
/// `remoteUserId`/`roomId`/`timestamp`), déjà construit dans un commit précédent — utilisé ici
/// directement plutôt que réinventé sous un autre nom.
class MissedCallsScreen extends StatefulWidget {
  const MissedCallsScreen({super.key, required this.client});
  final Client client;

  @override
  State<MissedCallsScreen> createState() => _MissedCallsScreenState();
}

class _MissedCallsScreenState extends State<MissedCallsScreen> {
  late Future<List<MissedCall>> _future;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() => _future = CallOpsecStore.list());
  }

  Future<void> _clear() async {
    // Trouvé en audit interne (revue croisée IA) : `_refresh()` (donc `setState`) était appelé
    // après cet `await` sans revérifier `mounted` — risque de "setState() called after dispose()"
    // si l'écran disparaît (ex. relock automatique) pendant la purge.
    await CallOpsecStore.clear();
    if (!mounted) return;
    _refresh();
  }

  /// Affiche le nom de la conversation quand la salle existe encore localement, sinon
  /// l'identifiant Matrix brut du correspondant (cohérent avec le reste de l'appli, voir
  /// `AddContactScreen`, qui affiche aussi des identifiants bruts).
  String _label(MissedCall call) {
    final room = widget.client.getRoomById(call.roomId);
    if (room != null) return room.getLocalizedDisplayname();
    return call.remoteUserId ?? 'Correspondant inconnu';
  }

  String _formatTimestamp(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    final h = date.hour.toString().padLeft(2, '0');
    final min = date.minute.toString().padLeft(2, '0');
    return '$d/$m à $h:$min';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Appels manqués'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Purger l\'historique',
            onPressed: () => _confirmClear(context),
          ),
        ],
      ),
      body: FutureBuilder<List<MissedCall>>(
        future: _future,
        builder: (context, snapshot) {
          // Sans ce test, une erreur d'ouverture de la base (clé absente, fichier corrompu…)
          // laissait un spinner infini. Aucun détail de l'erreur n'est affiché ni journalisé.
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      "Impossible de charger l'historique des appels manqués.",
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    TextButton(onPressed: _refresh, child: const Text('Réessayer')),
                  ],
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final calls = snapshot.data!;
          if (calls.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.phone_missed_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    Text('Aucun appel manqué', style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: calls.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final call = calls[i];
              return ListTile(
                leading: Icon(Icons.phone_missed, color: Theme.of(context).colorScheme.error),
                title: Text(_label(call), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(_formatTimestamp(call.timestamp)),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Purger l\'historique ?'),
        content: const Text(
          'Cette action efface définitivement les appels manqués enregistrés localement.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Purger')),
        ],
      ),
    );
    if (confirmed == true) await _clear();
  }
}
