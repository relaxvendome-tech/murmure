import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
// `KeyVerificationMethod` vit dans le barrel séparé `package:matrix/encryption.dart`, pas dans
// `package:matrix/matrix.dart` (voir le même commentaire dans verification_manager.dart).
import 'package:matrix/encryption.dart';

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
  // Trouvé en audit interne (revue indépendante, croisée avec le code source réel de
  // matrix-dart-sdk au tag v0.29.13 — version que `matrix: ^0.29.0` résout effectivement ici,
  // confirmé par le log de CI — et avec FluffyChat, l'app de référence du même éditeur) :
  // `flutter_vodozemac`/`vod.init()` (précédemment appelé ici) ne servait à RIEN pour cette
  // version du SDK. `vodozemac` n'a été introduit dans matrix-dart-sdk qu'à partir du tag v1.0.0
  // (migration majeure, juin 2025) ; à v0.29.13, `cross_signing.dart`, `encryption.dart`,
  // `key_manager.dart` et `olm_manager.dart` importent tous `package:olm/olm.dart` (libolm, pas
  // vodozemac) et c'est OlmManager qui appelle lui-même `olm.init()` en interne, à l'intérieur de
  // `Client.init()` (voir `Encryption.init()` au tag v0.29.13) — jamais l'appli elle-même.
  // Appeler `vod.init()` ici initialisait donc une bibliothèque (vodozemac) que le SDK ne regarde
  // jamais à cette version, pendant que celle qu'il utilise réellement (`olm`, via
  // `DynamicLibrary.open('libolm.so')` sur Android, voir `ffi_base.dart` du paquet `olm`) n'avait
  // aucun `.so` fourni dans l'APK : aucun paquet de ce dépôt ne livrait `libolm.so` (`flutter_olm`
  // n'était pas déclaré). Résultat réel, non testé sur appareil faute de toolchain Flutter dans ce
  // bac à sable mais déduit du code source des deux paquets : `DynamicLibrary.open` échoue dès le
  // premier accès aux bindings `olm`, donc dès `client.init()` plus bas, pour CHAQUE lancement —
  // chiffrement de bout en bout indisponible, pas seulement affaibli. Corrigé en ajoutant
  // `flutter_olm` à pubspec.yaml (fournit `libolm.so` pour Android/iOS, le pairing documenté par
  // le paquet `olm` lui-même) et en retirant `flutter_vodozemac`, dépendance morte à cette version
  // du SDK. LIMITE HONNÊTE, et ouverte comme chantier séparé : `libolm`/`flutter_olm` sont tous
  // deux dépréciés en amont (flutter_olm sans publication depuis ~2 ans) au profit de vodozemac ;
  // une migration délibérée vers une version de matrix-dart-sdk >= v6.1.0 (la plus ancienne dont
  // la contrainte `vodozemac` reste compatible avec `flutter_vodozemac: ^0.5.0`) serait la
  // correction propre à terme, mais implique des changements d'API cassants cumulés sur les appels
  // WebRTC (migrations VoIP des versions 2.0.0 à 6.1.0) qu'il serait irresponsable de faire à
  // l'aveugle, sans compilateur Flutter local pour les valider un par un.
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
        // Trouvé en audit interne (revue indépendante), confirmé contre le code source réel de
        // matrix-dart-sdk (tag v0.29.13, `matrix_sdk_database.dart`) : le constructeur de
        // `MatrixSdkDatabase` ne fait qu'enregistrer ses paramètres — `_collection` (champ `late`)
        // n'est affecté que dans `open()`, une méthode SÉPARÉE que `Client.init()` n'appelle
        // JAMAIS lui-même pour vous (vérifié : aucun `.open()` dans `client.dart`). C'est l'appli
        // qui doit le faire, exactement comme le fait l'exemple officiel du SDK
        // (`example/main.dart`) et sa propre suite de tests (`test/fake_database.dart`) — les deux
        // appellent `await db.open()` juste après l'avoir construite. Sans cet appel, le premier
        // accès à la base par `Client.init()` (`database?.getClient(...)`) levait une
        // `LateInitializationError` sur `_collection` — crash au tout premier lancement, avant même
        // l'écran d'onboarding, à chaque fois.
        databaseBuilder: (_) async {
          final database = MatrixSdkDatabase('murmure', database: db);
          await database.open();
          return database;
        },
        logLevel: Level.wtf,
        httpClient: await net.httpClient(),
        // Trouvé en audit interne (revue indépendante) : sans ce paramètre, `Client` retombe sur
        // `verificationMethods ?? <KeyVerificationMethod>{}` (voir `client.dart` du SDK, tag
        // v0.29.0) — un ensemble VIDE. Conséquence vérifiée dans le SDK réel : côté demande
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
        return RoomsScreen(client: client, callManager: callManager);
      },
    );
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
