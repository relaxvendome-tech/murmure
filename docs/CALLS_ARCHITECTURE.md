# Appels audio/vidéo — ce qu'il faut garantir avant d'écrire une ligne de code

Ce document fixe par écrit, comme `ADMIN_KEY.md` l'a fait pour la clé administrateur, la règle
non négociable pour les appels Murmure : **un appel ne doit jamais révéler l'adresse IP réelle de
l'appareil quand le mode réseau choisi est Tor ou un proxy SOCKS5 personnalisé** — exactement la
même garantie que celle qu'on vient de corriger pour le reste du trafic (`network.dart`). Tant que
ce document n'est pas entièrement respecté par l'implémentation, les appels restent désactivés en
mode Tor/proxy (voir « Comportement par défaut » plus bas).

## Pourquoi c'est plus difficile que le reste du trafic

Le correctif réseau de cette revue (SOCKS5 réel via `socks5_proxy`) ne protège que le trafic qui
passe par un `http.Client` — essentiellement les requêtes HTTP/HTTPS vers le homeserver (sync,
envoi de messages, upload de médias, et donc la signalisation des appels, qui transite elle aussi
par l'API Matrix en HTTPS). **Il ne protège PAS le flux média lui-même**, qui ne passe jamais par
ce client HTTP :

- WebRTC établit la connexion média via **ICE**, qui sonde plusieurs chemins possibles et choisit
  le meilleur. Parmi les candidats qu'il génère et peut annoncer à l'autre partie :
  - **candidats "host"** : l'adresse IP locale de l'appareil, en clair.
  - **candidats "srflx"** (server reflexive) : l'IP publique de l'appareil, obtenue en interrogeant
    un serveur **STUN** — c'est exactement le mécanisme que Tor/un VPN sert à cacher, et ICE
    l'annonce par défaut à l'autre partie de l'appel.
  - **candidats "relay"** : l'adresse d'un serveur **TURN**, qui relaie le flux sans jamais révéler
    l'IP réelle à l'autre partie — c'est le SEUL type de candidat sûr dans ce contexte.
- Ce flux ICE/STUN/TURN est très majoritairement transporté en **UDP**. Le proxy SOCKS5 qu'on a
  mis en place (`socks5_proxy` / `SocksTCPClient`) ne tunnelle que des connexions **TCP** — c'est
  une limite du protocole SOCKS5 lui-même tel qu'il est généralement implémenté (Tor/Orbot, en
  particulier, ne relaie pas d'UDP : le réseau Tor est un réseau de circuits TCP). Autrement dit,
  **le mécanisme réseau qu'on vient de corriger ne peut, par construction, pas protéger le flux
  média d'un appel**. Une autre défense est nécessaire, au niveau de la configuration WebRTC
  elle-même, pas au niveau du transport réseau générique.
- La pile WebRTC native (quel que soit le plugin Flutter utilisé) **gère ses propres sockets
  directement**, en dehors du `http.Client` Dart. Même si `NetConfig.httpClient()` est parfaitement
  correct, un plugin WebRTC peut très bien ouvrir ses connexions UDP/TCP sans jamais passer par ce
  client — il faut vérifier, pour le plugin choisi, qu'il expose une configuration ICE qui permette
  de désactiver purement et simplement STUN et les candidats host/srflx, pas seulement de
  "préférer" TURN.

## Ce qui doit être vrai avant d'activer les appels en mode Tor/proxy

1. **Aucun serveur STUN configuré en mode Tor/proxy.** Pas de `urls: stun:...` dans la
   configuration ICE passée au plugin WebRTC quand `NetConfig.mode != NetMode.direct`. Un serveur
   STUN existe pour une seule raison : révéler l'IP publique de l'appelant à lui-même (et donc,
   via l'échange de candidats ICE, à l'autre partie). On ne doit jamais le faire tourner ici.
2. **Un serveur TURN joignable en TCP/TLS (port 443, `turns:`) est obligatoire** pour que l'appel
   fonctionne malgré l'absence de STUN — sans ça, deux appareils derrière un NAT ne se connectent
   simplement jamais. Murmure doit héberger (ou permettre de configurer, comme pour le homeserver)
   un serveur TURN tel que **coturn**, avec `tls-listening-port` sur 443 et des identifiants de
   courte durée (`use-auth-secret`, renouvelés par le homeserver — c'est le mécanisme standard
   Matrix `org.matrix.msc3266`/`m.call.turn_server` côté serveur).
3. **`iceTransportPolicy: 'relay'` forcé** dans la configuration WebRTC dès que le mode n'est pas
   direct : ça interdit à la pile ICE d'utiliser ou même de GÉNÉRER un candidat host/srflx, quelle
   que soit la configuration de serveurs fournie par ailleurs. C'est la garantie structurelle, pas
   une simple préférence — sans ce réglage, un candidat host peut être annoncé même si aucun STUN
   n'est configuré (l'IP locale ne nécessite pas de STUN pour être connue).
4. **Le trafic TURN lui-même doit sortir via le proxy choisi.** Si le plugin WebRTC accepte un
   réglage de proxy SOCKS5/HTTP pour ses propres connexions (certains le permettent pour les flux
   relayés en TCP/TLS), il doit être configuré avec le même proxy que `NetConfig.httpClient()`.
   Si le plugin retenu ne le permet pas, le serveur TURN doit alors être joint directement — ce qui
   signifie que **l'IP réelle de l'appareil est révélée au serveur TURN**, même si elle reste
   cachée à l'autre partie de l'appel. Ce point doit être vérifié précisément pour le plugin choisi
   et écrit noir sur blanc dans l'interface utilisateur avant l'appel (bannière d'avertissement),
   jamais supposé silencieusement sûr.
5. **La signalisation (SDP, candidats ICE, raccroché) passe par les événements d'appel Matrix
   standard** (`m.call.invite`, `m.call.candidates`, etc.), donc par le homeserver, donc par
   `NetConfig.httpClient()` — déjà protégé par le correctif réseau de cette revue. Rien à refaire
   ici, à condition que le plugin matrix-dart-sdk de VoIP utilisé passe bien par le `Client` déjà
   construit avec le bon `httpClient` (à vérifier à l'implémentation, pas supposé).

## Comportement par défaut tant que ceci n'est pas implémenté et vérifié

Les appels doivent être **désactivés dans l'interface dès que `NetConfig.mode != NetMode.direct`**
(bouton d'appel grisé, message explicite : « Les appels sont désactivés en mode Tor/proxy : le
flux audio/vidéo ne peut pas être protégé par ce mode, voir docs/CALLS_ARCHITECTURE.md »). Ils
restent utilisables en mode direct, où l'IP réelle part de toute façon vers le homeserver (comme
pour tout le reste du trafic, et comme assumé par le mode « direct »).

## Plugin WebRTC à évaluer avant de choisir

Au moment d'implémenter, vérifier dans cet ordre, pour chaque plugin Flutter WebRTC candidat
(`flutter_webrtc` est le plus utilisé avec `matrix-dart-sdk`'s `Voip`) :

- [ ] Expose-t-il `iceTransportPolicy: 'relay'` dans sa configuration `RTCConfiguration` ?
- [ ] Accepte-t-il de fonctionner avec `iceServers` ne contenant QUE des entrées `turns:` (aucun
      `stun:`) sans tenter de résoudre un STUN par défaut en interne ?
- [ ] Peut-on vérifier, par capture réseau (Wireshark/tcpdump sur l'appareil de test), qu'aucun
      paquet STUN ni aucune IP locale n'apparaît dans les candidats ICE échangés quand
      `iceTransportPolicy: 'relay'` est actif ?
- [ ] Permet-il de router ses propres connexions via un proxy SOCKS5, ou documente-t-il clairement
      qu'il ne le permet pas (dans ce cas, avertissement utilisateur obligatoire, voir point 4) ?

## Décisions prises depuis la première version de ce document

- **Port TURNS : 5349, pas 443.** Caddy occupe déjà le port 443 pour Conduit ; démultiplexer les
  deux services sur le même port (par SNI) est possible en théorie mais n'a pas été vérifié dans
  ce dépôt. Voir `scripts/server/coturn/README.md` pour le détail de cet arbitrage et comment le
  revoir si un déploiement a un besoin impératif du 443.
- **Identifiants TURN dynamiques confirmés disponibles** : `matrix-dart-sdk`'s
  `Client.getTurnServer()` existe et retourne un `TurnServerCredentials` (`uris`, `username`,
  `password`, `ttl`) via `GET /_matrix/client/v3/voip/turnServer` — c'est le mécanisme standard
  Matrix, pas une supposition. Conduit le sert à partir de `turn_uris`/`turn_secret`/`turn_ttl`
  dans `conduit.toml` (ajoutés, voir ce fichier) sans jamais exposer `turn_secret` au client.
- **`lib/calls/call_policy.dart` écrit** : construit la configuration ICE (zéro STUN,
  `iceTransportPolicy: 'relay'` forcé, identifiants TURN récupérés via `getTurnServer()`, jamais
  codés en dur) et expose `CallPolicy.isAllowed(mode)`. **Reste volontairement à `false` pour
  `NetMode.tor`/`NetMode.customProxy`** : cette politique ICE est prête côté configuration, mais
  aucune vérification par capture réseau (voir checklist ci-dessus) n'a encore été faite sur un
  plugin WebRTC réel — la politique seule ne suffit pas à activer les appels en toute confiance.

## `flutter_webrtc` + signalisation Matrix VoIP : ce qui est fait, ce qui ne l'est pas

Découverte importante faite en construisant la signalisation : le paquet `matrix` déjà utilisé
par ce projet (`matrix-dart-sdk`) embarque sa propre implémentation complète du VoIP Matrix —
les classes `VoIP`, `CallSession`, `WebRTCDelegate` — qui gère déjà correctement `party_id`, le
versionnage, la résolution de « glare » (deux appareils qui s'appellent en même temps), etc. Une
proposition reçue pendant le développement de cette fonctionnalité réimplémentait à la main
l'envoi des événements `m.call.*` (`lib/calls/services/matrix_voip_signaling.dart` dans cette
proposition, jamais intégré) — avec un bug réel et sérieux : elle appelait `room.sendEvent(content)`
sans jamais préciser le paramètre nommé `type:`, qui vaut par défaut `m.room.message` dans
`matrix-dart-sdk`. Ses événements seraient donc partis comme de simples messages de discussion
chiffrés contenant un `msgtype` non standard — invisibles pour tout client Matrix respectant la
spec, y compris ce SDK lui-même côté réception — jamais comme de vrais événements d'appel. Elle
omettait aussi `party_id` et prétendait gérer la réception des appels alors qu'aucun code de
réception n'y figurait. **Décision retenue : utiliser directement `VoIP`/`CallSession` au lieu de
réimplémenter un protocole déjà normalisé.**

Architecture retenue (voir `lib/calls/services/call_manager.dart` et
`lib/calls/ui/call_session_screen.dart`) :

- `CallManager` construit un unique `VoIP(client, delegate)` aux côtés du `Client` Matrix
  (`main.dart`). `VoIP` s'abonne lui-même à `client.onCallEvents` — aucun routage d'événements à
  faire à la main, dans un sens comme dans l'autre.
- `MurmureWebRTCDelegate.createPeerConnection` est le SEUL point par lequel `CallSession` crée
  réellement une `RTCPeerConnection`, qu'il s'agisse d'un appel sortant ou d'un appel entrant. On
  y ignore délibérément la configuration ICE que `CallSession` calcule elle-même, et on la
  remplace TOUJOURS par celle de `CallPolicy.buildIceConfig` (zéro STUN, `relay` forcé,
  identifiants TURN dynamiques) — fail-closed structurel : si la politique refuse, aucune
  connexion WebRTC n'est créée, point final, quel que soit ce que `CallSession` aurait tenté.
  `CallManager.startCall` vérifie aussi la politique avant même d'envoyer l'invite, pour ne pas
  faire sonner inutilement le correspondant d'un appel qui ne pourra jamais aboutir.
- `CallSessionScreen` ne construit plus rien elle-même : elle affiche les flux que `CallSession`
  lui donne via `onStreamAdd`/`onStreamRemoved`, et pilote l'appel via `session.answer()` /
  `session.reject()` / `session.hangup()`. Écran de sonnerie séparé pour un appel entrant
  (décrocher n'est jamais automatique).
- Bouton d'appel ajouté dans `ChatScreen` (`lib/ui/rooms_screen.dart`) : vérifie
  `CallPolicy.isAllowed(mode)` et affiche un message explicite au lieu d'un échec silencieux si
  l'appel est refusé — cohérent avec le point « Comportement par défaut » ci-dessus.

## Ce qui reste à faire dans ce dépôt

- [x] Déployer un serveur coturn — config fournie dans `scripts/server/coturn/`, port 5349,
      identifiants de courte durée partagés avec Conduit via `turn_secret`. Reste à vérifier en
      conditions réelles (certificat, pare-feu, tag d'image) avant un vrai déploiement, voir le
      README de ce dossier.
- [x] Politique d'appel pure écrite (`lib/calls/call_policy.dart`) : zéro STUN,
      `iceTransportPolicy: 'relay'` forcé, identifiants dynamiques via `getTurnServer()`.
- [x] `flutter_webrtc` intégré, écran d'appel réel (flux local/distant, politique réseau
      respectée, refus visible et explicite hors mode direct).
- [x] Signalisation Matrix VoIP branchée via `VoIP`/`CallSession` (voir section ci-dessus), pas de
      réimplémentation à la main de `m.call.*`.
- [x] Bouton d'appel dans l'UI des conversations.
- [ ] Appels de groupe (`GroupCallSession`) : non implémentés, `handleNewGroupCall` est un no-op
      explicite dans `MurmureWebRTCDelegate` — Murmure ne propose aucune action pour en démarrer.
- [ ] Notification d'appel manqué / sonnerie audible : non implémentées (`handleMissedCall` et
      `playRingtone`/`stopRingtone` sont des no-op documentés dans `call_manager.dart`).
- [ ] **Vérifier par capture réseau (Wireshark/tcpdump) qu'aucun paquet STUN ni IP locale ne fuit
      réellement avec `flutter_webrtc`**, avant de changer `CallPolicy.isAllowed` pour autoriser
      les appels hors mode direct — non fait, et ne doit pas être présenté comme fait avant de
      l'être réellement sur un appareil. C'est la seule étape qui sépare encore ce code de
      « appels activés en mode Tor/proxy », et elle ne peut pas être cochée depuis ce bac à sable.
- [ ] Test réel sur deux appareils (CI ne construit que l'APK/AAB, elle ne lance pas d'appel) : la
      signalisation `VoIP`/`CallSession` et l'application de `CallPolicy` n'ont été vérifiées que
      par la compilation, jamais par un appel effectivement passé entre deux téléphones.
