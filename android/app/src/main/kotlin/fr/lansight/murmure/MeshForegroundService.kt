package fr.lansight.murmure

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Service de premier plan du mode Bluetooth maillé.
 *
 * Trouvé en audit interne (pas une proposition externe) : sans ce service, le scan BLE, l'annonce
 * et le relais store-and-forward (lib/mesh/mesh.dart) ne survivaient qu'au temps où l'appli
 * Murmure restait au premier plan — dès l'écran verrouillé ou l'appli mise en arrière-plan,
 * Android peut suspendre ou tuer le processus à tout moment (et le fait en pratique assez vite sur
 * la plupart des appareils, encore plus agressivement sur beaucoup de surcouches constructeur),
 * ce qui coupe silencieusement le relais — alors que c'est exactement l'usage visé (téléphone en
 * poche pendant une manifestation) qui exige qu'il continue sans que l'appli reste à l'écran.
 *
 * Ce service ne fait RIEN par lui-même : il n'ouvre aucune connexion BLE, ne touche à aucune donnée
 * de mesh.dart. Son seul rôle est d'élever la priorité du processus auprès d'Android (empêcher sa
 * suspension) tant que le mode Bluetooth est actif, via une notification persistante — une
 * obligation du système, pas un choix : Android exige qu'un service de premier plan affiche une
 * notification visible tant qu'il tourne, pour que l'utilisateur sache qu'une activité continue en
 * arrière-plan. Démarré/arrêté uniquement depuis MainActivity (voir le canal
 * "fr.lansight.murmure/mesh_fg"), lui-même piloté depuis Dart par
 * lib/mesh/mesh_foreground_service.dart, appelé par lib/mesh/mesh.dart au même moment où le scan
 * BLE démarre/s'arrête.
 *
 * TENSION OPSEC, assumée et traitée comme pour la notification d'appel manqué (voir
 * call_opsec_notifier.dart) : si le mode discret (calculatrice) est actif, afficher une
 * notification persistante disant « Murmure » trahirait le déguisement en permanence, bien plus
 * gravement qu'une notification ponctuelle. [startMesh] reçoit donc l'état du mode discret au
 * moment du démarrage (lu côté Dart, jamais recalculé ici) et choisit un texte et un canal de
 * notification cohérents avec l'identité affichée de l'appli à cet instant — jamais le texte
 * honnête quand la calculatrice est à l'écran.
 *
 * LIMITE HONNÊTE : ni le rendu réel de cette notification sur un appareil physique, ni sa capacité
 * effective à empêcher la suspension du processus sur les surcouches constructeur les plus
 * agressives (certains fabricants tuent les services de premier plan malgré tout, sauf à ce que
 * l'utilisateur désactive manuellement l'optimisation de batterie pour Murmure dans les réglages
 * système — hors de portée de ce code), n'ont été vérifiés sur un appareil réel. Un service de
 * premier plan est le meilleur levier qu'Android documente pour ce besoin, pas une garantie
 * absolue.
 */
class MeshForegroundService : Service() {

    companion object {
        private const val NOTIFICATION_ID = 4144
        private const val CHANNEL_HONEST = "murmure_mesh_fg"
        private const val CHANNEL_CALC = "sys_calc_bg_v1"
        const val EXTRA_CALC_MODE = "calc_mode"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val calcMode = intent?.getBooleanExtra(EXTRA_CALC_MODE, false) ?: false
        startForegroundCompat(buildNotification(calcMode))
        // START_STICKY : si Android tue malgré tout le processus pour récupérer de la mémoire,
        // il retente de le relancer dès que possible — mais sans intent d'origine, donc sans
        // calc_mode connu ; onStartCommand serait alors rappelé avec `intent == null`, géré par le
        // repli `?: false` ci-dessus (texte honnête par défaut plutôt que de deviner). Ce n'est
        // qu'un filet de sécurité : mesh.dart ne dépend pas de ce redémarrage pour fonctionner, son
        // propre état (scan, cliquet) n'est pas recréé automatiquement par ce service.
        return START_STICKY
    }

    private fun buildNotification(calcMode: Boolean): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        val (channelId, title, text) = if (calcMode) {
            Triple(CHANNEL_CALC, "Calculatrice", "Synchronisation des fonctions en arrière-plan")
        } else {
            Triple(CHANNEL_HONEST, "Murmure", "Mode hors-ligne actif (relais Bluetooth)")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channelName = if (calcMode) "Synchronisation arrière-plan" else "Mode hors-ligne"
            val channel = NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_LOW)
            manager?.createNotificationChannel(channel)
        }
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
    }
}
