package fr.lansight.murmure

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
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
 * - Canal "fr.lansight.murmure/stealth" : bascule de l'icône (Murmure <-> Calculatrice) par
 *   activity-alias. AUCUNE vérification de code PIN ici : elle reste en Dart (AppLock, PBKDF2 +
 *   empreinte dans le Keystore), jamais de code en clair dans l'APK.
 *
 * MainActivity n'a PAS d'intent-filter LAUNCHER : seules les deux alias en ont un.
 * On n'active/désactive QUE les alias. Désactiver MainActivity rendrait l'appli impossible à lancer
 * (un alias dont la cible est désactivée ne démarre plus).
 */
class MainActivity : FlutterFragmentActivity() {

    private val channelName = "fr.lansight.murmure/stealth"
    private val meshFgChannelName = "fr.lansight.murmure/mesh_fg"
    private val aliasDefault get() = ComponentName(this, "$packageName.DefaultAlias")
    private val aliasCalculator get() = ComponentName(this, "$packageName.CalculatorAlias")

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "setStealth" -> {
                    val enabled = call.argument<Boolean>("enabled")
                    if (enabled == null) {
                        result.error("BAD_ARGS", "enabled manquant", null)
                    } else {
                        try {
                            setStealth(enabled)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ALIAS", e.message, null)
                        }
                    }
                }
                "isStealth" -> result.success(isStealth())
                else -> result.notImplemented()
            }
        }
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
    }

    /** Active d'abord le nouvel alias, puis désactive l'ancien : jamais zéro icône. */
    private fun setStealth(enabled: Boolean) {
        val on = if (enabled) aliasCalculator else aliasDefault
        val off = if (enabled) aliasDefault else aliasCalculator
        packageManager.setComponentEnabledSetting(
            on, PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
        packageManager.setComponentEnabledSetting(
            off, PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
    }

    private fun isStealth(): Boolean =
        packageManager.getComponentEnabledSetting(aliasCalculator) ==
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
}
