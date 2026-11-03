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

  /// Écrit des octets déchiffrés dans un fichier temporaire et retourne son chemin.
  /// L'appelant DOIT appeler [wipe] dès que la lecture est terminée.
  static Future<File> writeTemp(List<int> bytes, {required String extension}) async {
    final dir = await _dir();
    final name = '${DateTime.now().microsecondsSinceEpoch}.$extension';
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Écrase puis supprime un fichier temporaire.
  static Future<void> wipe(File file) async {
    try {
      final len = await file.length();
      final sink = file.openWrite(mode: FileMode.write);
      const chunk = 64 * 1024;
      var remaining = len;
      final zeros = List<int>.filled(chunk, 0);
      while (remaining > 0) {
        final n = remaining < chunk ? remaining : chunk;
        sink.add(n == chunk ? zeros : zeros.sublist(0, n));
        remaining -= n;
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      // Le fichier peut déjà avoir disparu ; la suppression ci-dessous est la garantie finale.
    }
    try {
      await file.delete();
    } catch (_) {}
  }

  /// Purge tout le cache média : appelée au démarrage (restes d'une lecture interrompue) et lors
  /// de l'effacement d'urgence (panic / contrainte / trop d'erreurs de PIN).
  static Future<void> purgeAll() async {
    final dir = await _dir();
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is File) await wipe(entity);
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
