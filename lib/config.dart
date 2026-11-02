/// Constantes de configuration de Murmure.
///
/// IMPORTANT : aucun secret ne doit jamais figurer ici. Ce fichier est compilé dans l'APK et
/// lisible par quiconque le décompile (comme vu avec `murmure.example.fr` dans la 2.3.0).
library;

/// Préfixe utilisé pour partager un identifiant Matrix par QR/lien (ex. "murmure:@abc:serveur").
const String kIdPrefix = 'murmure:';

/// Jeton d'inscription envoyé au homeserver (`m.login.registration_token`).
/// Public par construction (il part dans la requête HTTP) : ne protège pas un secret,
/// il limite juste la création de comptes en masse. Renouvelable côté serveur sans recompiler
/// l'appli, car NetConfig lit en priorité l'URL ET le jeton depuis les réglages locaux.
const String kDefaultRegistrationToken = '';

/// Taille maximale d'un média envoyé (doit correspondre à CONDUIT_MAX_REQUEST_SIZE côté serveur).
const int kMaxMediaBytes = 50 * 1024 * 1024;

/// Durée avant reverrouillage automatique de l'appli en arrière-plan.
const Duration kRelockAfter = Duration(seconds: 30);
