package fr.lansight.murmure

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * Serveur GATT Bluetooth Low Energy pour le mode maillé hors-ligne (lib/mesh/mesh.dart côté Dart).
 *
 * Murmure utilise `flutter_blue_plus` pour le rôle "central" (scanner et se connecter aux autres
 * téléphones Murmure), mais ce paquet — comme la quasi-totalité des bibliothèques BLE Flutter —
 * ne pilote pas le rôle "peripheral" (annoncer un service GATT que d'autres peuvent découvrir et
 * lire). Cette classe comble exactement ce manque, en natif, et ne fait QUE transporter des octets
 * déjà chiffrés de bout en bout côté Dart (voir mesh_crypto.dart) : ce code ne voit, ne déchiffre
 * et ne stocke jamais de texte en clair, il ne fait que relayer des paquets opaques.
 *
 * Modèle d'échange, volontairement simple pour rester fiable en natif :
 * - ÉCRITURE (un autre téléphone nous envoie une enveloppe) : transmise telle quelle à Dart via
 *   [EventChannel], qui l'y déchiffre si elle lui est destinée ou la garde pour la relayer.
 * - LECTURE (un autre téléphone récupère ce qu'on transporte pour lui) : on répond avec la
 *   dernière valeur que Dart nous a donnée via [setReadValue] — Dart fait tourner cette valeur
 *   régulièrement parmi sa file d'attente (voir mesh.dart), donc un seul appareil croisé assez
 *   longtemps finit par voir passer toute la file, mais une seule enveloppe à la fois par lecture.
 *   C'est une limite assumée : un vrai protocole de pagination viendrait ensuite si le besoin de
 *   débit s'en fait sentir.
 */
class MeshGattServer(private val context: Context, messenger: BinaryMessenger) {

    companion object {
        private const val TAG = "MeshGattServer"
        private val SERVICE_UUID: UUID = UUID.fromString("5a4d5552-4d55-5245-0000-000000000001")
        private val CHAR_UUID: UUID = UUID.fromString("5a4d5552-4d55-5245-0000-000000000002")

        /// Garde-fou : une enveloppe mesh fait au plus 512 octets (voir mesh.dart). Un appareil qui
        /// enverrait des écritures "préparées" (voir [onCharacteristicWriteRequest]) sans jamais les
        /// exécuter ne doit pas pouvoir faire grossir le tampon de réassemblage indéfiniment (DoS
        /// mémoire) ; marge large pour ne jamais rejeter une écriture légitime.
        private const val MAX_PENDING_WRITE_BYTES = 4096
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var characteristic: BluetoothGattCharacteristic? = null

    @Volatile private var currentReadValue: ByteArray = ByteArray(0)
    private var eventSink: EventChannel.EventSink? = null

    /// Tampon des écritures BLE "préparées" (ATT Prepare Write / Execute Write), par appareil
    /// (adresse MAC). Voir [onCharacteristicWriteRequest]/[onExecuteWriteRequest] pour pourquoi
    /// c'est nécessaire : une seule écriture logique côté Dart peut arriver ici fragmentée en
    /// plusieurs appels de ce callback.
    private val pendingPreparedWrites = mutableMapOf<String, MutableList<Pair<Int, ByteArray>>>()

    private val methodChannel = MethodChannel(messenger, "fr.lansight.murmure/mesh_gatt")
    private val eventChannel = EventChannel(messenger, "fr.lansight.murmure/mesh_gatt_incoming")

    init {
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    try {
                        start()
                        result.success(true)
                    } catch (e: Exception) {
                        Log.w(TAG, "Impossible de démarrer le serveur GATT", e)
                        result.error("GATT_START", e.message, null)
                    }
                }
                "stop" -> {
                    stop()
                    result.success(true)
                }
                "setReadValue" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.error("BAD_ARGS", "bytes manquant", null)
                    } else {
                        currentReadValue = bytes
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                eventSink = sink
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun start() {
        if (gattServer != null) return // déjà démarré

        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            ?: throw IllegalStateException("Bluetooth indisponible sur cet appareil")
        val adapter: BluetoothAdapter = manager.adapter
            ?: throw IllegalStateException("Adaptateur Bluetooth indisponible")
        if (!adapter.isEnabled) throw IllegalStateException("Bluetooth désactivé")

        val char = BluetoothGattCharacteristic(
            CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_READ or BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        characteristic = char

        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(char)

        val server = manager.openGattServer(context, gattCallback)
            ?: throw IllegalStateException("Impossible d'ouvrir le serveur GATT")
        server.addService(service)
        gattServer = server

        val leAdvertiser = adapter.bluetoothLeAdvertiser
            ?: throw IllegalStateException("Cet appareil ne peut pas annoncer de service BLE")
        advertiser = leAdvertiser

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .build()
        // Pas de nom d'appareil ni d'identifiant dans l'annonce : seul l'UUID de service Murmure
        // est visible avant toute connexion, pour ne rien révéler à un observateur qui ne fait
        // que scanner (voir le même principe déjà appliqué côté scan dans mesh.dart).
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(android.os.ParcelUuid(SERVICE_UUID))
            .build()
        leAdvertiser.startAdvertising(settings, data, advertiseCallback)
    }

    @SuppressLint("MissingPermission")
    private fun stop() {
        try {
            advertiser?.stopAdvertising(advertiseCallback)
        } catch (_: Exception) {
        }
        try {
            gattServer?.close()
        } catch (_: Exception) {
        }
        advertiser = null
        gattServer = null
        characteristic = null
        pendingPreparedWrites.clear()
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) {
            Log.w(TAG, "Échec de l'annonce BLE : code $errorCode")
        }
    }

    private val gattCallback = object : BluetoothGattServerCallback() {
        @SuppressLint("MissingPermission")
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            val value = currentReadValue
            val chunk = if (offset <= value.size) value.copyOfRange(offset, value.size) else ByteArray(0)
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, chunk)
        }

        /**
         * Trouvé en audit interne — défaut sérieux, pas cosmétique : cette méthode ignorait
         * jusqu'ici totalement `preparedWrite`/`offset` et transmettait chaque appel de ce
         * callback directement à Dart comme s'il s'agissait toujours d'une enveloppe complète.
         * Or Android déclenche lui-même, de façon transparente et sans que l'application cliente
         * (`flutter_blue_plus`, côté central) n'ait rien demandé de spécial, la procédure "Write
         * Long Characteristic Values" de la spec Bluetooth dès qu'une écriture dépasse le MTU ATT
         * négocié (`mtu` − 3 octets) : la valeur arrive alors fragmentée en plusieurs écritures
         * "préparées" (`preparedWrite = true`, un `offset` croissant à chaque appel), suivies d'un
         * `onExecuteWrite` qui valide (ou annule) l'ensemble. C'est exactement le cas quand la
         * négociation MTU échoue d'un côté ou de l'autre (voir le commentaire sur
         * `requestMtu(517)` dans mesh.dart — déjà documenté comme un cas réel, pas hypothétique :
         * appareil ancien, ou iOS où `requestMtu` n'a pas d'effet garanti) : chaque fragment partait
         * alors ici vers Dart comme une enveloppe à part entière — un message tronqué et
         * injustifiable, jamais reconstitué, que mesh_crypto.dart ne pouvait que rejeter comme
         * corrompu. Le relais échouait donc silencieusement précisément dans le cas que la
         * négociation MTU est censée couvrir en best-effort.
         *
         * Corrigé en accumulant les fragments par appareil jusqu'à [onExecuteWrite], qui les
         * réassemble dans l'ordre des `offset` avant de transmettre l'enveloppe complète.
         */
        @SuppressLint("MissingPermission")
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (preparedWrite) {
                val pending = pendingPreparedWrites.getOrPut(device.address) { mutableListOf() }
                val pendingTotal = pending.sumOf { it.second.size }
                if (pendingTotal + value.size > MAX_PENDING_WRITE_BYTES) {
                    // Garde-fou DoS (voir MAX_PENDING_WRITE_BYTES) : on abandonne ce tampon plutôt
                    // que de le laisser grossir sans borne ; l'enveloppe en cours sera simplement
                    // perdue, comme n'importe quelle écriture déjà rejetée ailleurs dans mesh.dart.
                    pendingPreparedWrites.remove(device.address)
                    if (responseNeeded) {
                        gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                    }
                    return
                }
                pending.add(offset to value)
                if (responseNeeded) {
                    // Spec ATT : la réponse à une Prepare Write Request échoie l'offset et la
                    // valeur reçus, pour que le central puisse vérifier l'intégrité avant d'exécuter.
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                }
                return
            }

            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
            }
            // Transmis à Dart sur le thread principal : setMethodCallHandler/EventChannel ne sont
            // pas thread-safe depuis un callback Bluetooth qui arrive sur un thread binder.
            mainHandler.post {
                eventSink?.success(value)
            }
        }

        /**
         * Valide (ou annule) les écritures "préparées" accumulées pour cet appareil — voir
         * [onCharacteristicWriteRequest]. `execute = false` correspond à une annulation demandée
         * par le central (Cancel Write) : on jette simplement le tampon, rien à transmettre.
         */
        @SuppressLint("MissingPermission")
        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            val chunks = pendingPreparedWrites.remove(device.address)
            if (execute && chunks != null && chunks.isNotEmpty()) {
                val total = chunks.sumOf { it.second.size }
                val assembled = ByteArray(total)
                for ((chunkOffset, bytes) in chunks) {
                    val end = chunkOffset + bytes.size
                    if (chunkOffset < 0 || end > assembled.size) continue // fragment incohérent, ignoré
                    System.arraycopy(bytes, 0, assembled, chunkOffset, bytes.size)
                }
                mainHandler.post {
                    eventSink?.success(assembled)
                }
            }
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
        }

        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            // Chaque échange ponctuel (lecture/écriture simple) est sans état, mais une écriture
            // préparée en cours doit être nettoyée si l'appareil se déconnecte avant d'exécuter ou
            // d'annuler explicitement (sinon fuite mémoire : adresse jamais revue mais tampon
            // jamais libéré) — trouvé en audit interne en ajoutant le réassemblage ci-dessus.
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                pendingPreparedWrites.remove(device.address)
            }
        }
    }
}
