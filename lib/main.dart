import 'package:flutter/material.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/matrix.dart';

import 'account.dart';
import 'calls/services/call_manager.dart';
import 'calls/services/call_opsec_notifier.dart';
import 'calls/ui/call_session_screen.dart';
import 'media.dart';
import 'network.dart';
import 'ui/lock_screens.dart';
import 'ui/onboarding_screen.dart';
import 'ui/rooms_screen.dart';
import 'ui/theme.dart';
import 'verification/verification_manager.dart';

/// Permet à [MurmureWebRTCDelegate] (construit avant tout arbre de widgets, voir
/// `lib/calls/services/call_manager.dart`) de naviguer vers l'écran d'appel à la réception d'un
/// appel, sans avoir à transporter un `BuildContext` jusque-là.
final GlobalKey<NavigatorState> murmureNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Trouvé en audit interne, et sérieux : `flutter_vodozemac` est bien déclaré dans pubspec.yaml
  // et cité dans plusieurs commentaires de ce dépôt comme le moteur Olm/Megolm réellement utilisé,
  // mais rien n'appelait jamais son `init()` — qui charge la bibliothèque native (Rust via
  // flutter_rust_bridge) sur laquelle reposent TOUTES les opérations de chiffrement du SDK Matrix,
  // y compris la création même du compte et la connexion. Vérifié contre l'implémentation de
  // référence du même éditeur (Famedly) que matrix-dart-sdk, FluffyChat, dont `main()` appelle
  // explicitement `vod.init(...)` avant tout usage du SDK — jamais en interne par le SDK lui-même.
  // Sans cet appel, soit `Client(...).init()` plus bas lève une exception (l'écran d'erreur de
  // démarrage s'affiche, au moins visible), soit — plus grave, non exclu sans test sur appareil
  // réel — une tentative plus tardive d'opération cryptographique échoue silencieusement ailleurs
  // dans l'appli. `wasmPath` (utilisé par FluffyChat) ne s'applique qu'aux builds web ; Murmure est
  // Android uniquement, donc aucun argument n'est nécessaire ici (la bibliothèque native est
  // chargée depuis l'emplacement par défaut du plugin).
  await vod.init();
  await purgeMediaCache(); // nettoie les restes d'une lecture de média interrompue
  await CallOpsecNotifier.init(); // best-effort, voir le commentaire de cette méthode
  runApp(const MurmureApp());
}

/// Racine de l'appli : construit le client Matrix (avec sa base SQLCipher locale), puis affiche
/// soit l'onboarding (pas encore de compte), soit la messagerie, derrière le verrou PIN/calculatrice.
class MurmureApp extends StatefulWidget {
  const MurmureApp({super.key});

  @override
  State<MurmureApp> createState() => _MurmureAppState();
}

class _MurmureAppState extends State<MurmureApp> {
  Client? _client;
  CallManager? _callManager;
  VerificationManager? _verificationManager;
  bool _booting = true;
  String? _bootError;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final db = await Account.openDatabase();
      // Le client Matrix DOIT recevoir le client HTTP adapté au mode réseau choisi (direct, Tor,
      // proxy SOCKS5 personnalisé) dès sa construction : avant cette correction, ce paramètre
      // n'était jamais renseigné, et le SDK utilisait son client HTTP interne par défaut, qui
      // part toujours en direct — autrement dit, choisir « Tor » dans les réglages n'avait AUCUN
      // effet sur le trafic réel (inscription, messages, médias), seulement sur un test de
      // connectivité qui, lui non plus, ne passait pas par Tor (voir network.dart). Pour une
      // personne qui compte sur Tor pour ne pas révéler son IP réelle en manifestation, c'était
      // une fuite silencieuse et invisible. Voir aussi onboarding_screen.dart, qui met à jour
      // `client.httpClient` en direct si le mode change après ce démarrage.
      final net = await NetConfig.load();
      // Trouvé en audit interne : l'« AUDIT OUVERT » laissé ici par une passe précédente affirmait
      // que `Level.warning` était « déjà le niveau le plus restrictif raisonnable » pour le logger
      // interne de matrix-dart-sdk (`Logs()`) — vérifié faux en lisant le code source réel au tag
      // pinné (`lib/matrix_api_lite/utils/logs.dart`) : l'énumération `Level` est ordonnée
      // `wtf < error < warning < info < debug < verbose`, et `Logs().addLogEvent` imprime dès que
      // `level.index <= logLevel.index` — autrement dit `Level.warning` laisse passer `wtf`, `error`
      // ET `warning`, pas seulement les avertissements. `Level.wtf` (toujours disponible, jamais
      // utilisé jusqu'ici) est strictement plus restrictif et n'existait pas moins permissif dans
      // ce paquet.
      //
      // Ce changement de niveau n'est pas qu'un ajustement de principe : en lisant le code réel du
      // SDK à ce même tag, un appel concret à ce niveau `warning` imprime en clair le contenu
      // complet d'un message `to_device` en échec de renvoi (`client.dart`,
      // `processToDeviceQueue` : `Logs().w('Payload: \$data')`) — qui porte, pour un message chiffré
      // via Olm, la clé d'identité Curve25519 de l'expéditeur (`sender_key`), une métadonnée
      // persistante et identifiante, pas seulement du texte déjà opaque. Avec `Level.warning`, cet
      // appel s'exécutait réellement (2 <= 2) ; avec `Level.wtf` (index 0), il ne s'exécute plus
      // (2 <= 0 est faux).
      //
      // Ce qui reste vérifié, et clôt la partie « jeton d'accès » de l'audit ouvert précédent (pas
      // seulement affirmé) : `MatrixException` (`matrix_exception.dart`) ne porte QUE le corps JSON
      // de la réponse du serveur (`raw`), jamais les en-têtes de la requête, et le jeton d'accès
      // n'est envoyé que dans l'en-tête `Authorization: Bearer ...` (`matrix_api.dart`), jamais dans
      // une URL — aucun des deux ne peut donc apparaître dans un message journalisé construit à
      // partir de ces objets, à quelque niveau que ce soit.
      //
      // LIMITE HONNÊTE : `Level.wtf` reste le niveau le plus restrictif que ce paquet expose, pas
      // une suppression totale — ses 4 appels `Logs().wtf(...)` dans ce dépôt (tag v0.29.0)
      // continueront de s'imprimer sur `adb logcat` en cas d'échec grave (ex. l'exception brute
      // d'une connexion HTTP, dont le contenu exact n'a pas été audité ligne à ligne pour toutes les
      // erreurs réseau possibles). Un `print()` en version publiée reste de toute façon lisible par
      // `adb logcat` par quiconque a un accès physique ET le débogage USB autorisé — un sous-ensemble
      // du modèle de menace visé (saisie), pas son intégralité ; non vérifié par une capture logcat
      // réelle sur un appareil physique, qui reste à faire avant de compter entièrement sur ce point
      // pour l'OPSEC.
      final client = Client(
        'Murmure',
        databaseBuilder: (_) async => MatrixSdkDatabase('murmure', database: db),
        logLevel: Level.wtf,
        httpClient: await net.httpClient(),
      );
      await client.init(waitForFirstSync: false, waitUntilLoadCompletedLoaded: true);

      // Appels (voir lib/calls/) : construit une seule fois, aux côtés du client Matrix. Le
      // delegate navigue vers CallSessionScreen via murmureNavigatorKey (pas de BuildContext
      // disponible ici) dès qu'un appel — sortant ou entrant — est prêt côté WebRTC.
      final callManager = CallManager(client: client);
      callManager.delegate.navigatorKey = murmureNavigatorKey;
      callManager.delegate.buildCallScreen = (session) => CallSessionScreen(session: session);

      // Vérification SAS (voir lib/verification/verification_manager.dart et
      // docs/E2EE_VERIFICATION.md) : même raison de construction précoce que CallManager
      // ci-dessus, pour ne manquer aucune demande entrante dès le premier rendu.
      final verificationManager = VerificationManager(client: client)..navigatorKey = murmureNavigatorKey;
      verificationManager.start();

      if (!mounted) return;
      setState(() {
        _client = client;
        _callManager = callManager;
        _verificationManager = verificationManager;
        _booting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _bootError = '$e';
        _booting = false;
      });
    }
  }

  /// Effacement d'urgence déclenché depuis l'écran de verrou (code de contrainte, ou trop
  /// d'essais) : ferme immédiatement l'appli après avoir tout effacé, voir [Account.panic].
  Future<void> _panic() => Account.panic(_client);

  @override
  void dispose() {
    _verificationManager?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: murmureNavigatorKey,
      title: 'Murmure',
      debugShowCheckedModeBanner: false,
      theme: murmureTheme(brightness: Brightness.light),
      darkTheme: murmureTheme(brightness: Brightness.dark),
      themeMode: ThemeMode.system,
      home: _booting
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _bootError != null
              ? _BootErrorScreen(error: _bootError!, onRetry: () {
                  setState(() {
                    _booting = true;
                    _bootError = null;
                  });
                  _boot();
                })
              : LockGate(
                  onWiped: _panic,
                  child: _Home(client: _client!, callManager: _callManager!),
                ),
    );
  }
}

class _Home extends StatelessWidget {
  const _Home({required this.client, required this.callManager});
  final Client client;
  final CallManager callManager;

  @override
  Widget build(BuildContext context) {
    if (!client.isLogged()) {
      return OnboardingScreen(client: client);
    }
    return RoomsScreen(client: client, callManager: callManager);
  }
}

class _BootErrorScreen extends StatelessWidget {
  const _BootErrorScreen({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              const Text('Démarrage impossible', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Réessayer')),
            ],
          ),
        ),
      ),
    );
  }
}
