import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import '../network.dart';
import 'qr_screens.dart';

/// Trouvé en audit interne : une fois le compte créé, `OnboardingScreen` (et donc le seul
/// formulaire de choix du mode réseau — direct/Tor/proxy personnalisé) n'était plus jamais
/// atteignable (`_Home` dans main.dart n'affiche cet écran que tant que
/// `client.onLoginStateChanged` vaut autre chose que `loggedIn`). Le texte même de l'écran de
/// configuration initiale affirme pourtant « Ce réglage reste modifiable depuis l'appli à tout
/// moment, y compris sans connexion » — faux en pratique : `LockSettingsScreen` (l'unique écran
/// de réglages accessible depuis RoomsScreen) n'exposait ni le serveur, ni le mode de connexion,
/// ni le proxy. Quelqu'un ayant commencé en mode direct (Orbot pas encore installé, ou pas lancé
/// au moment de l'onboarding) n'avait ensuite plus aucun moyen de basculer vers Tor sans supprimer
/// son compte et tout recommencer — exactement le scénario que la fonctionnalité Tor existe pour
/// couvrir.
///
/// Reprend volontairement le même comportement que `_ServerSetupScreen` (onboarding_screen.dart) :
/// teste TOUJOURS avec le client réellement associé au mode choisi, échoue plutôt que de retomber
/// sur une connexion directe (« fail closed »), et ne journalise/n'applique rien tant que le test
/// de portée n'a pas réussi. Seule différence : au lieu d'enchaîner vers la création de compte, on
/// applique immédiatement `client.httpClient` (déjà connecté) et on revient en arrière — même
/// mécanisme que `_OnboardingScreenState._applyConfig`.
class NetworkSettingsScreen extends StatefulWidget {
  const NetworkSettingsScreen({super.key, required this.client});
  final Client client;

  @override
  State<NetworkSettingsScreen> createState() => _NetworkSettingsScreenState();
}

class _NetworkSettingsScreenState extends State<NetworkSettingsScreen> {
  final _urlCtrl = TextEditingController();
  final _proxyHostCtrl = TextEditingController();
  final _proxyPortCtrl = TextEditingController(text: '1080');
  NetMode _mode = NetMode.direct;
  NetConfig? _current;
  bool _loading = true;
  bool _testing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    NetConfig.load().then((c) {
      if (!mounted) return;
      setState(() {
        _current = c;
        _urlCtrl.text = c.homeserver.hasScheme ? c.homeserver.toString() : 'https://';
        _mode = c.mode;
        _proxyHostCtrl.text = c.proxyHost ?? '';
        if (c.proxyPort != null) _proxyPortCtrl.text = c.proxyPort.toString();
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _proxyHostCtrl.dispose();
    _proxyPortCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final uri = Uri.tryParse(_urlCtrl.text.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      setState(() => _error = 'Adresse de serveur invalide');
      return;
    }
    // Même règle qu'à l'onboarding (voir onboarding_screen.dart) : jamais de http:// en clair
    // en dehors d'un service oignon, qui s'authentifie par son adresse et est déjà chiffré par Tor
    // de bout en bout jusqu'à lui.
    if (uri.scheme != 'https' && !uri.host.endsWith('.onion')) {
      setState(() => _error = 'Seules les adresses https:// (ou .onion) sont acceptées');
      return;
    }
    if (_mode == NetMode.customProxy && _proxyHostCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Adresse du proxy SOCKS5 requise');
      return;
    }
    setState(() {
      _testing = true;
      _error = null;
    });

    final base = NetConfig(
      homeserver: uri,
      // Le jeton d'inscription ne sert qu'à `Account.register()`, déjà effectué pour arriver sur
      // cet écran (accessible uniquement depuis RoomsScreen, donc après connexion) : on le
      // préserve tel quel sans jamais le redemander ici.
      registrationToken: _current?.registrationToken ?? '',
      mode: _mode,
      proxyHost: _mode == NetMode.customProxy ? _proxyHostCtrl.text.trim() : null,
      proxyPort: _mode == NetMode.customProxy ? int.tryParse(_proxyPortCtrl.text.trim()) : null,
      updateManifestUrl: _current?.updateManifestUrl,
    );

    if (await _tryMode(base)) return;

    // Même repli automatique que l'onboarding : uniquement direct -> Tor, jamais l'inverse ni
    // depuis un proxy choisi explicitement (voir le commentaire de _ServerSetupScreenState._save
    // dans onboarding_screen.dart).
    if (_mode == NetMode.direct) {
      if (await _tryMode(base.copyWith(mode: NetMode.tor))) return;
    }

    if (!mounted) return;
    setState(() {
      _testing = false;
      _error ??= 'Serveur injoignable. Vérifiez l\'adresse, ou essayez via Tor.';
    });
  }

  Future<bool> _tryMode(NetConfig cfg) async {
    http.Client testClient;
    try {
      testClient = await cfg.httpClient();
    } on ProxyConfigError catch (e) {
      if (mounted) setState(() => _error = e.message);
      return false;
    }
    // Comme dans `_ServerSetupScreenState._tryMode` (onboarding_screen.dart) : ce client ne sert
    // qu'au test de portée, toujours refermé ensuite — jamais réutilisé tel quel pour le trafic
    // réel, par symétrie avec le client que `_OnboardingScreenState._applyConfig` recrée à neuf.
    final ok = await canReach(cfg.homeserver, client: testClient);
    testClient.close();
    if (!ok) return false;
    await cfg.save();
    // Applique le nouveau client HTTP au client Matrix déjà connecté, exactement comme
    // `_OnboardingScreenState._applyConfig` — sans ça, ce réglage serait enregistré mais sans
    // aucun effet jusqu'au prochain démarrage de l'appli.
    widget.client.httpClient = await cfg.httpClient();
    // Trouvé en audit interne (vérifié contre le SDK matrix-dart pinné, tag v0.29.13,
    // `matrix_api_lite/matrix_api.dart`) : `Client.homeserver` est un simple alias de `baseUri`,
    // l'URL de base que le SDK utilise pour construire CHAQUE requête (sync, envoi, médias) — pas
    // seulement le transport (`httpClient`, déjà réappliqué ci-dessus). Cette ligne manquait ici :
    // pour un compte déjà créé (seul cas qui passe par cet écran — l'onboarding, lui, laisse
    // `Account.register()` → `client.checkHomeserver()` le fixer au moment de l'inscription),
    // changer l'ADRESSE du serveur (pas seulement le mode direct/Tor/proxy) semblait réussir — le
    // test de portée ci-dessus passait, le réglage était enregistré, le message de confirmation
    // s'affichait — mais ne changeait rien au trafic réel : chaque requête continuait de partir
    // vers l'ancienne adresse (`baseUri` jamais mis à jour), restaurée identique au prochain
    // démarrage puisque `Client.init()` la relit depuis la session déjà stockée, jamais depuis
    // `NetConfig`. Concrètement inopérant pour le scénario même documenté en tête de ce fichier :
    // basculer vers une autre adresse du même serveur (ex. miroir .onion) une fois le compte créé.
    // Assignation directe plutôt que `client.checkHomeserver(cfg.homeserver)` : cette dernière
    // remet `homeserver` à `null` dans son propre `catch` en cas d'échec (vérifié dans le SDK
    // réel) — inutile et dangereux ici, puisque [canReach] vient déjà de confirmer la portée de
    // cette adresse avec le bon client, et qu'on ne veut surtout pas casser un client déjà connecté
    // et fonctionnel sur un échec tardif (version/flux de connexion) sans rapport avec la portée
    // déjà vérifiée.
    widget.client.homeserver = cfg.homeserver;
    if (!mounted) return true;
    setState(() => _testing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Réglages réseau mis à jour.')),
    );
    Navigator.of(context).pop();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final current = _current;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Réseau'),
        actions: [
          if (current != null && current.homeserver.hasScheme)
            IconButton(
              icon: const Icon(Icons.qr_code),
              tooltip: 'Partager ce serveur (QR)',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => MyServerQrScreen(
                  homeserver: current.homeserver,
                  registrationToken: current.registrationToken,
                ),
              )),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: ListView(
          children: [
            const Text(
              'Changer le serveur ou le mode de connexion ne touche pas votre compte : seule la '
              'façon dont l\'appli l\'atteint change.',
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(labelText: 'Adresse du serveur', hintText: 'https://…'),
              keyboardType: TextInputType.url,
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
            if (_mode == NetMode.customProxy) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _proxyHostCtrl,
                decoration: const InputDecoration(
                  labelText: 'Adresse du proxy SOCKS5',
                  hintText: 'ex. 10.0.0.5 ou proxy.example',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _proxyPortCtrl,
                decoration: const InputDecoration(labelText: 'Port'),
                keyboardType: TextInputType.number,
              ),
            ],
            if (_mode == NetMode.tor) ...[
              const SizedBox(height: 12),
              Text(
                'Orbot doit être installé et lancé (proxy SOCKS5 sur 127.0.0.1:9050).',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _testing ? null : _save,
              child: _testing
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }
}
