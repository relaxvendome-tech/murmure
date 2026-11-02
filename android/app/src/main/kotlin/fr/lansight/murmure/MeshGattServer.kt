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
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var characteristic: BluetoothGattCharacteristic? = null

    @Volatile private var currentReadValue: ByteArray = ByteArray(0)
    private var eventSink: EventChannel.EventSink? = null

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
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
            }
            // Transmis à Dart sur le thread principal : setMethodCallHandler/EventChannel ne sont
            // pas thread-safe depuis un callback Bluetooth qui arrive sur un thread binder.
            mainHandler.post {
                eventSink?.success(value)
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            // Rien à faire : chaque échange est sans état, une lecture ou une écriture à la fois.
        }
    }
}
