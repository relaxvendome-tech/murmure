import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'account.dart';
import 'media.dart';
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
      final client = Client(
        'Murmure',
        databaseBuilder: (_) async => MatrixSdkDatabase('murmure', database: db),
        logLevel: Level.warning,
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
