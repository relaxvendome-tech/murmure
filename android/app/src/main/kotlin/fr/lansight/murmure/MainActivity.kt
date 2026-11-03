package fr.lansight.murmure

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Activité unique de Murmure.
 *
 * - FLAG_SECURE : pas de capture d'écran, aperçu masqué dans les applis récentes.
 * - Icône et nom de lancement : toujours « Murmure », jamais basculés en « Calculatrice ». Un
 *   canal "fr.lansight.murmure/stealth" existait ici pour faire cette bascule via activity-alias ;
 *   retiré (voir docs/UPDATES.md) car la policy Google Play « Impersonation » interdit qu'une
 *   appli change son icône/nom affichés pour se faire passer pour une autre appli, y compris de
 *   façon optionnelle — seul l'écran de verrou interne (voir CalculatorLockScreen côté Dart) peut
 *   encore prendre l'apparence d'une calculatrice, ce qui reste autorisé (même principe que les
 *   « vault apps » existant légitimement sur le Play Store, dont le listing et l'icône restent
 *   honnêtes). AUCUNE vérification de code PIN ici de toute façon : elle reste en Dart (AppLock,
 *   PBKDF2 + empreinte dans le Keystore), jamais de code en clair dans l'APK.
 */
class MainActivity : FlutterFragmentActivity() {

    private val meshFgChannelName = "fr.lansight.murmure/mesh_fg"
    private val updateChannelName = "fr.lansight.murmure/update"

    // Serveur GATT du maillage Bluetooth hors-ligne (voir MeshGattServer.kt / lib/mesh/mesh.dart).
    // S'enregistre lui-même ses propres canaux (fr.lansight.murmure/mesh_gatt + _incoming) dans son
    // constructeur ; pas de couplage supplémentaire nécessaire ici.
    private var meshGattServer: MeshGattServer? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        meshGattServer = MeshGattServer(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        // Service de premier plan du maillage Bluetooth (voir MeshForegroundService.kt). Piloté
        // uniquement depuis Dart par lib/mesh/mesh_foreground_service.dart, lui-même appelé par
        // lib/mesh/mesh.dart au démarrage/arrêt du scan BLE — jamais démarré d'initiative ici.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, meshFgChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val calcMode = call.argument<Boolean>("calcMode") ?: false
                    try {
                        val intent = Intent(this, MeshForegroundService::class.java)
                            .putExtra(MeshForegroundService.EXTRA_CALC_MODE, calcMode)
                        ContextCompat.startForegroundService(this, intent)
                        result.success(true)
                    } catch (e: Exception) {
                        // Ne jamais faire planter l'appli pour un service d'arrière-plan : le
                        // maillage Bluetooth continue de fonctionner tant que l'appli est au
                        // premier plan même si ce service échoue à démarrer.
                        result.error("MESH_FG", e.message, null)
                    }
                }
                "stop" -> {
                    try {
                        stopService(Intent(this, MeshForegroundService::class.java))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("MESH_FG", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        // Mises à jour (voir lib/update/ et docs/UPDATES.md). Deux méthodes, délibérément
        // minimales : lire la version réellement installée (seule source fiable, voir
        // currentVersionCode ci-dessous), et lancer l'installeur système sur un APK déjà
        // téléchargé ET déjà vérifié par empreinte côté Dart (UpdateChecker.download) — ce canal
        // ne télécharge ni ne vérifie rien lui-même, il se contente de déclencher l'écran
        // d'installation natif, qui fait lui-même la vérification de signature.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "currentVersionCode" -> {
                    try {
                        result.success(currentVersionCode())
                    } catch (e: Exception) {
                        result.error("VERSION", e.message, null)
                    }
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("BAD_ARGS", "path manquant", null)
                    } else {
                        try {
                            installApk(path)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * `getLongVersionCode()` (API 28+) est le seul accesseur correct depuis qu'Android autorise
     * des `versionCode` dépassant ce qu'un `Int` 32 bits peut représenter (le champ `versionCode`
     * historique reste rempli pour compatibilité mais tronqué sur les très grandes valeurs,
     * jamais atteintes par Murmure en pratique, mais autant lire la bonne API dès que possible).
     * `minSdk` de ce dépôt est 26 (voir build.gradle.kts), donc le repli API < 28 reste
     * nécessaire.
     */
    private fun currentVersionCode(): Long {
        val info = packageManager.getPackageInfo(packageName, 0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
    }

    /**
     * Ouvre l'écran d'installation système pour l'APK à [path]. Ne contourne et ne remplace
     * AUCUNE vérification Android : c'est le système, pas ce code, qui refuse l'installation si
     * la signature de cet APK ne correspond pas à celle de l'appli déjà installée — la vraie
     * protection contre un APK malveillant substitué, indépendante de la vérification SHA-256
     * déjà faite côté Dart avant d'arriver jusqu'ici (voir UpdateChecker.download).
     * `FileProvider` (voir AndroidManifest.xml + res/xml/file_paths.xml) est nécessaire depuis
     * l'API 24 : un `Uri` `file://` direct vers un fichier d'appli serait refusé par l'installeur
     * système (autre processus, autre UID).
     */
    private fun installApk(path: String) {
        val file = File(path)
        if (!file.exists()) {
            throw IllegalArgumentException("Fichier introuvable : $path")
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }
}
