import 'package:flutter/material.dart';

import '../crash_log.dart';

/// Écran « Diagnostics » : affiche le journal LOCAL de plantages/erreurs tenu par
/// [CrashLogStore] — voir sa documentation de classe pour la garantie centrale : rien de ce qui
/// est affiché ici n'est jamais envoyé où que ce soit, seulement consultable sur ce téléphone.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  List<CrashEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await CrashLogStore.list();
    if (mounted) setState(() => _entries = entries);
  }

  Future<void> _clear() async {
    await CrashLogStore.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          if (entries != null && entries.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Vider le journal',
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Vider le journal ?'),
                    content: const Text(
                        'Efface définitivement les entrées listées ci-dessous, sur ce '
                        'téléphone uniquement.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          child: const Text('Annuler')),
                      TextButton(
                          onPressed: () => Navigator.of(ctx).pop(true),
                          child: const Text('Vider')),
                    ],
                  ),
                );
                if (confirmed == true) await _clear();
              },
            ),
        ],
      ),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'Ce journal reste uniquement sur ce téléphone : rien n\'est jamais envoyé à '
                    'qui que ce soit, ni à Murmure, ni à un service tiers. Il ne contient que le '
                    'type et l\'emplacement d\'une erreur, jamais le contenu d\'un message. Il est '
                    'effacé automatiquement par l\'effacement de panique ou la suppression du '
                    'compte, comme le reste des données locales.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: entries.isEmpty
                      ? const Center(child: Text('Aucune erreur enregistrée.'))
                      : ListView.separated(
                          itemCount: entries.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final e = entries[i];
                            return ExpansionTile(
                              title: Text(e.errorType),
                              subtitle: Text('${e.source} · ${_formatTs(e.ts)}'),
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: SelectableText(
                                      e.stack,
                                      style: const TextStyle(
                                          fontFamily: 'monospace', fontSize: 11),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }

  String _formatTs(DateTime ts) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(ts.day)}/${two(ts.month)}/${ts.year} ${two(ts.hour)}:${two(ts.minute)}';
  }
}
