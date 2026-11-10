package fr.lansight.murmure

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
    private val callFgChannelName = "fr.lansight.murmure/call_fg"

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
        // Recréation de l'activité : ne jamais laisser tourner un second serveur GATT à côté de
        // l'ancien (voir aussi cleanUpFlutterEngine).
        meshGattServer?.shutdown()
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
                // Version d'Android (API level) : permet à Dart de ne demander la localisation
                // que là où le scan BLE l'exige encore (SDK <= 30, voir mesh_screen.dart).
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                else -> result.notImplemented()
            }
        }
        // Service de premier plan des appels (micro/caméra en arrière-plan, voir
        // CallForegroundService.kt). Piloté uniquement par lib/calls/services/call_foreground_service.dart.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, callFgChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val calcMode = call.argument<Boolean>("calcMode") ?: false
                    val video = call.argument<Boolean>("video") ?: false
                    try {
                        val intent = Intent(this, CallForegroundService::class.java)
                            .putExtra(CallForegroundService.EXTRA_CALC_MODE, calcMode)
                            .putExtra(CallForegroundService.EXTRA_VIDEO, video)
                        ContextCompat.startForegroundService(this, intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("CALL_FG", e.message, null)
                    }
                }
                "stop" -> {
                    try {
                        stopService(Intent(this, CallForegroundService::class.java))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("CALL_FG", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Activité détruite (moteur Flutter détaché) : le code Dart du maillage meurt avec ce moteur,
     * donc plus rien ne pilote le serveur GATT ni le service de premier plan. Corrigé : ils
     * restaient actifs (annonce BLE orpheline + notification persistante) et une recréation de
     * l'activité ouvrait un SECOND serveur GATT. On arrête tout ici.
     */
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        meshGattServer?.shutdown()
        meshGattServer = null
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, meshFgChannelName).setMethodCallHandler(null)
        try {
            stopService(Intent(this, MeshForegroundService::class.java))
        } catch (_: Exception) {
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, callFgChannelName).setMethodCallHandler(null)
        try {
            stopService(Intent(this, CallForegroundService::class.java))
        } catch (_: Exception) {
        }
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
