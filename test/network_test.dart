// Tests de lib/network.dart — trois fonctions pures ou testables sans vrai réseau
// (`describeMatrixError`, `NetConfig.isConfigured`, `canReach`), choisies car ce fichier porte la
// garantie « fail closed » du projet (jamais de repli silencieux vers une connexion directe quand
// Tor ou un proxy SOCKS5 est demandé, voir le commentaire de NetConfig.httpClient) et a déjà été
// corrigé deux fois pour des bugs de ce type (31ba08f, 9419886). `canReach` est testée avec
// `http.testing.MockClient` (fourni par le paquet `http` lui-même, pas de dépendance
// supplémentaire) plutôt qu'un vrai socket : elle ne doit dépendre que du client qu'on lui passe,
// jamais en créer un en interne — exactement la régression que le commentaire de canReach décrit
// avoir corrigée.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:murmure/network.dart';

void main() {
  group('describeMatrixError', () {
    test('extrait le champ "error" d\'une réponse JSON Matrix classique', () {
      final body = '{"errcode":"M_FORBIDDEN","error":"Jeton d\'inscription invalide"}';
      expect(describeMatrixError(body), 'Jeton d\'inscription invalide');
    });

    test('retourne le corps brut si le JSON est valide mais sans champ "error"', () {
      const body = '{"errcode":"M_UNKNOWN"}';
      expect(describeMatrixError(body), body);
    });

    test('retourne le corps brut si ce n\'est pas du JSON du tout', () {
      const body = 'Bad Gateway';
      expect(describeMatrixError(body), body);
    });

    test('retourne le corps brut si le JSON est valide mais n\'est pas un objet', () {
      const body = '[1,2,3]';
      expect(describeMatrixError(body), body);
    });

    test('retourne le corps brut si "error" n\'est pas une chaîne', () {
      const body = '{"error":42}';
      expect(describeMatrixError(body), body);
    });
  });

  group('NetConfig.isConfigured', () {
    NetConfig withHomeserver(Uri uri) => NetConfig(
          homeserver: uri,
          registrationToken: '',
          mode: NetMode.direct,
        );

    test('vrai pour un homeserver https avec un hôte', () {
      expect(withHomeserver(Uri.parse('https://matrix.exemple.invalid')).isConfigured, isTrue);
    });

    test('vrai pour une adresse .onion (Tor)', () {
      expect(
        withHomeserver(Uri.parse('https://exempleoniona1b2c3d4.onion')).isConfigured,
        isTrue,
      );
    });

    test('faux pour un Uri vide (aucun serveur configuré)', () {
      expect(withHomeserver(Uri.parse('')).isConfigured, isFalse);
    });

    test('faux pour un schéma sans hôte', () {
      expect(withHomeserver(Uri.parse('https://')).isConfigured, isFalse);
    });

    test('faux pour le homeserver invalide par défaut de NetConfig.load()', () {
      // Uri.parse('https://invalid.invalid') a bien un hôte ("invalid.invalid") : ce n'est pas
      // isConfigured qui protège contre ce cas-là mais canReach(), qui échouera simplement à
      // joindre ce nom. On fige ici le comportement réel plutôt que celui qu'on pourrait
      // supposer, pour que ce test échoue si cette hypothèse change un jour silencieusement.
      expect(withHomeserver(Uri.parse('https://invalid.invalid')).isConfigured, isTrue);
    });
  });

  group('canReach', () {
    test('vrai quand le client retourne 200 sur /_matrix/client/versions', () async {
      Uri? requested;
      final client = MockClient((request) async {
        requested = request.url;
        return http.Response('{}', 200);
      });
      final ok = await canReach(Uri.parse('https://matrix.exemple.invalid'), client: client);
      expect(ok, isTrue);
      expect(requested.toString(), 'https://matrix.exemple.invalid/_matrix/client/versions');
    });

    test('faux quand le serveur répond autre chose que 200', () async {
      final client = MockClient((request) async => http.Response('erreur', 502));
      final ok = await canReach(Uri.parse('https://matrix.exemple.invalid'), client: client);
      expect(ok, isFalse);
    });

    test('faux (jamais une exception) quand la requête échoue (hors ligne, proxy mort, etc.)', () async {
      final client = MockClient((request) async => throw Exception('connexion refusée'));
      final ok = await canReach(Uri.parse('https://matrix.exemple.invalid'), client: client);
      expect(ok, isFalse);
    });

    test('faux (jamais une exception) sur dépassement du délai', () async {
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response('{}', 200);
      });
      final ok = await canReach(
        Uri.parse('https://matrix.exemple.invalid'),
        client: client,
        timeout: const Duration(milliseconds: 1),
      );
      expect(ok, isFalse);
    });

    test('faux sans même appeler le client quand le homeserver n\'a pas de schéma', () async {
      final client = MockClient((request) async {
        fail('canReach ne doit pas émettre de requête sans schéma valide');
      });
      final ok = await canReach(Uri.parse(''), client: client);
      expect(ok, isFalse);
    });
  });
}
