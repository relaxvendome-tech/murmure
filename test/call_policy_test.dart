// Tests de lib/calls/call_policy.dart — politique d'appel fail-closed.
//
// Testé sans vrai Client Matrix ni réseau : `_FakeClient` n'implémente que `getTurnServer`
// (la seule méthode que CallPolicy.buildIceConfig appelle) ; toute autre méthode lève
// UnimplementedError via `Fake`, ce qui ferait échouer le test si CallPolicy en utilisait une autre.
//
// NON testable ici : le respect réel de `iceTransportPolicy: 'relay'` par le plugin WebRTC
// (nécessite capture réseau sur appareil physique, voir docs/CALLS_ARCHITECTURE.md).
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:murmure/calls/call_policy.dart';
import 'package:murmure/network.dart';

class _FakeClient extends Fake implements Client {
  _FakeClient({this.creds, this.error});
  final TurnServerCredentials? creds;
  final Object? error;
  int calls = 0;

  @override
  Future<TurnServerCredentials> getTurnServer() async {
    calls++;
    if (error != null) throw error!;
    return creds!;
  }
}

TurnServerCredentials _creds({List<String>? uris}) => TurnServerCredentials(
      password: 'pw',
      ttl: 600,
      // matrix >= 9 : `uris` est une `List<Uri>`.
      uris: (uris ?? ['turns:turn.example.org:5349?transport=tcp', 'turn:turn.example.org:3478'])
          .map(Uri.parse)
          .toList(),
      username: 'user',
    );

void main() {
  group('CallPolicy.isAllowed', () {
    test('seul le mode direct est autorisé', () {
      expect(CallPolicy.isAllowed(NetMode.direct), isTrue);
      expect(CallPolicy.isAllowed(NetMode.tor), isFalse);
      expect(CallPolicy.isAllowed(NetMode.customProxy), isFalse);
    });

    test('couvre tous les NetMode : tout nouveau mode est refusé sauf direct', () {
      for (final m in NetMode.values) {
        expect(CallPolicy.isAllowed(m), m == NetMode.direct, reason: m.name);
      }
    });
  });

  group('CallPolicy.buildIceConfig', () {
    test('mode non direct : null et le homeserver n\'est jamais contacté', () async {
      for (final m in [NetMode.tor, NetMode.customProxy]) {
        final client = _FakeClient(creds: _creds());
        expect(await CallPolicy.buildIceConfig(client: client, mode: m), isNull, reason: m.name);
        expect(client.calls, 0, reason: m.name);
      }
    });

    test('getTurnServer échoue : null (fail-closed, pas de repli sans TURN)', () async {
      final client = _FakeClient(error: Exception('M_NOT_FOUND'));
      expect(await CallPolicy.buildIceConfig(client: client, mode: NetMode.direct), isNull);
      expect(client.calls, 1);
    });

    test('liste d\'URIs TURN vide : null', () async {
      final client = _FakeClient(creds: _creds(uris: []));
      expect(await CallPolicy.buildIceConfig(client: client, mode: NetMode.direct), isNull);
    });

    test('config valide : relay forcé, identifiants du homeserver, aucun STUN', () async {
      final client = _FakeClient(creds: _creds());
      final cfg = await CallPolicy.buildIceConfig(client: client, mode: NetMode.direct);
      expect(cfg, isNotNull);
      expect(cfg!.iceTransportPolicy, 'relay');
      expect(cfg.iceServers, hasLength(1));
      final s = cfg.iceServers.single;
      expect(s.username, 'user');
      expect(s.credential, 'pw');
      expect(s.urls, ['turns:turn.example.org:5349?transport=tcp', 'turn:turn.example.org:3478']);
      for (final u in cfg.iceServers.expand((s) => s.urls)) {
        expect(u.toLowerCase().startsWith('stun'), isFalse, reason: u);
      }
    });

    test('les URI stun: renvoyées par le homeserver sont filtrées', () async {
      final client = _FakeClient(
          creds: _creds(uris: ['stun:s.example.org:3478', 'turn:turn.example.org:3478']));
      final cfg = await CallPolicy.buildIceConfig(client: client, mode: NetMode.direct);
      expect(cfg!.iceServers.single.urls, ['turn:turn.example.org:3478']);
      expect(cfg.iceTransportPolicy, 'relay');
    });

    test('uniquement des URI stun: → appel refusé (fail-closed)', () async {
      final client = _FakeClient(creds: _creds(uris: ['stun:s.example.org:3478']));
      expect(await CallPolicy.buildIceConfig(client: client, mode: NetMode.direct), isNull);
    });
  });

  group('CallIceConfig / CallIceServer toJson', () {
    test('forme attendue par RTCConfiguration', () {
      const cfg = CallIceConfig(
        iceServers: [CallIceServer(urls: ['turn:a:3478'], username: 'u', credential: 'c')],
        iceTransportPolicy: 'relay',
      );
      expect(cfg.toJson(), {
        'iceServers': [
          {'urls': ['turn:a:3478'], 'username': 'u', 'credential': 'c'},
        ],
        'iceTransportPolicy': 'relay',
      });
    });
  });
}
