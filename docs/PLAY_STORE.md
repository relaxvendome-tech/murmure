# Fiche Google Play — Murmure (test ouvert)

Textes rédigés à partir du code réel de `lib/`, `android/app/src/main/AndroidManifest.xml` et `scripts/server/`.
Fonctions volontairement ABSENTES (vérifiées par grep, ne pas les annoncer) : notifications de messages
lorsque le processus de l'appli est tué par Android (elles n'existent que tant que l'appli tourne), changement
d'icône de lancement (retiré, voir `UPDATES.md`), mise à jour hors Google Play (retirée : aucune
REQUEST_INSTALL_PACKAGES). Messages éphémères (`lib/ephemeral.dart`), biométrie
(`lib/biometric.dart`, `local_auth`), blocage (`blocked_users_screen.dart`) et notifications sans contenu
(`message_notifier.dart`) existent désormais et sont annoncés.

Vocabulaire interdit : « inviolable », « 100 % sécurisé », « intraçable », « validé par l'ANSSI », « anonyme
garanti ».

## 1. Textes de la fiche

### Nom (≤ 30 caractères)

```
Murmure : messagerie chiffrée
```
(29 caractères)

### Description courte (≤ 80 caractères)

```
Messagerie chiffrée de bout en bout, sans numéro de téléphone ni e-mail.
```
(72 caractères)

### Description complète (≤ 4000 caractères)

```
Murmure est une messagerie chiffrée de bout en bout, fondée sur le protocole ouvert Matrix. Elle se crée sans numéro de téléphone, sans adresse e-mail et sans accès à votre carnet d'adresses.

VERSION DE TEST
Murmure est en test ouvert. Des bugs sont possibles et vos retours sont précieux. Ne l'utilisez pas encore comme seul moyen de communication dans une situation critique.

UN COMPTE SANS DONNÉES PERSONNELLES
• Aucun numéro de téléphone, aucune adresse e-mail demandés.
• L'identifiant est généré aléatoirement sur votre appareil ; vous choisissez seulement un nom affiché.
• Aucune lecture de vos contacts, aucune localisation.
• Murmure n'est lié à aucun serveur imposé : vous renseignez l'adresse du serveur Murmure auquel vous vous connectez (saisie, ou scan d'un QR code fourni par son administrateur). L'inscription demande un jeton d'invitation donné par l'administrateur du serveur.

MESSAGES ET APPELS CHIFFRÉS
• Conversations privées et groupes chiffrés de bout en bout (Matrix, Olm/Megolm).
• Envoi de photos, chiffrées comme les messages.
• Messages éphémères réglables par conversation : ils sont masqués puis supprimés par les appareils Murmure ; ils ne protègent pas d'une capture d'écran.
• Blocage de contacts.
• Notifications sans contenu : « Nouveau message », sans nom ni texte (tant que l'appli tourne).
• Accusés de lecture et indicateur de saisie désactivés par défaut.
• Appels audio et vidéo.
• Vérification des appareils par comparaison d'emojis (SAS) ou d'empreinte, pour confirmer que vous parlez bien à la bonne personne.
• Ajout d'un contact par QR code.
• Base de données locale chiffrée (SQLCipher), clé conservée dans l'Android Keystore.

PROTECTION DE VOTRE APPAREIL
• Verrou par code PIN, avec effacement après trop d'essais erronés. Déverrouillage biométrique optionnel, en complément du code.
• Code de contrainte : s'il est saisi, Murmure efface localement clés, messages et médias, puis se ferme.
• Mode discret optionnel : écran de verrouillage d'apparence calculatrice à l'intérieur de l'application ; l'icône et le nom restent Murmure. Le bon code ouvre Murmure ; ce n'est pas une application cachée.
• Captures d'écran bloquées et aperçu masqué dans les applications récentes.
• Aucune sauvegarde automatique Android des données de l'appli, ni copie lors d'un transfert vers un nouveau téléphone.

RÉSEAU
• Connexion directe, via Tor (avec l'application Orbot) ou via un proxy SOCKS5 personnalisé. En mode Tor ou proxy, Murmure refuse de se connecter en direct plutôt que de revenir silencieusement à votre IP réelle.
• Mode Bluetooth maillé, expérimental : relais de messages chiffrés d'appareil à appareil quand le réseau mobile est indisponible. Portée limitée, fonction en développement, aucune garantie de remise. Un service de premier plan et une notification permanente sont affichés pendant son fonctionnement.

Les mises à jour de Murmure sont distribuées uniquement par Google Play.

CE QUE MURMURE NE FAIT PAS
Murmure protège le contenu des messages mais pas toutes les métadonnées : le serveur voit notamment les identifiants, les salons, les horaires et les tailles des échanges. Aucune application ne supprime tout risque, notamment si votre téléphone est compromis ou si votre interlocuteur est piégé. Murmure est un projet indépendant, sans audit officiel ni certification.

Politique de confidentialité : voir le lien de la fiche.
```
(3397 caractères, recompter après toute modification : limite 4000)

### Notes de version — première release de test (≤ 500 caractères)

```
Première version de test ouverte de Murmure 3.0.
• Comptes sans téléphone ni e-mail
• Messages, groupes, photos et appels audio/vidéo chiffrés de bout en bout (Matrix)
• Vérification des appareils (SAS)
• Verrou PIN (biométrie optionnelle), code de contrainte, mode discret
• Messages éphémères, blocage de contacts
• Modes Tor / proxy SOCKS5
• Relais Bluetooth maillé (expérimental)
Des bugs sont possibles. Signalez-les via le lien de contact de la fiche.
```

## 2. Formulaire « Sécurité des données »

Principe : « collecté » = quitte l'appareil vers le serveur Murmure (exploité par le développeur). Les
données chiffrées de bout en bout dont le serveur ne peut pas lire le contenu restent déclarées par prudence.

| Question | Réponse |
|---|---|
| L'appli collecte ou partage-t-elle des données ? | Oui (collecte), aucun partage avec des tiers |
| Données chiffrées en transit ? | Oui (HTTPS ; Caddy en frontal) |
| Suppression à la demande ? | Oui, **dans l'appli** : Réglages (engrenage) > « Zone dangereuse » > « Supprimer mon compte » désactive le compte sur le serveur et efface localement clés, messages, médias et réglages (voir `SUPPRESSION_COMPTE.md`). Sans accès à l'appli (téléphone perdu, échec de la désactivation serveur) : demande par e-mail, décrite à l'URL de suppression déclarée en section 4. Limite à déclarer : les messages déjà envoyés ne sont pas effacés du serveur par l'appli ni des appareils des correspondants. **À aligner avec la politique de confidentialité.** |
| Infos personnelles : nom, e-mail, ID utilisateur | **Nom** : oui, nom affiché choisi par l'utilisateur (**obligatoire** à la création du compte, pseudonyme libre), fonctionnalité de l'appli, non partagé. **E-mail** : non. **ID utilisateur** : oui, identifiant Matrix aléatoire, fonctionnalité de l'appli + gestion du compte. Adresse/téléphone/autres : non |
| Localisation | Non (ACCESS_FINE_LOCATION n'est déclarée que jusqu'à Android 11, pour le scan BLE ; jamais lue) |
| Contacts, calendrier, appels, SMS | Non |
| Messages (« Messages dans l'appli ») | Oui : messages et photos, **chiffrés de bout en bout** ; le serveur ne stocke que du chiffré, **sauf les réactions emoji** (ligne suivante). Fonctionnalité de l'appli. Non partagé |
| Réactions (emoji) | **Non chiffrées de bout en bout** (événements Matrix `m.reaction`, envoyés en clair dans le salon chiffré) : le serveur voit l'emoji choisi, son auteur, l'horodatage et l'identifiant du message visé (pas le texte de ce message). Fonctionnalité de l'appli. Non partagé. À citer dans la politique de confidentialité et à ne jamais présenter comme chiffré |
| Photos et vidéos | Oui : photos envoyées par l'utilisateur, chiffrées E2E. Fonctionnalité de l'appli. Non partagé |
| Audio | Appels : flux WebRTC chiffré, non enregistré ni stocké. Déclarer « non collecté » (traitement éphémère) |
| Fichiers/docs | Non |
| Activité dans l'appli, historique web | Non (aucun analytique, aucune pub) |
| Infos et performances de l'appli | Non (aucun SDK de plantage ni d'analytique) |
| Identifiants de l'appareil ou autres | Non pour l'ID publicitaire. Le nom d'appareil Matrix (device) est un nom d'affichage de session, à citer dans la politique |
| Adresse IP | Non journalisée : Caddy masque `remote_ip` / `client_ip`, Conduit en `log = "warn"`. L'IP est néanmoins vue techniquement par le serveur pour établir la connexion. Ne pas écrire « jamais vue ». coturn configuré sans aucun journal (`log-file=/dev/null`, `scripts/server/coturn/turnserver.conf`). **À vérifier : journaux du pare-feu/hébergeur** |
| Métadonnées Matrix | Oui, à décrire dans la politique : identifiants, salons, membres, horodatages, tailles, versions d'appareil, réactions emoji (contenu en clair, voir ci-dessus) |
| Publicité, analytique, SDK tiers | Aucun |
| Hébergement | Serveur en France (**à confirmer par l'hébergeur retenu avant publication**) |

Déclarations de cohérence avec la politique de confidentialité (qui n'est pas dans le dépôt : à vérifier) :
pas de numéro, e-mail, contacts, localisation ; ID aléatoire + nom affiché (obligatoire) ; E2E sauf réactions emoji ;
métadonnées Matrix ; suppression du compte dans l'appli ;
IP non journalisée ; serveur en France ; aucune fédération (`allow_federation = false`).

## 3. Permissions du Manifest

| Permission | Justification | Risque Play |
|---|---|---|
| INTERNET, ACCESS_NETWORK_STATE | Connexion au serveur Matrix, état du réseau | Faible |
| BLUETOOTH_SCAN (`neverForLocation`), BLUETOOTH_CONNECT, BLUETOOTH_ADVERTISE | Relais maillé hors réseau (`lib/mesh`) | Moyen : demandées à l'exécution, fonction principale expliquée |
| ACCESS_FINE_LOCATION (`maxSdkVersion=30`) | Scan BLE sur Android ≤ 11, jamais lue | Moyen : localisation, justifier dans le formulaire |
| CAMERA | Scan de QR codes (contacts, serveur), appels vidéo | Faible |
| RECORD_AUDIO, MODIFY_AUDIO_SETTINGS | Appels audio/vidéo | Faible |
| POST_NOTIFICATIONS | Notifications sans contenu (nouveau message, appel manqué/entrant), notification du service Bluetooth. Demandée seulement après la création du compte et le déverrouillage, jamais au premier écran | Faible |
| FOREGROUND_SERVICE, FOREGROUND_SERVICE_CONNECTED_DEVICE | Service Bluetooth maillé en arrière-plan | **Moyen/élevé** : la déclaration du type `connectedDevice` demande une explication et une vidéo de démonstration |
| FOREGROUND_SERVICE_MICROPHONE, FOREGROUND_SERVICE_CAMERA | Service de premier plan `CallForegroundService` (types `microphone`, + `camera` en appel vidéo) : appels VoIP déclenchés par l'utilisateur (il lance ou décroche l'appel). Sans lui, Android coupe micro et caméra dès l'appli en arrière-plan ou l'écran éteint, et l'appel devient muet. Démarré uniquement pendant un appel en cours, arrêté à sa fin, notification persistante « Appel en cours » (neutre « Activité » en mode discret) ; aucune capture hors appel | **Moyen** : la déclaration des types `microphone`/`camera` demande une description et une vidéo (lancer un appel, passer en arrière-plan, la notification, raccrocher) |

Points d'attention :
1. **REQUEST_INSTALL_PACKAGES** : retirée (Murmure n'est distribuée que sur Google Play ; la CI échoue
   si elle réapparaît dans le manifeste fusionné). Plus de risque de refus sur ce point.
2. **Foreground service** : prévoir description + vidéo montrant l'activation du mode Bluetooth, et une
   seconde vidéo pour les types `microphone`/`camera` (appel déclenché par l'utilisateur, passage en
   arrière-plan, notification visible, fin de l'appel).
3. **Notifications en mode discret** : texte neutre (« Rappel — Nouvelle activité. »), sans imitation
   d'une autre appli ; Android affiche de toute façon le nom réel « Murmure » dans l'en-tête
   (`call_opsec_notifier.dart`). Seul l'écran de verrou interne a une apparence de calculatrice, ce que la
   fiche décrit honnêtement.
4. Localisation Android ≤ 11 : le formulaire « Autorisations sensibles » peut demander pourquoi ; réponse :
   exigence technique du scan BLE, aucune donnée de position lue.

## 4. Déclarations Console à prévoir

- **Public cible** : 18 ans et plus uniquement (pas d'attrait pour les enfants, pas de programme « Famille »).
- **Classification du contenu (IARC)** : questionnaire « Messagerie / réseaux sociaux » ; contenu généré par
  les utilisateurs : oui (messages privés) ; partage de localisation : non ; achats : non ; pas de violence
  propre à l'appli. Attendre un PEGI 12 / Teen environ.
- **Contenu généré par les utilisateurs** : prévoir une politique de signalement et de blocage ou l'expliquer
  (serveur privé sur invitation, modération par l'administrateur). Fonction de blocage présente
  (`lib/ui/blocked_users_screen.dart`, accessible depuis le profil) : la citer dans le formulaire.
- **Publicités** : aucune. **Application gouvernementale / financière / santé** : non.
- **Accès à l'appli pour l'examen** : l'appli exige l'adresse d'un serveur et un jeton d'inscription. Fournir
  dans « Instructions d'accès » : URL du serveur, jeton d'inscription, QR code d'onboarding, deux comptes de test
  si possible, et la manière de tester les appels. Sans cela : rejet d'office.
- **Sécurité des données** : section 2. **Politique de confidentialité** : URL publique obligatoire, avec
  section suppression de compte.
- **Suppression de compte** : URL web de demande de suppression (obligatoire pour les comptes créés dans l'appli).
  URL à déclarer : https://github.com/relaxvendome-tech/murmure/blob/main/docs/SUPPRESSION_COMPTE.md
- **Autorisations sensibles / services de premier plan** : formulaire + vidéo (section 3).
- **Chiffrement / export** : mentionner l'usage de chiffrement standard (pas de crypto propriétaire) pour la
  conformité export US ; en France, la fourniture d'un moyen de cryptologie relève de la LCEN (art. 30) et du décret
  2007-663 : vérifier auprès de l'ANSSI si une déclaration est requise ou si une exemption s'applique.
- **Cible API** : targetSdk 36 / compileSdk 36 (exigence Google Play 2026) ; bibliothèques natives alignées
  sur 16 Ko **à partir du correctif qui recompile libolm 3.2.16 en CI** (`scripts/build_libolm.sh`, liée avec
  `-z max-page-size=16384`, remplace `flutter_olm` 2.0.0 dont le `libolm.so` était aligné 4 Ko). Le contrôle
  readelf de la CI bloque toute release Play contenant une `.so` arm64-v8a/x86_64 non alignée : vérifier
  dans le log de la release que « 0 non alignée(s) » est affiché (et ne pas publier un AAB antérieur à ce
  correctif). Fournir l'AAB signé avec la clé d'upload : uniquement l'artefact
  `murmure-release-play` d'un tag `v*` (ou lancement manuel `play_release=true`) ; l'artefact
  `murmure-DEBUG-non-publiable` des builds de `main` est signé debug et refusé par la Console.
- **Test ouvert** : pays, quota, adresse e-mail/URL de retour des testeurs. Compte développeur personnel
  créé après nov. 2023 : 12 testeurs pendant 14 jours en test fermé avant la production (non requis pour le
  test ouvert seul).
- **Usurpation d'identité** : le nom et l'icône restent « Murmure » ; ne rien écrire dans la fiche qui évoque
  Signal, Telegram ou « calculatrice » en tant qu'identité de l'appli.
