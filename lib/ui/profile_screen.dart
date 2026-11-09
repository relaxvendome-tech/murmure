import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../account.dart';
import '../message_notifier.dart';
import '../privacy_settings.dart';
import 'blocked_users_screen.dart';
import 'security_info_screen.dart';

/// Permet de voir et changer son pseudo (nom affiché) à tout moment, sans recréer de compte.
///
/// Jusqu'ici, le pseudo n'était choisi qu'une seule fois, à la création du compte
/// (voir [_CreateAccountScreen] dans onboarding_screen.dart) et ne pouvait plus être modifié
/// nulle part dans l'appli — contrairement à Signal/Telegram, où le nom affiché se change
/// librement depuis les réglages. Ce choix du pseudo n'affaiblit pas l'anonymat de Murmure :
/// c'est un simple libellé que CHAQUE contact voit déjà dans ses conversations (via
/// `getLocalizedDisplayname`), jamais un identifiant servant à vous retrouver — il ne remplace
/// pas, et ne pourra jamais remplacer, l'échange de l'identifiant Matrix (@xxx:serveur) par QR
/// code ou texte : il n'existe aucun annuaire ni recherche par pseudo sur le serveur, ce qui est
/// justement ce qui empêche quiconque de découvrir un compte sans que son propriétaire n'ait
/// explicitement partagé son code.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.client});
  final Client client;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _nameCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _savedMessage;
  bool _notifMessages = true;
  bool _sendReadReceipts = false;
  bool _sendTyping = false;

  @override
  void initState() {
    super.initState();
    MessageNotifier.isEnabled().then((v) {
      if (mounted) setState(() => _notifMessages = v);
    });
    PrivacySettings.sendReadReceipts().then((v) {
      if (mounted) setState(() => _sendReadReceipts = v);
    });
    PrivacySettings.sendTyping().then((v) {
      if (mounted) setState(() => _sendTyping = v);
    });
    _load();
  }

  Future<void> _load() async {
    try {
      // getFromRooms: false — on veut la valeur réellement enregistrée sur le serveur, pas une
      // copie potentiellement périmée vue dans une conversation.
      final profile = await widget.client.fetchOwnProfile(getFromRooms: false);
      if (!mounted) return;
      setState(() {
        _nameCtrl.text = profile.displayName ?? '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Impossible de récupérer le pseudo actuel : $e';
      });
    }
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() {
        _error = 'Le pseudo ne peut pas être vide';
        _savedMessage = null;
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _savedMessage = null;
    });
    try {
      await Account.setDisplayName(widget.client, name);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _savedMessage = 'Pseudo mis à jour';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mon profil')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Ce nom est visible par vos contacts dans vos conversations. Il ne sert à '
                    'personne pour vous retrouver : vos contacts doivent toujours échanger votre '
                    'code (QR ou texte) pour commencer à vous parler.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(labelText: 'Pseudo'),
                    textCapitalization: TextCapitalization.words,
                    onSubmitted: (_) => _save(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  if (_savedMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(_savedMessage!,
                        style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Enregistrer'),
                  ),
                  const SizedBox(height: 20),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.notifications_outlined),
                    title: const Text('Notifications de messages'),
                    subtitle: const Text(
                        'Affiche « Nouveau message » sans jamais montrer le contenu ni '
                        "l'expéditeur. Uniquement tant que l'appli tourne ; aucune en mode discret."),
                    value: _notifMessages,
                    onChanged: (v) {
                      setState(() => _notifMessages = v);
                      MessageNotifier.setEnabled(v);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.done_all),
                    title: const Text('Envoyer les accusés de lecture'),
                    subtitle: const Text(
                        'Si activé : le serveur et votre correspondant voient quand et jusqu\'à '
                        'quel message vous avez lu. Si désactivé : aucun accusé public n\'est '
                        'envoyé (vos non-lus restent remis à zéro localement).'),
                    value: _sendReadReceipts,
                    onChanged: (v) {
                      setState(() => _sendReadReceipts = v);
                      PrivacySettings.setSendReadReceipts(v);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.edit_outlined),
                    title: const Text('Indiquer quand j\'écris'),
                    subtitle: const Text(
                        'Si activé : le serveur et votre correspondant voient en direct que vous '
                        'êtes en train d\'écrire dans la conversation.'),
                    value: _sendTyping,
                    onChanged: (v) {
                      setState(() => _sendTyping = v);
                      PrivacySettings.setSendTyping(v);
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.block),
                    title: const Text('Utilisateurs bloqués'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => BlockedUsersScreen(client: widget.client)),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.shield_outlined),
                    title: const Text('Sécurité et limites'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SecurityInfoScreen()),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
