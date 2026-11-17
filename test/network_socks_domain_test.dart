// Verrou de régression pour le point vérifié dans la doc de [NetConfig.httpClient]
// (lib/network.dart) : en mode Tor/proxy SOCKS5 personnalisé, le nom d'hôte du HOMESERVER (pas
// celui du proxy, déjà couvert par net_config_test.dart) doit partir en clair vers le proxy
// (type d'adresse SOCKS5 0x03 « domain »), jamais pré-résolu en IP localement (type 0x01/0x04) —
// sinon le résolveur DNS du système, donc potentiellement le réseau local/FAI, verrait quel
// domaine est visité même si la connexion TCP part ensuite par Tor.
//
// Vérifié en lisant directement le code source du paquet `socks5_proxy` 2.1.1 épinglé (dépôt
// github.com/LacticWhale/socks_dart, commit 317f086 = exactement la version 2.1.1) :
// `socks_tcp_client.dart` construit l'adresse cible avec
// `InternetAddress(uri.host, type: InternetAddressType.unix)` — jamais une IP déjà résolue — et
// `socks_client.dart` mappe ce type vers `AddressType.domain` (0x03) avant d'envoyer les octets
// UTF-8 du NOM dans la requête CONNECT. Ce test ne relit pas ce code à chaque run : il observe le
// comportement réel sur le fil, pour détecter toute régression (mise à jour du paquet qui
// changerait ce choix, ou refactor côté Murmure qui romprait la chaîne).
//
// Un faux serveur SOCKS5 minimal tourne sur une socket TCP locale : il ne comprend que l'étape de
// négociation et la requête CONNECT, capture son type d'adresse et son contenu, répond avec un
// succès SOCKS5 factice, puis ferme — le TLS qui suit échoue forcément (aucun vrai serveur
// derrière), ce qui est attendu et ignoré : seule la requête CONNECT elle-même est examinée.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:murmure/network.dart';

/// Lecteur à tampon minimal sur une [Socket] : accumule les octets reçus et ne complète une
/// lecture que lorsque assez d'octets sont arrivés (un seul `add` TCP ne contient pas forcément
/// un message SOCKS5 entier, même en boucle locale).
class _BufferedSocketReader {
  _BufferedSocketReader(Socket socket) {
    _sub = socket.listen(_onData, onDone: () => _onData(Uint8List(0)));
  }

  final List<int> _buf = [];
  final List<_PendingRead> _pending = [];
  late final StreamSubscription<Uint8List> _sub;

  void _onData(Uint8List data) {
    _buf.addAll(data);
    while (_pending.isNotEmpty && _buf.length >= _pending.first.n) {
      final p = _pending.removeAt(0);
      p.completer.complete(_buf.sublist(0, p.n));
      _buf.removeRange(0, p.n);
    }
  }

  Future<List<int>> readN(int n) {
    if (_buf.length >= n) {
      final chunk = _buf.sublist(0, n);
      _buf.removeRange(0, n);
      return Future.value(chunk);
    }
    final completer = Completer<List<int>>();
    _pending.add(_PendingRead(n, completer));
    return completer.future;
  }

  Future<void> dispose() => _sub.cancel();
}

class _PendingRead {
  _PendingRead(this.n, this.completer);
  final int n;
  final Completer<List<int>> completer;
}

void main() {
  test(
    'customProxy/Tor : le nom du homeserver part en ATYP domain (0x03), jamais en IP résolue',
    () async {
      final serverSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => serverSocket.close());

      int? capturedAtyp;
      List<int>? capturedAddressBytes;
      final serverDone = Completer<void>();

      serverSocket.listen((socket) async {
        final reader = _BufferedSocketReader(socket);
        try {
          // Négociation : version, nombre de méthodes, méthodes (Murmure ne configure pas
          // d'authentification, donc toujours [0x05, 0x01, 0x00]).
          final greeting = await reader.readN(3);
          expect(greeting[0], 0x05, reason: 'version SOCKS5');
          socket.add([0x05, 0x00]); // méthode choisie : aucune authentification.
          await socket.flush();

          // En-tête de la requête CONNECT : version, commande, réservé, type d'adresse.
          final header = await reader.readN(4);
          expect(header[0], 0x05);
          expect(header[1], 0x01, reason: 'commande CONNECT');
          capturedAtyp = header[3];

          if (capturedAtyp == 0x01) {
            // IPv4 résolue localement : exactement ce qu'on ne veut jamais voir ici.
            capturedAddressBytes = await reader.readN(4);
          } else if (capturedAtyp == 0x04) {
            // IPv6 résolue localement : idem.
            capturedAddressBytes = await reader.readN(16);
          } else if (capturedAtyp == 0x03) {
            // Domaine en clair, laissé au proxy à résoudre : le comportement attendu.
            final lenByte = await reader.readN(1);
            capturedAddressBytes = await reader.readN(lenByte[0]);
          } else {
            fail('type d\'adresse SOCKS5 inattendu : $capturedAtyp');
          }
          await reader.readN(2); // port, pas utile à ce test.

          // Réponse de succès factice (adresse liée 0.0.0.0:0) pour laisser le client avancer
          // vers la poignée de main TLS, qui échouera faute de vrai serveur — attendu et ignoré.
          socket.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
          await socket.flush();
        } finally {
          await reader.dispose();
          if (!serverDone.isCompleted) serverDone.complete();
          // Laisse le client avancer vers sa tentative TLS (qui échouera, aucun vrai serveur
          // derrière) avant de couper : fermer trop tôt ferait échouer `send()` avant même que la
          // requête CONNECT capturée ci-dessus ait pu être validée par les assertions.
          await Future.delayed(const Duration(milliseconds: 100));
          await socket.close();
        }
      });

      final cfg = NetConfig(
        homeserver: Uri.parse('https://mon-homeserver.murmure.invalid'),
        registrationToken: 'tok',
        mode: NetMode.customProxy,
        proxyHost: '127.0.0.1',
        proxyPort: serverSocket.port,
      );
      final client = await cfg.httpClient();
      try {
        await client
            .get(Uri.parse('https://mon-homeserver.murmure.invalid/_matrix/client/versions'))
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        // Attendu : pas de vrai serveur TLS derrière le faux proxy SOCKS5. Seule la requête
        // CONNECT, déjà capturée ci-dessus, nous intéresse.
      } finally {
        client.close();
      }

      await serverDone.future.timeout(const Duration(seconds: 5));

      expect(
        capturedAtyp,
        0x03,
        reason: 'le homeserver doit être désigné par son NOM (SOCKS5 domain, 0x03) pour que ce '
            'soit le proxy — Tor ou le proxy personnalisé — qui le résolve, jamais le résolveur '
            'DNS local',
      );
      expect(utf8.decode(capturedAddressBytes!), 'mon-homeserver.murmure.invalid');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
