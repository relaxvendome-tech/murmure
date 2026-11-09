# Mises à jour

**Murmure est distribuée uniquement sur Google Play, et ses mises à jour passent exclusivement
par Google Play.** L'appli ne contient aucun mécanisme d'auto-mise à jour : ni écran « Mises à
jour », ni téléchargement ou installation d'APK, ni permission `REQUEST_INSTALL_PACKAGES`, ni
FileProvider d'installation, ni saveur Gradle séparée.

## Pourquoi

- La policy Google Play interdit à une appli distribuée sur Play de se mettre à jour par un autre
  moyen que Play : `REQUEST_INSTALL_PACKAGES` et l'installation d'un APK téléchargé exposent à un
  refus de publication, voire à la suspension du compte développeur.
- Play vérifie et signe les mises à jour (signature d'application gérée par Google, clé d'envoi
  distincte) : aucune infrastructure de distribution à héberger ni à protéger.
- Moins de surface d'attaque et moins de permissions : pas de chemin de code qui écrit un APK
  téléchargé sur le téléphone, donc rien de plus à effacer lors d'un essuyage de panique.

## Garde-fou

La CI (`.github/workflows/build.yml`, étape « Garde-fou policy Play ») lit le manifeste Android
fusionné de la version release et échoue si `REQUEST_INSTALL_PACKAGES` y apparaît, y compris via
un plugin tiers. Le manifeste principal la retire aussi explicitement (`tools:node="remove"`).

L'APK universel produit par la CI (`app-release.apk`) ne sert qu'à une installation manuelle sur
un appareil de test ; il ne se met pas à jour tout seul.

## Mode discret et icône de l'appli

L'icône et le nom de l'appli dans le tiroir d'applications restent toujours « Murmure ». Une
bascule d'icône vers « Calculatrice » (via `activity-alias`) a été retirée : la policy Google Play
« Impersonation » interdit à une appli de changer son icône ou son nom affichés pour se faire
passer pour une autre, même à titre optionnel. Seul l'écran de verrou interne
(`lib/ui/calculator_lock_screen.dart`, réglage `calc_mode`) peut prendre l'apparence d'une
calculatrice une fois l'appli ouverte.
