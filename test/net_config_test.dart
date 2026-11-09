// Tests de NetConfig.copyWith, NetConfig.httpClient (garantie fail-closed) et ProxyConfigError,
// lib/network.dart. Aucune connexion réseau : les clients SOCKS créés ne se connectent qu'à la
// première requête, et sont fermés immédiatement.
import 'package:flutter_test/flutter_test.dart';
import 'package:murmure/network.dart';

NetConfig _cfg({NetMode mode = NetMode.direct, String? host, int? port}) => NetConfig(
      homeserver: Uri.parse('https://hs.example.org'),
      registrationToken: 'tok',
      mode: mode,
      proxyHost: host,
      proxyPort: port,
    );

void main() {
  group('NetConfig.copyWith', () {
    test('sans argument : copie identique', () {
      final c = _cfg(mode: NetMode.customProxy, host: '1.2.3.4', port: 1080).copyWith();
      expect(c.homeserver, Uri.parse('https://hs.example.org'));
      expect(c.registrationToken, 'tok');
      expect(c.mode, NetMode.customProxy);
      expect(c.proxyHost, '1.2.3.4');
      expect(c.proxyPort, 1080);
    });

    test('ne modifie que les champs fournis', () {
      final c = _cfg().copyWith(mode: NetMode.tor, registrationToken: 'x');
      expect(c.mode, NetMode.tor);
      expect(c.registrationToken, 'x');
      expect(c.homeserver, Uri.parse('https://hs.example.org'));
    });
  });

  group('NetConfig.httpClient (fail-closed)', () {
    test('customProxy sans hôte : ProxyConfigError, jamais de client direct', () async {
      await expectLater(_cfg(mode: NetMode.customProxy, port: 1080).httpClient(),
          throwsA(isA<ProxyConfigError>()));
    });

    test('customProxy avec hôte vide : ProxyConfigError', () async {
      await expectLater(_cfg(mode: NetMode.customProxy, host: '', port: 1080).httpClient(),
          throwsA(isA<ProxyConfigError>()));
    });

    test('customProxy sans port : ProxyConfigError', () async {
      await expectLater(_cfg(mode: NetMode.customProxy, host: '127.0.0.1').httpClient(),
          throwsA(isA<ProxyConfigError>()));
    });

    test('tor et customProxy valides : retournent un client sans lever', () async {
      final tor = await _cfg(mode: NetMode.tor).httpClient();
      tor.close();
      final custom =
          await _cfg(mode: NetMode.customProxy, host: '127.0.0.1', port: 1080).httpClient();
      custom.close();
    });

    test('customProxy par nom d\'hôte : aucune résolution DNS à la création (démarrage hors ligne)',
        () async {
      // `.invalid` ne se résout jamais (RFC 2606) : si httpClient() résolvait encore le nom au
      // démarrage, cet appel lèverait. Il doit rendre un client sans lever.
      final c = await _cfg(mode: NetMode.customProxy, host: 'proxy.murmure.invalid', port: 1080)
          .httpClient();
      c.close();
    });

    test('customProxy par nom d\'hôte irrésoluble : le premier envoi lève ProxyConfigError, '
        'jamais de repli direct', () async {
      final c = await _cfg(mode: NetMode.customProxy, host: 'proxy.murmure.invalid', port: 1080)
          .httpClient();
      try {
        await expectLater(
          c.get(Uri.parse('https://hs.example.org/_matrix/client/versions')),
          throwsA(isA<ProxyConfigError>()),
        );
      } finally {
        c.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('direct : retourne un client', () async {
      (await _cfg().httpClient()).close();
    });
  });

  group('ProxyConfigError', () {
    test('toString renvoie le message tel quel', () {
      expect(const ProxyConfigError('boom').toString(), 'boom');
      expect(const ProxyConfigError('boom').message, 'boom');
    });
  });
}
