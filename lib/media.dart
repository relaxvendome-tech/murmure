import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Gestion des fichiers temporaires de médias (images, vidéos déchiffrés pour lecture).
///
/// Threat model « saisie de téléphone » : un média déchiffré ne doit jamais rester en clair plus
/// longtemps que nécessaire, et jamais dans la galerie ou les Téléchargements. Chaque fichier est
/// écrasé avant suppression (la suppression seule laisse les données sur le disque flash jusqu'à
/// réécriture par le système — l'écrasement réduit la fenêtre d'exposition, sans garantie absolue
/// sur SSD avec wear-leveling, ce qu'aucune appli ne peut garantir).
///
/// Suite à la revue croisée IA (« niveau Telegram/Signal ») notant l'absence d'envoi de
/// photo/vidéo : implémenté ici pour la partie photo (voir `ChatScreen._pickAndSendImage` dans
/// `lib/ui/rooms_screen.dart`), avec [stripExifAndReencode] appelée AVANT tout chiffrement/envoi —
/// jamais après, jamais côté serveur ou destinataire — conformément au threat model documenté
/// ci-dessus : une photo prise par l'appareil embarque typiquement des métadonnées EXIF
/// (coordonnées GPS, horodatage précis, modèle de l'appareil) qui survivraient telles quelles au
/// chiffrement de bout en bout sinon.
class MediaCache {
  static Future<Directory> _dir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'murmure_media'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Écritures en cours (voir [purgeAll]) : chacune s'enregistre ici avant d'écrire sur le disque
  /// et se désenregistre une fois le fichier complet, pour que [purgeAll] puisse attendre leur fin
  /// plutôt que de risquer de les manquer.
  static final Set<Completer<void>> _activeWrites = {};

  /// Non nul pendant [purgeAll] : toute nouvelle écriture attend la fin de la purge avant de
  /// commencer, pour ne jamais créer un fichier juste après le passage qui doit l'effacer.
  static Completer<void>? _purging;

  /// Écrit des octets déchiffrés dans un fichier temporaire et retourne son chemin.
  /// L'appelant DOIT appeler [wipe] dès que la lecture est terminée.
  ///
  /// Trouvé en audit interne (course avec l'effacement d'urgence) : [purgeAll] énumère le
  /// répertoire UNE SEULE FOIS et n'écrase que les fichiers déjà présents à cet instant. Un appel
  /// à cette méthode dont l'écriture (`writeAsBytes`) n'était pas encore terminée — ou pas encore
  /// commencée — au moment de cette énumération n'était jamais vu par [purgeAll] : le fichier
  /// temporaire, contenant des octets DÉCHIFFRÉS en clair (une photo/vidéo tout juste ouverte dans
  /// l'appli au moment où l'utilisateur déclenche le code de contrainte, par exemple), pouvait donc
  /// survivre intact à un effacement de panique censé faire disparaître « clés, messages et
  /// médias » du téléphone. Chaque écriture s'enregistre maintenant dans [_activeWrites] avant de
  /// commencer et attend la fin d'une purge déjà en cours ([_purging]) avant même d'essayer : une
  /// purge ne peut donc jamais être doublée d'une écriture qui lui échappe, dans aucun des deux
  /// sens.
  static Future<File> writeTemp(List<int> bytes, {required String extension}) async {
    while (_purging != null) {
      await _purging!.future;
    }
    final done = Completer<void>();
    _activeWrites.add(done);
    try {
      final dir = await _dir();
      final name = '${DateTime.now().microsecondsSinceEpoch}.$extension';
      final file = File(p.join(dir.path, name));
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } finally {
      _activeWrites.remove(done);
      done.complete();
    }
  }

  /// Écrase puis supprime un fichier temporaire.
  static Future<void> wipe(File file) async {
    RandomAccessFile? raf;
    try {
      // Longueur lue AVANT l'ouverture : FileMode.write tronquerait le fichier à 0 (les blocs
      // d'origine seraient libérés sans être écrasés). FileMode.append ne tronque pas ; avec
      // setPosition(0), l'écriture se fait en place sur les blocs existants.
      final len = await file.length();
      raf = await file.open(mode: FileMode.append);
      await raf.setPosition(0);
      const chunk = 64 * 1024;
      var remaining = len;
      final zeros = Uint8List(chunk);
      while (remaining > 0) {
        final n = remaining < chunk ? remaining : chunk;
        await raf.writeFrom(zeros, 0, n);
        remaining -= n;
      }
      await raf.flush();
    } catch (_) {
      // Le fichier peut déjà avoir disparu ; la suppression ci-dessous est la garantie finale.
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
    try {
      await file.delete();
    } catch (_) {}
  }

  /// Purge tout le cache média : appelée au démarrage (restes d'une lecture interrompue) et lors
  /// de l'effacement d'urgence (panic / contrainte / trop d'erreurs de PIN).
  ///
  /// Voir le commentaire de [writeTemp] : bloque d'abord toute NOUVELLE écriture ([_purging]), puis
  /// attend que celles déjà en cours ([_activeWrites]) se terminent — donc que leur fichier existe
  /// bel et bien sur le disque — avant d'énumérer le répertoire une seule fois et de tout écraser.
  /// Une écriture qui commence pendant la purge attend que celle-ci se termine (voir [writeTemp])
  /// et crée donc son fichier APRÈS, jamais pendant : aucune fenêtre où un fichier déchiffré en
  /// clair existe sans qu'il soit, soit déjà vu par cette énumération, soit encore non créé.
  static Future<void> purgeAll() async {
    final purge = Completer<void>();
    _purging = purge;
    try {
      await Future.wait(_activeWrites.map((c) => c.future));
      final dir = await _dir();
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is File) await wipe(entity);
      }
    } finally {
      // `identical` plutôt qu'une simple affectation : si un second appel concurrent à [purgeAll]
      // a entre-temps remplacé [_purging] par SON propre verrou (ex. la purge de démarrage et un
      // effacement d'urgence qui se chevauchent), cet appel-ci ne doit relâcher que SON verrou,
      // jamais celui de l'autre — sinon une écriture pourrait démarrer alors que l'autre purge,
      // elle, est encore en train d'énumérer le répertoire.
      if (identical(_purging, purge)) _purging = null;
      purge.complete();
    }
  }
}

/// Alias pour compatibilité avec le nom utilisé dans main.dart (`purgeMediaCache`).
Future<void> purgeMediaCache() => MediaCache.purgeAll();

/// Redécode [bytes] puis les réencode en JPEG, en repartant d'un [img.ExifData] neuf plutôt que de
/// compter sur un éventuel `clear()` partiel de l'EXIF décodé : une instance fraîchement construite
/// est vide par construction (aucune ambiguïté sur ce qu'elle contient encore), donc aucune
/// coordonnée GPS, horodatage ou identifiant d'appareil du fichier d'origine ne peut survivre dans
/// la sortie. Toujours réencodée en JPEG quel que soit le format d'entrée reconnu par
/// `package:image` (PNG, WebP, etc. embarquent aussi des chunks de métadonnées propres au format,
/// pas seulement de l'EXIF) : repartir d'un format de sortie unique et simple évite d'avoir à
/// auditer séparément le comportement de chaque encodeur pour chaque format source.
///
/// Lève [FormatException] si [bytes] n'est pas reconnu comme une image par `package:image` —
/// l'appelant doit alors refuser l'envoi plutôt que d'envoyer les octets bruts non vérifiés.
Uint8List stripExifAndReencode(Uint8List bytes, {int quality = 90}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('Image illisible : format non reconnu.');
  }
  decoded.exif = img.ExifData();
  return Uint8List.fromList(img.encodeJpg(decoded, quality: quality));
}
