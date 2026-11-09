# Supprimer son compte et ses données : Murmure

**Application :** Murmure (messagerie chiffrée, Android)
**Développeur :** LanSight
**Contact :** relaxvendome@gmail.com

## Supprimer son compte depuis l'application

1. Ouvrez Murmure et restez sur la liste des conversations.
2. Appuyez sur l'icône en forme d'engrenage (« Réglages ») en haut à droite.
3. L'écran « Verrouillage » s'ouvre.
4. Faites défiler jusqu'à la rubrique « Zone dangereuse ».
5. Appuyez sur « Supprimer mon compte ».
6. Confirmez en appuyant sur « Supprimer ».

L'application se ferme ensuite. Au prochain lancement, elle redémarre comme neuve.

## Ce qui est supprimé

**Sur le serveur :** le compte Matrix est désactivé sur le serveur Murmure auquel vous étiez connecté.

**Sur le téléphone :** sont effacés les clés de chiffrement, la base de données locale (messages, contacts, salons, historique des appels manqués), les photos et fichiers médias reçus ou envoyés et les réglages de l'application (code PIN, mode discret, configuration réseau). La suppression locale est effectuée même si la désactivation sur le serveur échoue. Dans ce cas, le compte peut rester sur le serveur : demandez alors sa suppression par e-mail (voir plus bas).

## Ce qui peut être conservé

- **Côté serveur :** l'application ne demande pas l'effacement des messages déjà envoyés. Les données conservées par le serveur (identifiants, salons, horodatages, tailles des échanges, messages chiffrés) et leur durée de conservation dépendent de la configuration du serveur, que l'application ne contrôle pas. Ce point est à confirmer auprès de l'administrateur du serveur.
- **Chez vos correspondants :** les messages que vous avez envoyés restent sur les appareils de vos interlocuteurs. Murmure ne peut pas les effacer chez eux.
- **Sauvegardes :** Murmure exclut toutes ses données de la sauvegarde automatique Android (cloud) et du transfert vers un nouvel appareil.

## Demander la suppression sans l'application

Si vous ne pouvez plus accéder à l'application (téléphone perdu, application désinstallée, erreur lors de la suppression), écrivez à **relaxvendome@gmail.com** depuis l'adresse de votre choix. Indiquez :

- le nom affiché de votre compte, ou l'identifiant Matrix (de la forme `@identifiant:serveur`) si vous le connaissez ;
- l'adresse du serveur Murmure utilisé, si vous la connaissez ;
- la demande de suppression du compte et de ses données.

Le délai de traitement d'une demande envoyée par e-mail n'est pas fixé par l'application.
