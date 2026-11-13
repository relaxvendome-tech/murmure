import 'package:flutter/material.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/matrix.dart';
// `KeyVerificationMethod` vit dans le barrel séparé `package:matrix/encryption.dart`, pas dans
// `package:matrix/matrix.dart` (voir le même commentaire dans verification_manager.dart).
import 'package:matrix/encryption.dart';

import 'account.dart';
import 'calls/services/call_manager.dart';
import 'calls/services/call_opsec_notifier.dart';
import 'calls/ui/call_session_screen.dart';
import 'crash_log.dart';
import 'ephemeral.dart';
import 'lock.dart';
import 'media.dart';
import 'message_notifier.dart';
import 'mesh/mesh_opsec_notifier.dart';
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
  // Tout en premier, avant même `ensureInitialized()` : voir crash_log.dart (journal de
  // plantages purement local, jamais transmis). Installé ici pour couvrir le plus de code
  // possible, y compris l'initialisation ci-dessous (`vod.init()`, ouverture des bases...).
  CrashLogStore.install();
  WidgetsFlutterBinding.ensureInitialized();
  // Chiffrement de bout en bout : matrix-dart-sdk 16.x utilise vodozemac (Rust, audité), via le
  // paquet Dart `vodozemac`, dont la bibliothèque native Android est fournie par
  // `flutter_vodozemac` (libvodozemac_bindings_dart.so, compilée par cargokit). Le SDK ne
  // l'initialise PAS lui-même : `Client.init()` ne crée `Encryption` que si `vod.isInitialized()`
  // (vérifié dans `client.dart` au tag v16.0.2) et, sinon, continue SANS chiffrement. Un échec
  // ici n'est donc jamais ignoré en silence : il laisse `encryptionEnabled` à faux, et le
  // garde-fou de `_boot`/`_Home`/`Account.register` refuse alors de démarrer ou de s'inscrire.
  // Aucun détail d'exception n'est journalisé (chemin de bibliothèque, etc.).
  try {
    await vod.init();
  } catch (_) {
    // Fail-closed : voir ci-dessus (encryptionEnabled restera faux).
  }
  await purgeMediaCache(); // nettoie les restes d'une lecture de média interrompue
  // Initialise le plugin de notifications d'appel et purge les anciens canaux, SANS demander la
  // permission POST_NOTIFICATIONS : une fenêtre système avant l'onboarding (ou par-dessus l'écran
  // de verrou) serait mauvaise pour l'UX et révélatrice en mode discret. La demande est faite
  // après l'onboarding et le premier déverrouillage, voir [_PostUnlockInit]. Best-effort.
  await CallOpsecNotifier.init();
  await MessageNotifier.init(); // notifications de nouveaux messages (sans contenu), best-effort
  // Trouvé en audit interne (revue multi-IA croisée) : sans cet appel, un message reçu en mode
  // maillé Bluetooth (voir mesh/mesh.dart) n'était signalé que si `MeshScreen` était déjà ouvert
  // (seul abonné précédent à `Mesh.instance.events`). S'abonne ici une fois, pour toute la durée
  // de vie de l'appli, indépendamment de l'écran affiché — voir mesh/mesh_opsec_notifier.dart.
  await MeshOpsecNotifier.init(); // best-effort, même principe que CallOpsecNotifier
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
  bool _bootError = false;

  /// Échec de démarrage dû à une panne Keystore ([KeystoreUnavailable]) : rien n'a été écrit ni
  /// supprimé ; « Réessayer » bouclerait dans le même processus (bascule collante du plugin).
  bool _keystoreDown = false;

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
      // une suppression totale — ses 6 appels `Logs().wtf(...)` dans ce dépôt (tag v16.0.2)
      // continueront de s'imprimer sur `adb logcat` en cas d'échec grave (ex. l'exception brute
      // d'une connexion HTTP, dont le contenu exact n'a pas été audité ligne à ligne pour toutes les
      // erreurs réseau possibles). Un `print()` en version publiée reste de toute façon lisible par
      // `adb logcat` par quiconque a un accès physique ET le débogage USB autorisé — un sous-ensemble
      // du modèle de menace visé (saisie), pas son intégralité ; non vérifié par une capture logcat
      // réelle sur un appareil physique, qui reste à faire avant de compter entièrement sur ce point
      // pour l'OPSEC.
      final client = Client(
        'Murmure',
        // matrix-dart-sdk >= 1.0.0 : le constructeur exige une base DÉJÀ ouverte
        // (`databaseBuilder` supprimé). `MatrixSdkDatabase.init` construit puis appelle `open()`
        // (qui crée/migre les tables) — même base SQLCipher qu'avant (`murmure_matrix.db`, clé
        // Keystore de [Account.dbKey]). Une base créée par l'ancien SDK 0.29 est migrée par
        // `_migrateFromVersion` du SDK (au pire vidage du cache + resynchronisation) ; les comptes
        // Olm/sessions Megolm picklés par libolm sont relus par vodozemac
        // (`fromOlmPickleEncrypted`, vérifié dans olm_manager.dart/session_key.dart au tag v16.0.2).
        // `secureStorage` volontairement NON renseigné : le jeton d'accès et le compte Olm ne sont
        // pas dupliqués hors de la base chiffrée.
        database: await MatrixSdkDatabase.init('murmure', database: db),
        logLevel: Level.wtf,
        httpClient: await net.httpClient(),
        // Trouvé en audit interne (revue indépendante) : sans ce paramètre, `Client` retombe sur
        // `verificationMethods ?? <KeyVerificationMethod>{}` (voir `client.dart` du SDK, tag
        // v0.29.0, inchangé au tag v16.0.2) — un ensemble VIDE. Conséquence vérifiée dans le SDK réel : côté demande
        // entrante, `KeyVerification.handlePayload(request)` calcule
        // `possibleMethods = payload['methods'].intersect(client.verificationMethods)` ; vide,
        // il annule immédiatement en `m.unknown_method` AVANT d'atteindre l'état `askAccept` —
        // `onKeyVerificationRequest` ne s'émet donc jamais et `VerificationManager` ne reçoit
        // rien. Côté demande sortante, `startVerification()` annonce `methods: []`, que le
        // correspondant rejette aussitôt. Dans les deux cas l'écran affichait « Vérification
        // annulée ou échouée… ne faites pas confiance » — un message qui ressemble à une alerte
        // d'homme du milieu alors que c'était un simple paramètre manquant à la construction du
        // client, la fonctionnalité de vérification d'appareil n'ayant jamais réellement
        // fonctionné. Seul `emoji` est annoncé : c'est la seule méthode que l'UI de ce dépôt sait
        // présenter (voir sas_verification_screen.dart, comparaison d'émojis uniquement — aucun
        // flux QR `qrShow`/`qrScan`/`reciprocate` n'est implémenté côté écran, les annoncer sans
        // les gérer romprait le protocole côté correspondant qui choisirait l'une d'elles).
        verificationMethods: {KeyVerificationMethod.emoji},
      );
      await client.init(waitForFirstSync: false, waitUntilLoadCompletedLoaded: true);

      // CRITIQUE (vérifié dans matrix-dart-sdk v16.0.2, `Client.init`) : si vodozemac n'est pas
      // initialisé (ou si `Encryption` lève), le SDK met `encryption = null` et CONTINUE — `encryptionEnabled`
      // devient faux et les messages partiraient en clair, sans aucune erreur visible. Fail closed :
      // une session connectée sans chiffrement fonctionnel ne démarre jamais.
      if (client.isLogged() && !client.encryptionEnabled) {
        try {
          await client.dispose(closeDatabase: true);
        } catch (_) {
          // Best-effort : l'essentiel est de ne jamais exposer ce client à l'interface.
        }
        throw const _EncryptionUnavailable();
      }

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
      MessageNotifier.attach(client); // écoute client.onEvent, voir message_notifier.dart
      // Messages éphémères : balayage périodique de toutes les conversations, pas seulement de
      // celle ouverte à l'écran (voir lib/ephemeral.dart).
      EphemeralService.instance.start(client);

      if (!mounted) return;
      setState(() {
        _client = client;
        _callManager = callManager;
        _verificationManager = verificationManager;
        _booting = false;
      });
    } catch (e) {
      // Jamais le texte de l'exception à l'écran : cet écran s'affiche AVANT le verrou (il n'y a
      // pas encore de client pour construire LockGate), donc lisible par quiconque tient le
      // téléphone — un chemin de fichier, une adresse de serveur ou un identifiant y fuiraient.
      if (!mounted) return;
      setState(() {
        _bootError = true;
        _keystoreDown = e is KeystoreUnavailable;
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
      // Écran opaque PAR-DESSUS toutes les routes (pas seulement LockGate, simple `home:`) quand
      // l'appli passe en `inactive`/`hidden`/arrière-plan avec un code actif : voir
      // [AppLock.obscured] et `LockGate.didChangeAppLifecycleState`. Noir uni, neutre en mode
      // discret comme en mode normal.
      builder: (context, child) => ValueListenableBuilder<bool>(
        valueListenable: AppLock.obscured,
        child: child,
        builder: (context, obscured, child) => Stack(
          alignment: Alignment.topLeft,
          fit: StackFit.expand,
          children: [
            if (child != null) child,
            if (obscured) const ColoredBox(color: Colors.black),
          ],
        ),
      ),
      home: _booting
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _bootError
              ? _keystoreDown
                  ? const _BootErrorScreen(relaunchOnly: true)
                  : _BootErrorScreen(onRetry: () {
                      setState(() {
                        _booting = true;
                        _bootError = false;
                      });
                      _boot();
                    })
              : LockGate(
                  onWiped: _panic,
                  callManager: _callManager!,
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
    // Trouvé en audit interne (revue indépendante), confirmé contre le code réel : ce widget
    // était un simple `StatelessWidget` qui ne lisait `client.isLogged()` qu'au moment de son
    // propre `build()`, sans jamais s'abonner à `client.onLoginStateChanged` — alors que
    // `onboarding_screen.dart` affirmait dans un commentaire (« Rien d'autre à faire : MurmureApp
    // réagit à client.isLogged() ») que la réussite de `Account.register()`/connexion suffisait à
    // faire réapparaître ce widget avec `RoomsScreen`. Faux : rien ne déclenchait jamais de
    // nouveau `build()` après la création du compte — `_MurmureAppState._boot()` ne s'exécute
    // qu'une fois, à `initState()`. L'écran d'onboarding restait donc affiché indéfiniment après
    // une inscription pourtant réussie côté serveur, sans aucun message d'erreur (le compte
    // existe, seule l'UI ne le sait pas) : il fallait fermer et relancer l'appli pour voir enfin
    // la messagerie. `onLoginStateChanged` (`CachedStreamController`, même famille que
    // `client.onSync` déjà utilisé dans rooms_screen.dart) a `.value` ET `.stream`, donc
    // `StreamBuilder` avec `initialData` évite tout flash de l'écran d'onboarding au premier
    // rendu d'une session déjà connectée.
    return StreamBuilder<LoginState>(
      stream: client.onLoginStateChanged.stream,
      initialData: client.onLoginStateChanged.value,
      builder: (context, snapshot) {
        final loggedIn = snapshot.data == LoginState.loggedIn;
        if (!loggedIn) {
          return OnboardingScreen(client: client);
        }
        // Même garde-fou que dans `_boot` (vodozemac absent => SDK silencieusement sans chiffrement),
        // couvrant aussi la session ouverte juste après l'inscription, qui ne repasse pas par
        // `_boot`. Rien n'est envoyable tant que ce test échoue.
        if (!client.encryptionEnabled) {
          return const _BootErrorScreen();
        }
        return _PostUnlockInit(child: RoomsScreen(client: client, callManager: callManager));
      },
    );
  }
}

/// Session connectée mais chiffrement de bout en bout indisponible (vodozemac non initialisé) : on
/// refuse de démarrer plutôt que d'envoyer en clair. Message volontairement neutre à l'écran.
class _EncryptionUnavailable implements Exception {
  const _EncryptionUnavailable();
}

/// Tâches à ne lancer qu'une fois l'onboarding terminé ET l'appli déverrouillée (ce widget n'est
/// construit que sous LockGate, une fois connecté) : demande de permission de notifications
/// (POST_NOTIFICATIONS, via [CallOpsecNotifier.requestPermission] ; le plugin lui-même est
/// initialisé sans demande dans `main()`). Une seule fois par processus.
class _PostUnlockInit extends StatefulWidget {
  const _PostUnlockInit({required this.child});
  final Widget child;

  @override
  State<_PostUnlockInit> createState() => _PostUnlockInitState();
}

class _PostUnlockInitState extends State<_PostUnlockInit> {
  static bool _done = false;

  @override
  void initState() {
    super.initState();
    if (_done) return;
    _done = true;
    // Après le premier rendu : la fenêtre système ne doit pas interrompre la construction.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      CallOpsecNotifier.requestPermission(); // best-effort, voir cette méthode
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _BootErrorScreen extends StatelessWidget {
  const _BootErrorScreen({this.onRetry, this.relaunchOnly = false});

  /// Nul quand réessayer ne peut rien changer dans cette session (chiffrement indisponible après
  /// inscription) : l'appli doit être relancée.
  final VoidCallback? onRetry;

  /// Panne Keystore ([KeystoreUnavailable]) : écran neutre, seul message « relancez », pas de
  /// « Réessayer » (il bouclerait dans le même processus).
  final bool relaunchOnly;

  @override
  Widget build(BuildContext context) {
    if (relaunchOnly) {
      return const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(kRelaunchMessage, textAlign: TextAlign.center),
          ),
        ),
      );
    }
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              const Text('Démarrage impossible. Réessayez.',
                  textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold)),
              // Raison d'un échec bloquant connu (ex. inscription annulée faute de chiffrement,
              // voir [Account.register]) : texte fixe, jamais un message d'exception brut.
              ValueListenableBuilder<String?>(
                valueListenable: fatalErrorReason,
                builder: (context, reason, _) => reason == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(reason, textAlign: TextAlign.center),
                      ),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: onRetry, child: const Text('Réessayer')),
              ] else ...[
                const SizedBox(height: 8),
                const Text('Fermez puis relancez l\'appli.', textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
