package com.timbertrail.screentimeguardian

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.random.Random

data class P2PPeerInfo(
    val deviceId: String,
    val deviceName: String,
    val platform: String,
    val address: InetAddress?,
    val port: Int,
    val trustStatus: String,
    val lastStatus: String,
    val lastSeenAt: Instant,
    val lastSyncAt: Instant? = null,
    val capabilities: List<String> = emptyList()
)

class P2PTransport(context: Context, private val store: SessionStore) {
    private val appContext = context.applicationContext
    private val nsdManager = appContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val executor = Executors.newCachedThreadPool()
    private val peers = ConcurrentHashMap<String, P2PPeerInfo>()
    private val resolvingServices = ConcurrentHashMap.newKeySet<String>()
    private val lastSyncAttempts = ConcurrentHashMap<String, Long>()
    private var serverSocket: ServerSocket? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    @Volatile private var running = false
    @Volatile var status: String = "P2P 未启动"
        private set
    var onStateChanged: (() -> Unit)? = null

    fun start() {
        if (running) return
        if (!store.p2pSyncEnabled) {
            setStatus("P2P 已关闭")
            return
        }
        running = true
        serverSocket = ServerSocket(0)
        registerBonjourService()
        startBonjourDiscovery()
        executor.execute(::acceptLoop)
        executor.execute(::periodicSyncLoop)
        setStatus("P2P Bonjour 已开启，等待局域网设备")
    }

    fun stop() {
        running = false
        stopBonjourDiscovery()
        unregisterBonjourService()
        serverSocket?.close()
        serverSocket = null
        setStatus("P2P 已关闭")
    }

    fun refresh() {
        stop()
        if (store.p2pSyncEnabled) start()
    }

    fun peersSnapshot(): List<P2PPeerInfo> =
        peers.values.sortedWith(compareByDescending<P2PPeerInfo> { it.lastSeenAt }.thenBy { it.deviceName.lowercase() })

    fun approvePeer(deviceId: String) {
        store.trustPeer(deviceId)
        peers[deviceId]?.let {
            val updated = it.copy(trustStatus = "已同意", lastStatus = "已同意，等待同步")
            peers[deviceId] = updated
            executor.execute { connectAndSync(updated) }
        }
        setStatus("已同意设备，等待同步")
    }

    fun rejectPeer(deviceId: String) {
        store.rejectPeer(deviceId)
        peers[deviceId]?.let {
            peers[deviceId] = it.copy(trustStatus = "已拒绝", lastStatus = "已拒绝")
        }
        setStatus("已拒绝设备")
    }

    fun syncNow(): Int {
        if (!store.p2pSyncEnabled) {
            setStatus("P2P 已关闭")
            return 0
        }
        if (!running) start()

        val knownPeers = peers.values.filter { it.port > 0 }
        if (knownPeers.isEmpty()) {
            setStatus("尚未发现设备，请确认两端配对码一致并在同一局域网")
            return 0
        }

        val trustedPeers = knownPeers.filter { store.isTrusted(it.deviceId) }
        if (trustedPeers.isEmpty()) {
            setStatus("已发现设备，但尚未同意任何同步设备")
            return 0
        }
        trustedPeers.forEach { peer -> executor.execute { connectAndSync(peer) } }
        setStatus("正在同步 ${trustedPeers.size} 台设备")
        return trustedPeers.size
    }

    private fun registerBonjourService() {
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                setStatus("P2P Bonjour 已发布：${serviceInfo.serviceName}")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                setStatus("P2P Bonjour 发布失败：$errorCode")
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) = Unit

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
        }

        registrationListener = listener
        val serviceInfo = NsdServiceInfo().apply {
            serviceName = serviceName()
            serviceType = SERVICE_TYPE
            port = serverSocket?.localPort ?: 0
            setAttribute("device_id", store.deviceId)
            setAttribute("device_name", store.deviceName)
            setAttribute("platform", "android")
            setAttribute("app_version", APP_VERSION)
            setAttribute("pairing_verifier", pairingVerifier())
            setAttribute("tcp_port", port.toString())
            setAttribute("capabilities", SYNC_CAPABILITIES.joinToString(","))
        }
        nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun unregisterBonjourService() {
        val listener = registrationListener ?: return
        registrationListener = null
        try {
            nsdManager.unregisterService(listener)
        } catch (_: Exception) {
        }
    }

    private fun startBonjourDiscovery() {
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (!running || !isStgServiceType(serviceInfo.serviceType)) {
                    return
                }
                resolveBonjourService(serviceInfo)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                if (running && isStgServiceType(serviceInfo.serviceType)) {
                    setStatus("P2P Bonjour 设备离线：${serviceInfo.serviceName}")
                }
            }

            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                setStatus("P2P Bonjour 发现启动失败：$errorCode")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }

        discoveryListener = listener
        nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun stopBonjourDiscovery() {
        val listener = discoveryListener ?: return
        discoveryListener = null
        try {
            nsdManager.stopServiceDiscovery(listener)
        } catch (_: Exception) {
        }
    }

    private fun resolveBonjourService(serviceInfo: NsdServiceInfo) {
        val serviceKey = serviceInfo.serviceName
        if (!resolvingServices.add(serviceKey)) return

        nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                resolvingServices.remove(serviceKey)
                if (running) setStatus("P2P Bonjour 解析失败：$errorCode")
            }

            override fun onServiceResolved(resolvedInfo: NsdServiceInfo) {
                resolvingServices.remove(serviceKey)
                registerPeer(resolvedInfo)
            }
        })
    }

    private fun registerPeer(serviceInfo: NsdServiceInfo) {
        val attributes = serviceInfo.attributes.mapValues { String(it.value, Charsets.UTF_8) }
        val deviceId = attributes["device_id"]?.trim().orEmpty()
        if (deviceId.isEmpty() ||
            deviceId == store.deviceId ||
            store.isRejected(deviceId) ||
            attributes["pairing_verifier"] != pairingVerifier()) {
            return
        }

        val peer = P2PPeerInfo(
            deviceId = deviceId,
            deviceName = attributes["device_name"]?.ifBlank { serviceInfo.serviceName } ?: serviceInfo.serviceName,
            platform = attributes["platform"]?.ifBlank { "unknown" } ?: "unknown",
            address = serviceInfo.host,
            port = serviceInfo.port,
            trustStatus = store.trustStatus(deviceId),
            lastStatus = if (store.isTrusted(deviceId)) "已同意，等待同步" else "待确认",
            lastSeenAt = Instant.now(),
            capabilities = parseCapabilities(attributes["capabilities"])
        )
        store.rememberKnownDevice(
            deviceId = peer.deviceId,
            deviceName = peer.deviceName,
            platform = peer.platform,
            appVersion = attributes["app_version"] ?: "",
            lastSeenAt = peer.lastSeenAt
        )
        peers[deviceId] = peer
        setStatus(if (store.isTrusted(deviceId)) "发现已同意设备：${peer.deviceName}" else "发现待确认设备：${peer.deviceName}")
        if (store.isTrusted(deviceId) && shouldAutoSync(deviceId)) {
            executor.execute { connectAndSync(peer) }
        }
    }

    private fun acceptLoop() {
        while (running) {
            try {
                serverSocket?.accept()?.use { receiveAndReply(it, shouldReply = true) }
            } catch (_: Exception) {
                if (running) Thread.sleep(1000)
            }
        }
    }

    private fun periodicSyncLoop() {
        while (running) {
            Thread.sleep(store.p2pSyncIntervalMinutes.coerceAtLeast(1) * 60_000L)
            if (running) syncNow()
        }
    }

    private fun connectAndSync(peer: P2PPeerInfo) {
        val address = peer.address ?: return
        if (peer.port <= 0 || !store.isTrusted(peer.deviceId)) return
        peers[peer.deviceId] = peer.copy(lastStatus = "正在同步", lastSeenAt = Instant.now())
        notifyChanged()
        try {
            Socket(address, peer.port).use {
                sendSnapshot(it, peer)
                receiveAndReply(it, shouldReply = false)
            }
        } catch (_: Exception) {
            peers[peer.deviceId] = peer.copy(lastStatus = "连接失败", lastSeenAt = Instant.now())
            setStatus("P2P 连接失败，等待下一次 Bonjour 发现")
        }
    }

    private fun receiveAndReply(socket: Socket, shouldReply: Boolean) {
        val input = DataInputStream(socket.getInputStream())
        val length = input.readInt()
        if (length <= 0 || length > MAX_FRAME_BYTES) return
        val body = ByteArray(length)
        input.readFully(body)
        val result = handleEnvelope(JSONObject(String(body, Charsets.UTF_8)), socket.inetAddress)
        if (result.accepted && shouldReply) {
            sendSnapshot(socket, result.senderDeviceId, result.capabilities)
            store.recordPeerSync(result.senderDeviceId, result.capabilities)
        } else if (result.accepted) {
            store.recordPeerSync(result.senderDeviceId, result.capabilities)
        }
    }

    private fun sendSnapshot(socket: Socket, peer: P2PPeerInfo) {
        sendSnapshot(socket, peer.deviceId, peer.capabilities)
    }

    private fun sendSnapshot(socket: Socket, peerDeviceId: String, peerCapabilities: Collection<String>) {
        val since = if (supportsCapability(peerCapabilities, "delta_sync")) store.syncSince(peerDeviceId) else null
        val envelope = encryptSnapshot(store.makeSyncSnapshot(since), peerCapabilities).toString().toByteArray(Charsets.UTF_8)
        DataOutputStream(socket.getOutputStream()).apply {
            writeInt(envelope.size)
            write(envelope)
            flush()
        }
    }

    private fun handleEnvelope(envelope: JSONObject, remoteAddress: InetAddress?): P2PHandleResult {
        if (envelope.optInt("protocol_version") != 1 ||
            envelope.optString("type") != "sync_snapshot" ||
            envelope.optString("sender_device_id") == store.deviceId) {
            return P2PHandleResult.rejected()
        }
        val senderId = envelope.optString("sender_device_id").trim()
        val capabilities = parseCapabilities(envelope.optJSONArray("capabilities"))
        if (senderId.isEmpty()) return P2PHandleResult.rejected()
        if (envelope.optString("pairing_verifier") != pairingVerifier()) {
            setStatus("发现 STG 设备但配对码不一致：${envelope.optString("sender_device_name", senderId)}")
            return P2PHandleResult.rejected(senderId, capabilities)
        }
        registerInboundPeer(envelope, remoteAddress)
        if (!store.isTrusted(senderId)) {
            val rejected = store.isRejected(senderId)
            peers[senderId]?.let {
                peers[senderId] = it.copy(
                    trustStatus = store.trustStatus(senderId),
                    lastStatus = if (rejected) "已拒绝，未同步" else "待确认，未同步",
                    lastSeenAt = Instant.now()
                )
            }
            setStatus(if (rejected) "已拒绝设备尝试同步：${envelope.optString("sender_device_name", senderId)}" else "收到待确认设备请求：${envelope.optString("sender_device_name", senderId)}")
            return P2PHandleResult.rejected(senderId, capabilities)
        }
        val changed = try {
            val plaintext = decryptPayload(envelope.getString("payload"), envelope.optString("payload_encoding", PLAIN_PAYLOAD_ENCODING))
            store.mergeSyncSnapshot(SyncSnapshot.fromJson(JSONObject(String(plaintext, Charsets.UTF_8))))
        } catch (error: Exception) {
            setStatus("P2P 解密或合并失败：${error.message ?: "未知错误"}")
            return P2PHandleResult.rejected(senderId, capabilities)
        }
        val syncedAt = Instant.now()
        peers[senderId]?.let {
            peers[senderId] = it.copy(
                lastStatus = if (changed > 0) "已同步 $changed 条记录" else "无新记录",
                lastSeenAt = syncedAt,
                lastSyncAt = syncedAt,
                capabilities = capabilities.ifEmpty { it.capabilities }
            )
        }
        setStatus(if (changed > 0) "P2P 已同步 $changed 条记录" else "P2P 已连接，无新记录")
        return P2PHandleResult.accepted(senderId, capabilities, changed)
    }

    private fun encryptSnapshot(snapshot: SyncSnapshot, peerCapabilities: Collection<String>): JSONObject {
        val nonce = Random.Default.nextBytes(12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(pairingKey(), "AES"), GCMParameterSpec(128, nonce))
        val payloadEncoding = if (supportsCapability(peerCapabilities, "gzip")) GZIP_PAYLOAD_ENCODING else PLAIN_PAYLOAD_ENCODING
        val plaintext = snapshot.toJson().toString().toByteArray(Charsets.UTF_8)
        val sealed = cipher.doFinal(if (payloadEncoding == GZIP_PAYLOAD_ENCODING) gzip(plaintext) else plaintext)
        val payload = Base64.getEncoder().encodeToString(nonce + sealed)
        return JSONObject()
            .put("protocol_version", 1)
            .put("type", "sync_snapshot")
            .put("sender_device_id", store.deviceId)
            .put("sender_device_name", store.deviceName)
            .put("platform", "android")
            .put("sender_tcp_port", serverSocket?.localPort ?: 0)
            .put("capabilities", org.json.JSONArray(SYNC_CAPABILITIES))
            .put("payload_encoding", payloadEncoding)
            .put("pairing_verifier", pairingVerifier())
            .put("payload", payload)
            .put("sent_at_utc", Instant.now().toString())
    }

    private fun decryptPayload(payload: String, payloadEncoding: String?): ByteArray {
        val combined = Base64.getDecoder().decode(payload)
        val nonce = combined.copyOfRange(0, 12)
        val ciphertext = combined.copyOfRange(12, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(pairingKey(), "AES"), GCMParameterSpec(128, nonce))
        val plaintext = cipher.doFinal(ciphertext)
        return when (payloadEncoding?.trim()?.lowercase().orEmpty()) {
            "", PLAIN_PAYLOAD_ENCODING -> plaintext
            GZIP_PAYLOAD_ENCODING -> gunzip(plaintext)
            else -> throw IllegalArgumentException("不支持的 P2P 载荷编码：$payloadEncoding")
        }
    }

    private fun shouldAutoSync(deviceId: String): Boolean {
        val now = System.currentTimeMillis()
        val lastAttempt = lastSyncAttempts[deviceId]
        if (lastAttempt != null && now - lastAttempt < 60_000L) {
            return false
        }
        lastSyncAttempts[deviceId] = now
        return true
    }

    private fun registerInboundPeer(envelope: JSONObject, remoteAddress: InetAddress?) {
        val senderId = envelope.optString("sender_device_id").trim()
        if (senderId.isEmpty()) return
        val existing = peers[senderId]
        val trust = store.trustStatus(senderId)
        val port = envelope.optInt("sender_tcp_port", existing?.port ?: 0)
        val capabilities = parseCapabilities(envelope.optJSONArray("capabilities"))
        val peer = P2PPeerInfo(
            deviceId = senderId,
            deviceName = envelope.optString("sender_device_name").ifBlank { existing?.deviceName ?: "Unknown device" },
            platform = envelope.optString("platform").ifBlank { existing?.platform ?: "unknown" },
            address = remoteAddress ?: existing?.address,
            port = port,
            trustStatus = trust,
            lastStatus = if (trust == "已同意") existing?.lastStatus ?: "已同意，等待同步" else trust,
            lastSeenAt = Instant.now(),
            lastSyncAt = existing?.lastSyncAt,
            capabilities = capabilities.ifEmpty { existing?.capabilities ?: emptyList() }
        )
        store.rememberKnownDevice(
            deviceId = peer.deviceId,
            deviceName = peer.deviceName,
            platform = peer.platform,
            appVersion = "",
            lastSeenAt = peer.lastSeenAt
        )
        peers[senderId] = peer
        notifyChanged()
    }

    private fun serviceName(): String {
        return "${safeDnsLabel(store.deviceName)}-${store.deviceId.take(6)}"
    }

    private fun isStgServiceType(serviceType: String): Boolean {
        return serviceType.trim().trimEnd('.').equals(SERVICE_TYPE.trimEnd('.'), ignoreCase = true)
    }

    private fun safeDnsLabel(value: String): String {
        val safe = value
            .trim()
            .map { if (it.isLetterOrDigit() || it == '-') it else '-' }
            .joinToString("")
            .trim('-')
            .ifBlank { "stg-device" }
        return safe.take(40).trim('-').ifBlank { "stg-device" }
    }

    private fun pairingKey(): ByteArray =
        MessageDigest.getInstance("SHA-256").digest("STG-P2P-v1:${store.p2pPairingCode}".toByteArray(Charsets.UTF_8))

    private fun pairingVerifier(): String =
        MessageDigest.getInstance("SHA-256")
            .digest("STG-P2P-verify:${store.p2pPairingCode}".toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            .take(16)

    private fun gzip(input: ByteArray): ByteArray {
        val output = ByteArrayOutputStream()
        GZIPOutputStream(output).use { it.write(input) }
        return output.toByteArray()
    }

    private fun gunzip(input: ByteArray): ByteArray {
        val output = ByteArrayOutputStream()
        GZIPInputStream(ByteArrayInputStream(input)).use { it.copyTo(output) }
        return output.toByteArray()
    }

    private fun supportsCapability(capabilities: Collection<String>, capability: String): Boolean =
        capabilities.any { it.equals(capability, ignoreCase = true) }

    private fun parseCapabilities(value: String?): List<String> =
        value
            ?.split(',')
            ?.map { it.trim().lowercase() }
            ?.filter { it.isNotBlank() }
            ?.distinct()
            ?: emptyList()

    private fun parseCapabilities(value: org.json.JSONArray?): List<String> {
        if (value == null) return emptyList()
        return (0 until value.length()).mapNotNull { index ->
            value.optString(index).trim().lowercase().takeIf { it.isNotBlank() }
        }.distinct()
    }

    private fun setStatus(value: String) {
        status = value
        notifyChanged()
    }

    private fun notifyChanged() {
        onStateChanged?.invoke()
    }

    companion object {
        private const val SERVICE_TYPE = "_stg-sync._tcp."
        private const val APP_VERSION = "1.0.9"
        private const val MAX_FRAME_BYTES = 16 * 1024 * 1024
        private const val PLAIN_PAYLOAD_ENCODING = "plain"
        private const val GZIP_PAYLOAD_ENCODING = "gzip"
        val SYNC_CAPABILITIES = listOf(
            "delta_sync",
            "gzip",
            "history_compaction"
        )
    }
}

data class P2PHandleResult(
    val accepted: Boolean,
    val senderDeviceId: String,
    val capabilities: List<String>,
    val changed: Int
) {
    companion object {
        fun accepted(senderDeviceId: String, capabilities: List<String>, changed: Int) =
            P2PHandleResult(true, senderDeviceId, capabilities, changed)

        fun rejected(senderDeviceId: String = "", capabilities: List<String> = emptyList()) =
            P2PHandleResult(false, senderDeviceId, capabilities, 0)
    }
}
