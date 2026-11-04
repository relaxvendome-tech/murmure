import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../network.dart';
import 'update_models.dart';

/// Vérification, téléchargement et installation des mises à jour — voir docs/UPDATES.md pour le
/// format du manifeste et la façon de déployer son propre serveur de mise à jour.
///
/// Trois garanties structurelles, toutes délibérées :
/// 1. Chaque requête réseau (manifeste ET APK) passe par `NetConfig.httpClient()` — exactement le
///    même client que le trafic Matrix, donc le même mode choisi par l'utilisateur (direct, Tor,
///    proxy SOCKS5). Une mise à jour ne doit jamais devenir le seul trafic de l'appli qui ignore
///    ce choix et révèle l'IP réelle.
/// 2. Rien ne se télécharge ni ne s'installe sans un appel explicite depuis l'UI (voir
///    ui/update_screen.dart) : pas de vérification silencieuse en arrière-plan, pas de téléchargement
///    automatique. Dans le contexte visé (téléphone pouvant être saisi), une mise à jour qui
///    déclenche seule du trafic réseau ou un écran d'installation serait une fuite d'OPSEC.
/// 3. L'APK téléchargé est vérifié par SHA-256 contre le manifeste AVANT d'être proposé à
///    l'installeur système — en plus de la vérification de signature qu'Android fait lui-même à
///    l'installation (seule protection réelle contre un APK signé par une clé différente de celle
///    déjà installée ; voir [install] et le commentaire de [UpdateManifest.sha256]).
class UpdateChecker {
  static const _channel = MethodChannel('fr.lansight.murmure/update');

  /// Lu côté natif (`PackageInfo.getLongVersionCode`/`versionCode`) plutôt que codé en dur côté
  /// Dart : c'est la seule source qui ne peut pas diverger de ce qui est réellement installé.
  static Future<int> currentVersionCode() async {
    final v = await _channel.invokeMethod<int>('currentVersionCode');
    if (v == null) {
      throw const UpdateError('Impossible de lire la version actuellement installée');
    }
    return v;
  }

  /// Retourne `null` si aucune mise à jour n'est configurée ([NetConfig.updateManifestUrl] vide)
  /// ou si l'appli est déjà à jour — jamais une erreur dans ces deux cas, qui sont des états
  /// normaux, pas des échecs.
  static Future<UpdateCheckResult?> check() async {
    final net = await NetConfig.load();
    final urlStr = net.updateManifestUrl;
    if (urlStr == null || urlStr.isEmpty) return null;
    final uri = Uri.tryParse(urlStr);
    if (uri == null || !uri.hasScheme || uri.scheme != 'https') {
      throw const UpdateError('URL de mise à jour invalide (doit être en https://)');
    }
    final client = await net.httpClient();
    try {
      final resp = await client.get(uri).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        throw UpdateError('Le serveur de mise à jour a répondu ${resp.statusCode}');
      }
      Map<String, dynamic> json;
      try {
        json = jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (_) {
        throw const UpdateError('Réponse du serveur de mise à jour illisible (pas du JSON)');
      }
      final manifest = UpdateManifest.fromJson(json);
      final current = await currentVersionCode();
      if (manifest.versionCode <= current) return null; // déjà à jour
      final mandatory = manifest.minSupportedVersionCode != null && current < manifest.minSupportedVersionCode!;
      return UpdateCheckResult(manifest: manifest, mandatory: mandatory);
    } on FormatException catch (e) {
      throw UpdateError('Manifeste de mise à jour invalide : ${e.message}');
    } finally {
      client.close();
    }
  }

  /// Taille maximale acceptée pour un APK téléchargé (300 Mo, largement au-dessus de ce qu'une
  /// appli comme Murmure peut raisonnablement produire). Trouvé en audit interne : rien ne bornait
  /// avant ce correctif la taille du corps de réponse lu dans la boucle ci-dessous — un serveur de
  /// mise à jour mal configuré, compromis, ou un manifeste pointant par erreur vers une URL qui ne
  /// sert pas un APK (ex. redirigée vers une page ou un flux sans fin) aurait fait grossir le
  /// tampon en mémoire sans limite jusqu'à épuisement de la RAM — un modèle de menace pertinent ici
  /// (téléphones d'occasion ou d'entrée de gamme, voir le reste du threat model du projet), pas
  /// seulement une négligence académique. Vérifiée à chaque fragment reçu (pas seulement sur
  /// `Content-Length`, qu'un serveur peut omettre ou mentir) : fail closed, comme le reste de ce
  /// mécanisme (voir la vérification SHA-256 plus bas).
  static const _maxApkBytes = 300 * 1024 * 1024;

  /// Télécharge l'APK annoncé par [manifest] (via le même client réseau que [check]), vérifie son
  /// empreinte SHA-256 EN MÉMOIRE, puis seulement si elle correspond, écrit le fichier à son
  /// emplacement final et le retourne. En cas d'empreinte différente, [UpdateError] est levée sans
  /// qu'aucun octet n'ait jamais été écrit sur le disque — rien à supprimer, rien à nettoyer : un
  /// APK non vérifié n'existe à aucun moment ailleurs qu'en mémoire, pas même temporairement.
  static Future<File> download(UpdateManifest manifest, {void Function(double progress)? onProgress}) async {
    final net = await NetConfig.load();
    final client = await net.httpClient();
    try {
      final req = http.Request('GET', manifest.apkUrl);
      final streamed = await client.send(req);
      if (streamed.statusCode != 200) {
        throw UpdateError('Téléchargement de la mise à jour échoué (${streamed.statusCode})');
      }
      final total = streamed.contentLength;
      // `BytesBuilder` (pas `List<int>` + `addAll`, utilisé avant ce correctif) : un `List<int>`
      // construit ainsi garde chaque octet comme un élément de tableau de la taille d'un mot
      // machine (8 octets sur la quasi-totalité des téléphones Android actuels, 64 bits) au lieu
      // d'un seul octet réellement nécessaire — un APK de 50 Mo (taille courante pour ce genre
      // d'appli) aurait donc fait gonfler ce tampon jusqu'à environ 400 Mo en mémoire, bien avant
      // tout calcul de SHA-256. `BytesBuilder` garde un `Uint8List` interne, un octet par octet.
      final received = BytesBuilder(copy: false);
      var sum = 0;
      await for (final chunk in streamed.stream) {
        sum += chunk.length;
        if (sum > _maxApkBytes) {
          throw UpdateError(
            'Téléchargement de la mise à jour interrompu : taille reçue au-delà du plafond de '
            '${_maxApkBytes ~/ (1024 * 1024)} Mo. Serveur de mise à jour mal configuré ou URL '
            'incorrecte dans le manifeste — installation refusée.',
          );
        }
        received.add(chunk);
        if (total != null && total > 0 && onProgress != null) {
          onProgress(sum / total);
        }
      }
      final bytes = received.toBytes();
      final digest = await Sha256().hash(bytes);
      final hex = digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (hex != manifest.sha256) {
        throw UpdateError(
          'Empreinte de l\'APK téléchargé incorrecte (attendu ${manifest.sha256}, obtenu $hex) — '
          'téléchargement corrompu ou manifeste erroné. Installation refusée.',
        );
      }
      final dir = await getApplicationSupportDirectory();
      final updatesDir = Directory(p.join(dir.path, 'updates'));
      await updatesDir.create(recursive: true);
      final file = File(p.join(updatesDir.path, 'murmure-${manifest.versionCode}.apk'));
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } finally {
      client.close();
    }
  }

  /// Lance l'installeur système Android pour [apk] (voir MainActivity.kt : `FileProvider` +
  /// `Intent.ACTION_VIEW`). C'est Android, pas ce code, qui refuse l'installation si la signature
  /// de cet APK ne correspond pas à celle déjà installée — la vraie protection de dernier
  /// recours, indépendante de la vérification SHA-256 faite dans [download].
  static Future<void> install(File apk) async {
    try {
      await _channel.invokeMethod<void>('installApk', {'path': apk.path});
    } on PlatformException catch (e) {
      throw UpdateError('Impossible de lancer l\'installation : ${e.message}');
    }
  }
}
