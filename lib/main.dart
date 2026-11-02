import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'account.dart';
import 'media.dart';
import 'network.dart';
import 'ui/lock_screens.dart';
import 'ui/onboarding_screen.dart';
import 'ui/rooms_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await purgeMediaCache(); // nettoie les restes d'une lecture de média interrompue
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
      final client = Client(
        'Murmure',
        databaseBuilder: (_) async => MatrixSdkDatabase('murmure', database: db),
        logLevel: Level.warning,
        httpClient: await net.httpClient(),
      );
      await client.init(waitForFirstSync: false, waitUntilLoadCompletedLoaded: true);
      if (!mounted) return;
      setState(() {
        _client = client;
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
  Widget build(BuildContext context) {
    return MaterialApp(
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
                  child: _Home(client: _client!),
                ),
    );
  }
}

class _Home extends StatelessWidget {
  const _Home({required this.client});
  final Client client;

  @override
  Widget build(BuildContext context) {
    if (!client.isLogged()) {
      return OnboardingScreen(client: client);
    }
    return RoomsScreen(client: client);
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
