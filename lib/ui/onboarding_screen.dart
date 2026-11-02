import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../account.dart';
import '../network.dart';

/// Premier lancement : configurer le serveur (jamais codé en dur, voir network.dart), puis créer
/// un compte anonyme (identifiant et mot de passe aléatoires, seul le nom affiché est choisi).
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.client});
  final Client client;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  NetConfig? _config;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    NetConfig.load().then((c) {
      if (!mounted) return;
      setState(() {
        _config = c;
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_config == null || !_config!.isConfigured) {
      return _ServerSetupScreen(
        initial: _config,
        onConfigured: (c) => setState(() => _config = c),
      );
    }
    return _CreateAccountScreen(client: widget.client, config: _config!);
  }
}

class _ServerSetupScreen extends StatefulWidget {
  const _ServerSetupScreen({required this.initial, required this.onConfigured});
  final NetConfig? initial;
  final void Function(NetConfig) onConfigured;

  @override
  State<_ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<_ServerSetupScreen> {
  final _urlCtrl = TextEditingController(text: 'https://');
  final _tokenCtrl = TextEditingController();
  NetMode _mode = NetMode.direct;
  bool _testing = false;
  String? _error;

  Future<void> _save() async {
    final uri = Uri.tryParse(_urlCtrl.text.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      setState(() => _error = 'Adresse de serveur invalide');
      return;
    }
    setState(() {
      _testing = true;
      _error = null;
    });
    final cfg = NetConfig(homeserver: uri, registrationToken: _tokenCtrl.text.trim(), mode: _mode);
    var ok = await canReach(uri);
    if (!ok && _mode == NetMode.direct) {
      // Bascule automatique sur Tor si le direct échoue (réseau censuré ou coupé).
      final torCfg = cfg.copyWith(mode: NetMode.tor);
      if (await canReach(uri)) {
        ok = true;
      }
      if (ok) {
        await torCfg.save();
        if (!mounted) return;
        widget.onConfigured(torCfg);
        return;
      }
    }
    if (!ok) {
      setState(() {
        _testing = false;
        _error = 'Serveur injoignable. Vérifiez l\'adresse, ou essayez via Tor.';
      });
      return;
    }
    await cfg.save();
    if (!mounted) return;
    widget.onConfigured(cfg);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connexion au serveur')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: ListView(
          children: [
            const Text(
              'Entrez l\'adresse du serveur Murmure (Conduit/Matrix). Ce réglage reste modifiable '
              'depuis l\'appli à tout moment, y compris sans connexion.',
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(labelText: 'Adresse du serveur', hintText: 'https://…'),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenCtrl,
              decoration: const InputDecoration(labelText: 'Jeton d\'inscription (si demandé)'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<NetMode>(
              value: _mode,
              decoration: const InputDecoration(labelText: 'Mode de connexion'),
              items: const [
                DropdownMenuItem(value: NetMode.direct, child: Text('Direct')),
                DropdownMenuItem(value: NetMode.tor, child: Text('Tor (via Orbot)')),
                DropdownMenuItem(value: NetMode.customProxy, child: Text('Proxy SOCKS5 personnalisé')),
              ],
              onChanged: (m) => setState(() => _mode = m ?? NetMode.direct),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _testing ? null : _save,
              child: _testing ? const CircularProgressIndicator() : const Text('Continuer'),
            ),
            const SizedBox(height: 8),
            Text(
              'Pas de réseau pour l\'instant ? Le mode Bluetooth hors-ligne reste disponible depuis '
              'les réglages une fois l\'appli ouverte.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateAccountScreen extends StatefulWidget {
  const _CreateAccountScreen({required this.client, required this.config});
  final Client client;
  final NetConfig config;

  @override
  State<_CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<_CreateAccountScreen> {
  final _nameCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Choisissez un nom affiché');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Account.register(widget.client, name);
      // Rien d'autre à faire : MurmureApp réagit à client.isLogged() et affiche RoomsScreen.
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeMatrixError('$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nouveau compte')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'Aucun numéro de téléphone, aucun e-mail. Choisissez simplement un nom — '
              'votre identifiant sera généré au hasard.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Nom affiché'),
              textCapitalization: TextCapitalization.words,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _create,
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Créer mon compte'),
            ),
          ],
        ),
      ),
    );
  }
}
