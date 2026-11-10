package fr.lansight.murmure

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Service de premier plan des appels audio/vidéo (types `microphone`, + `camera` en vidéo).
 *
 * Sans lui, Android (10+, restrictions renforcées en 11/14) coupe micro et caméra d'une appli en
 * arrière-plan ou écran éteint : l'appel reste établi mais plus aucun son/image ne part. Ce
 * service ne fait RIEN par lui-même (aucune capture, aucune donnée) : il maintient seulement le
 * processus en premier plan pendant un appel déclenché par l'utilisateur, via une notification
 * persistante imposée par le système. Démarré/arrêté depuis MainActivity (canal
 * "fr.lansight.murmure/call_fg"), piloté par lib/calls/services/call_foreground_service.dart.
 *
 * OPSEC : en mode discret, notification NEUTRE (« Activité », icône neutre, canal neutre), jamais
 * le nom Murmure ni l'imitation d'une autre appli (policy Play « Impersonation »). L'état du mode
 * discret est reçu en extra, jamais recalculé ici.
 */
class CallForegroundService : Service() {

    companion object {
        private const val NOTIFICATION_ID = 4151 // 4150 = MeshForegroundService
        private const val CHANNEL_HONEST = "murmure_call_fg"
        private const val CHANNEL_CALC = "discreet_call_fg_v1"
        const val EXTRA_CALC_MODE = "calc_mode"
        const val EXTRA_VIDEO = "video"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val calcMode = intent?.getBooleanExtra(EXTRA_CALC_MODE, false) ?: false
        val video = intent?.getBooleanExtra(EXTRA_VIDEO, false) ?: false
        try {
            startForegroundCompat(buildNotification(calcMode), video)
        } catch (e: Exception) {
            // Démarrage refusé par le système (restriction d'arrière-plan, permission) : l'appel
            // continue au premier plan sans ce service ; ne jamais faire planter l'appli.
            stopSelf()
        }
        // START_NOT_STICKY : relancé sans intent, le service ne saurait ni le mode discret ni le
        // type vidéo, et le moteur Dart de l'appel n'est pas recréé avec lui.
        return START_NOT_STICKY
    }

    private fun buildNotification(calcMode: Boolean): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        val channelId = if (calcMode) CHANNEL_CALC else CHANNEL_HONEST
        val title = if (calcMode) "Activité" else "Appel en cours"
        val icon = if (calcMode) R.drawable.ic_stat_neutral else R.mipmap.ic_launcher
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channelName = if (calcMode) "Activité" else "Appel en cours"
            val channel = NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_LOW)
            manager?.createNotificationChannel(channel)
        }
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle(title)
            .setSmallIcon(icon)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .build()
    }

    private fun startForegroundCompat(notification: Notification, video: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Défense en profondeur (le côté Dart ne démarre qu'avec RECORD_AUDIO accordée) : ne
            // jamais demander le type caméra sans CAMERA accordée, sinon SecurityException sur
            // Android 14+ et perte du micro avec.
            var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (video && checkSelfPermission(Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED) {
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
    }
}
