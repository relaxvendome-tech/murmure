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
 * « Murmure » quand le mode discret est actif, mais jamais non plus l'identité d'une autre appli
 * (texte et icône neutres, voir buildNotification).
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
        private const val NOTIFICATION_ID = 4150 // 4143-4146 pris (appels, messages, maillage)
        private const val CHANNEL_HONEST = "murmure_mesh_fg"
        // Mode discret : canal NEUTRE (un nom de canal est figé à sa création, d'où un nouvel id).
        // Remplace "sys_calc_bg_v1" (canal « Calculatrice »), supprimé dans buildNotification().
        private const val CHANNEL_CALC = "discreet_fg_v2"
        private val LEGACY_CHANNELS = listOf("sys_calc_bg_v1")
        const val EXTRA_CALC_MODE = "calc_mode"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val calcMode = intent?.getBooleanExtra(EXTRA_CALC_MODE, false) ?: false
        startForegroundCompat(buildNotification(calcMode))
        // START_NOT_STICKY (corrigé, était START_STICKY) : si Android tue le processus, il ne
        // relance PAS ce service. Le relancer ne servait à rien (le moteur Dart qui pilote le scan
        // n'est pas recréé avec lui) et était dangereux : relancé sans intent, calc_mode était
        // inconnu et la notification retombait sur « Murmure », trahissant le mode discret.
        return START_NOT_STICKY
    }

    private fun buildNotification(calcMode: Boolean): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        // Trouvé en audit interne : titre et texte étaient bien adaptés au mode discret, mais
        // `setSmallIcon` restait figé sur `ic_launcher` (le logo Murmure) dans les deux cas. Cette
        // icône s'affiche en permanence dans la barre d'état ET dans le panneau de notifications
        // tant que le service tourne — exactement la trahison visuelle permanente que ce fichier
        // documente plus haut comme la TENSION OPSEC à éviter.
        //
        // POLICY PLAY « USURPATION » (corrigé) : le mode discret affichait « Calculatrice » avec
        // R.mipmap.ic_calculator, c.-à-d. se faisait passer pour une AUTRE appli — interdit par la
        // policy Google Play « Impersonation », même optionnel (même raisonnement que le retrait de
        // l'activity-alias, voir MainActivity.kt). Désormais : texte NEUTRE (« Activité en
        // arrière-plan » / « Nouvelle activité. ») et petite icône monochrome neutre
        // (res/drawable/ic_stat_neutral.xml), ni logo Murmure ni imitation d'une autre appli.
        val (channelId, title, text, icon) = if (calcMode) {
            Quadruple(CHANNEL_CALC, "Activité en arrière-plan", "Nouvelle activité.", R.drawable.ic_stat_neutral)
        } else {
            Quadruple(CHANNEL_HONEST, "Murmure", "Mode hors-ligne actif (relais Bluetooth)", R.mipmap.ic_launcher)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Anciens canaux « Calculatrice » : supprimés (best-effort, sans effet s'ils n'existent
            // pas). Leur nom resterait sinon visible dans Réglages > Notifications.
            for (legacy in LEGACY_CHANNELS) {
                try {
                    manager?.deleteNotificationChannel(legacy)
                } catch (_: Exception) {
                }
            }
            val channelName = if (calcMode) "Activité en arrière-plan" else "Mode hors-ligne"
            val channel = NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_LOW)
            manager?.createNotificationChannel(channel)
        }
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(icon)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private data class Quadruple<A, B, C, D>(val first: A, val second: B, val third: C, val fourth: D)

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
