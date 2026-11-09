import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import '../account.dart';
import '../config.dart';
import '../network.dart';
import 'qr_screens.dart';
import 'security_info_screen.dart';

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

  /// Vrai quand l'utilisateur, depuis l'écran de création de compte, a demandé à revenir à la
  /// configuration du serveur (jeton d'inscription faux ou absent, mauvaise adresse…). Sans ce
  /// retour, une configuration enregistrée mais inutilisable était une impasse : seule la
  /// réinstallation de l'appli permettait d'en sortir.
  bool _editingServer = false;

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

  /// Le client Matrix est construit une seule fois, au démarrage de l'appli (voir main.dart),
  /// AVANT que l'onboarding ne connaisse le mode réseau choisi ici. On met donc à jour son
  /// `httpClient` (propriété mutable du SDK) dès qu'un réglage est validé, pour que l'inscription
  /// qui suit immédiatement passe réellement par Tor ou le proxy choisi, sans attendre un
  /// redémarrage de l'appli.
  Future<void> _applyConfig(NetConfig c) async {
    // Même enveloppe que celle posée par le constructeur de `Client` (matrix-dart-sdk :
    // `FixedTimeoutHttpClient(httpClient ?? http.Client(), Duration(seconds: 35))`) : sans elle,
    // une connexion Tor/proxy bloquée ne serait jamais interrompue. L'ancien client interne est
    // fermé pour ne pas laisser de sockets (éventuellement directs) ouverts.
    final previous = widget.client.httpClient;
    widget.client.httpClient = FixedTimeoutHttpClient(await c.httpClient(), kHttpTimeout);
    _closeHttpClient(previous);
    if (!mounted) return;
    setState(() {
      _config = c;
      _editingServer = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final configured = _config != null && _config!.isConfigured;
    if (!configured || _editingServer) {
      return _ServerSetupScreen(
        // `ValueKey` : un nouvel état (donc des contrôleurs relus depuis `initial`) à chaque
        // retour sur cet écran, jamais l'état périmé d'un affichage précédent.
        key: ValueKey(_config),
        initial: _config,
        onConfigured: _applyConfig,
        onCancel: configured ? () => setState(() => _editingServer = false) : null,
      );
    }
    return _CreateAccountScreen(
      client: widget.client,
      config: _config!,
      onChangeServer: () => setState(() => _editingServer = true),
    );
  }
}

class _ServerSetupScreen extends StatefulWidget {
  const _ServerSetupScreen({super.key, required this.initial, required this.onConfigured, this.onCancel});
  final NetConfig? initial;
  final Future<void> Function(NetConfig) onConfigured;

  /// Non nul quand une configuration valide existe déjà (retour depuis la création de compte) :
  /// permet de revenir sans rien changer.
  final VoidCallback? onCancel;

  @override
  State<_ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<_ServerSetupScreen> {
  final _urlCtrl = TextEditingController(text: 'https://');
  final _tokenCtrl = TextEditingController();
  final _proxyHostCtrl = TextEditingController();
  final _proxyPortCtrl = TextEditingController(text: '1080');
  NetMode _mode = NetMode.direct;
  bool _testing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Pré-remplit le formulaire avec la configuration déjà enregistrée (retour via « Changer de
    // serveur ») : l'utilisateur corrige seulement le champ fautif, typiquement le jeton.
    final c = widget.initial;
    if (c != null && c.isConfigured) {
      _urlCtrl.text = c.homeserver.toString();
      _tokenCtrl.text = c.registrationToken;
      _mode = c.mode;
      _proxyHostCtrl.text = c.proxyHost ?? '';
      if (c.proxyPort != null) _proxyPortCtrl.text = c.proxyPort.toString();
    }
  }

  /// Trouvé en audit interne (revue multi-IA croisée — ChatGPT, Qwen et Perplexity ont chacune
  /// signalé, indépendamment, que taper à la main une URL de serveur et un jeton d'inscription
  /// bloque un testeur dès le premier écran) : scanne un code généré par qui gère un serveur
  /// Murmure (via [MyServerQrScreen] plus bas, pensé pour ça) pour remplir ce formulaire
  /// automatiquement, plutôt que de recopier lettre par lettre une adresse et un jeton.
  ///
  /// DÉLIBÉRÉMENT PAS DE SERVEUR PAR DÉFAUT CODÉ EN DUR dans l'appli elle-même : c'est un principe
  /// déjà affirmé par ce fichier (voir le commentaire de tête de `OnboardingScreen`) et par
  /// `network.dart` — Murmure n'est lié à aucun serveur central unique, chacun peut héberger le
  /// sien (`scripts/server/`), et figer une adresse dans l'APK créerait exactement le point
  /// unique de surveillance/blocage que l'architecture décentralisée cherche à éviter. Ce scan
  /// résout la friction de saisie sans revenir sur ce choix : il faut toujours qu'un serveur ait
  /// été choisi et qu'un code en soit sorti, par qui que ce soit, avant ce scan.
  Future<void> _scanServerQr() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (raw == null || !mounted) return;
    const prefix = 'murmure-server:';
    if (!raw.startsWith(prefix)) {
      setState(() => _error = 'Code non reconnu (pas un code de serveur Murmure)');
      return;
    }
    final uri = Uri.tryParse(raw.substring(prefix.length));
    if (uri == null || uri.host.isEmpty) {
      setState(() => _error = 'Code de serveur invalide');
      return;
    }
    setState(() {
      _urlCtrl.text = Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null)
          .toString();
      _tokenCtrl.text = uri.queryParameters['token'] ?? '';
      _error = null;
    });
  }

  Future<void> _save() async {
    final uri = Uri.tryParse(_urlCtrl.text.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      setState(() => _error = 'Adresse de serveur invalide');
      return;
    }
    // Trouvé en audit interne : seuls `hasScheme`/`host.isNotEmpty` étaient vérifiés — un
    // "http://..." passait la validation aussi bien qu'un "https://...". En mode direct ou proxy
    // SOCKS5 personnalisé, ça aurait fait transiter en clair jeton d'accès, identifiants d'appareil
    // et métadonnées Matrix (le chiffrement de bout en bout des messages ne protège pas ces
    // champs-là) face à quiconque observe le réseau — exactement le scénario que ce champ
    // préremplit par défaut sur "https://" sans l'imposer. Exception pour les adresses .onion : un
    // service oignon Tor s'authentifie par son adresse elle-même et Tor chiffre déjà le trajet de
    // bout en bout jusqu'à lui, y compris en mode "direct" (qui route alors vers Tor via le proxy
    // SOCKS système) — c'est l'usage normal (cf. Tor Browser, qui n'exige pas non plus HTTPS pour
    // les .onion).
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
      registrationToken: _tokenCtrl.text.trim(),
      mode: _mode,
      proxyHost: _mode == NetMode.customProxy ? _proxyHostCtrl.text.trim() : null,
      proxyPort: _mode == NetMode.customProxy ? int.tryParse(_proxyPortCtrl.text.trim()) : null,
    );

    // On teste TOUJOURS avec le client réellement associé au mode choisi (jamais un client direct
    // générique) : un faux positif ici ferait croire à l'utilisateur qu'il passe par Tor/un proxy
    // alors que le test, lui, serait parti en clair.
    if (await _tryMode(base)) return;

    // Repli automatique sur Tor UNIQUEMENT si l'utilisateur avait choisi « Direct » et que ça a
    // échoué (réseau censuré ou coupé) — jamais de repli silencieux depuis Tor ou un proxy choisi
    // explicitement vers du direct, ce qui serait le pire des deux issues pour cet usage.
    if (_mode == NetMode.direct) {
      if (await _tryMode(base.copyWith(mode: NetMode.tor))) return;
    }

    if (!mounted) return;
    setState(() {
      _testing = false;
      _error ??= 'Serveur injoignable. Vérifiez l\'adresse, ou essayez via Tor.';
    });
  }

  /// Teste [cfg] avec SON propre client (direct, Tor ou proxy) et, si l'appel réussit,
  /// enregistre et propage la configuration. Retourne faux sans rien enregistrer sinon.
  Future<bool> _tryMode(NetConfig cfg) async {
    http.Client client;
    try {
      client = await cfg.httpClient();
    } on ProxyConfigError catch (e) {
      if (mounted) setState(() => _error = e.message);
      return false;
    }
    final ok = await canReach(cfg.homeserver, client: client);
    client.close();
    if (!ok) return false;
    await cfg.save();
    if (!mounted) return true;
    await widget.onConfigured(cfg);
    return true;
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Adresse du serveur', hintText: 'https://…'),
                    keyboardType: TextInputType.url,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.qr_code_scanner),
                  tooltip: 'Scanner le code d\'un serveur',
                  onPressed: _scanServerQr,
                ),
              ],
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
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _testing ? null : _save,
              child: _testing
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Continuer'),
            ),
            if (widget.onCancel != null) ...[
              const SizedBox(height: 4),
              TextButton(
                onPressed: _testing ? null : widget.onCancel,
                child: const Text('Annuler'),
              ),
            ],
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

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    _proxyHostCtrl.dispose();
    _proxyPortCtrl.dispose();
    super.dispose();
  }
}

class _CreateAccountScreen extends StatefulWidget {
  const _CreateAccountScreen({required this.client, required this.config, required this.onChangeServer});
  final Client client;
  final NetConfig config;

  /// Revient à l'écran serveur pré-rempli (jeton faux/absent, mauvaise adresse).
  final VoidCallback onChangeServer;

  @override
  State<_CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<_CreateAccountScreen> {
  final _nameCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  // Trouvé en audit interne (revue croisée IA + vérification du reste du fichier contre le même
  // défaut) : seul _ServerSetupScreenState, l'autre écran de ce fichier, libérait ses contrôleurs
  // ; celui-ci ne le faisait pas.
  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

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
    // Navigator capturé AVANT l'await : ce widget est remplacé par RoomsScreen dès l'inscription.
    final nav = Navigator.of(context);
    try {
      await Account.register(widget.client, name);
      // Affiche UNE fois « Sécurité et limites » juste après la création du compte.
      nav.push(MaterialPageRoute(builder: (_) => const SecurityInfoScreen()));
      // Trouvé en audit interne : ce commentaire affirmait que MurmureApp (`_Home` dans
      // main.dart) réagissait seul à ce changement — c'était faux, rien ne l'abonnait à
      // `client.onLoginStateChanged` avant la correction de ce bug dans main.dart. C'est
      // maintenant réellement le cas (StreamBuilder sur `client.onLoginStateChanged.stream`) :
      // rien d'autre à faire ici, `_Home` recevra l'événement émis par `Account.register()`
      // (via `client.init()` -> `onLoginStateChanged.add(LoginState.loggedIn)`) et basculera sur
      // RoomsScreen de lui-même, sans navigation explicite nécessaire depuis cet écran.
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _describeRegistrationError(e, widget.config);
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
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _busy ? null : widget.onChangeServer,
              icon: const Icon(Icons.dns_outlined),
              label: const Text('Changer de serveur'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Message d'échec d'inscription compréhensible, sans jamais afficher de pile ou d'objet brut.
String _describeRegistrationError(Object e, NetConfig config) {
  if (e is MatrixException) {
    switch (e.error) {
      case MatrixError.M_FORBIDDEN:
      case MatrixError.M_UNAUTHORIZED:
        return config.registrationToken.isEmpty
            ? 'Ce serveur exige un jeton d\'inscription. Touchez « Changer de serveur » pour le '
                'saisir (ou scanner le code du serveur).'
            : 'Jeton d\'inscription refusé (invalide, expiré ou déjà épuisé). Touchez « Changer de '
                'serveur » pour le corriger.';
      case MatrixError.M_USER_IN_USE:
        return 'Cet identifiant est déjà pris sur ce serveur. Réessayez : un nouvel identifiant '
            'sera tiré au hasard.';
      case MatrixError.M_INVALID_USERNAME:
        return 'Identifiant refusé par le serveur. Réessayez.';
      case MatrixError.M_LIMIT_EXCEEDED:
        return 'Trop de tentatives. Patientez quelques minutes avant de réessayer.';
      default:
        return describeMatrixError(e.errorMessage);
    }
  }
  return 'Inscription impossible : serveur injoignable ou réponse inattendue. Vérifiez la '
      'connexion, ou touchez « Changer de serveur ».';
}

/// Ferme le client HTTP interne remplacé (la classe d'enveloppe du SDK, [TimeoutHttpClient],
/// n'implémente pas `close()` elle-même : c'est son `inner` qui détient les sockets).
void _closeHttpClient(http.Client old) {
  try {
    if (old is TimeoutHttpClient) {
      old.inner.close();
    } else {
      old.close();
    }
  } catch (_) {
    // Best-effort : un client déjà fermé ne doit pas bloquer le changement de configuration.
  }
}
