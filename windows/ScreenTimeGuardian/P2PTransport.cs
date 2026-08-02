using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ScreenTimeGuardian;

internal sealed class P2PTransport : IDisposable
{
    private const int MaxFrameBytes = 16 * 1024 * 1024;
    private const string PlainPayloadEncoding = "plain";
    private const string GzipPayloadEncoding = "gzip";
    internal static readonly string[] SyncCapabilities =
    [
        "delta_sync",
        "gzip",
        "history_compaction"
    ];

    private readonly object gate = new();
    private readonly SessionStore store;
    private readonly JsonSerializerOptions jsonOptions = new(JsonSerializerDefaults.Web);
    private readonly ConcurrentDictionary<string, P2PPeerInfo> peers = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, DateTimeOffset> lastSyncAttempts = new(StringComparer.OrdinalIgnoreCase);
    private CancellationTokenSource? cancellation;
    private TcpListener? tcpListener;
    private BonjourDiscovery? bonjourDiscovery;
    private int tcpPort;
    private string status = "P2P 未启动";

    public P2PTransport(SessionStore store)
    {
        this.store = store;
    }

    public event EventHandler? StateChanged;

    public bool IsRunning
    {
        get
        {
            lock (gate)
            {
                return cancellation is { IsCancellationRequested: false };
            }
        }
    }

    public string Status
    {
        get
        {
            lock (gate)
            {
                return status;
            }
        }
    }

    public IReadOnlyList<P2PPeerInfo> KnownPeers => peers.Values
        .OrderByDescending(peer => peer.LastSeenUtc)
        .ThenBy(peer => peer.DeviceName)
        .ToList();

    public void Start()
    {
        if (!store.Settings.P2PSyncEnabled)
        {
            Stop();
            SetStatus("P2P 同步已关闭");
            return;
        }

        lock (gate)
        {
            if (cancellation is { IsCancellationRequested: false })
            {
                return;
            }
        }

        try
        {
            var listener = new TcpListener(IPAddress.Any, 0);
            listener.Start();
            var cts = new CancellationTokenSource();
            var discovery = new BonjourDiscovery(CreateDiscoveryBeacon, OnBonjourPeerDiscovered, SetStatus);

            lock (gate)
            {
                tcpListener = listener;
                tcpPort = ((IPEndPoint)listener.LocalEndpoint).Port;
                bonjourDiscovery = discovery;
                cancellation = cts;
            }

            _ = Task.Run(() => AcceptLoopAsync(listener, cts.Token));
            discovery.Start(cts.Token);
            _ = Task.Run(() => PeriodicSyncLoopAsync(cts.Token));
            SetStatus($"P2P Bonjour 已启动，监听端口 {tcpPort}");
        }
        catch (Exception ex)
        {
            SetStatus($"P2P 启动失败：{ex.Message}");
        }
    }

    public void Stop()
    {
        CancellationTokenSource? cts;
        TcpListener? listener;
        BonjourDiscovery? discovery;
        lock (gate)
        {
            cts = cancellation;
            listener = tcpListener;
            discovery = bonjourDiscovery;
            cancellation = null;
            tcpListener = null;
            bonjourDiscovery = null;
            tcpPort = 0;
        }

        if (cts is null)
        {
            return;
        }

        try
        {
            cts.Cancel();
            discovery?.Dispose();
            listener?.Stop();
        }
        catch
        {
            // Stopping is best-effort; a cancelled background loop will exit on its own.
        }
        finally
        {
            cts.Dispose();
        }

        SetStatus("P2P 同步已停止");
    }

    public void Restart()
    {
        Stop();
        Start();
    }

    public async Task<int> SyncNowAsync()
    {
        if (!store.Settings.P2PSyncEnabled)
        {
            SetStatus("P2P 同步已关闭");
            return 0;
        }

        if (!IsRunning)
        {
            Start();
        }

        var knownPeers = KnownPeers;
        if (knownPeers.Count == 0)
        {
            SetStatus("尚未发现设备，请确认两端配对码一致并在同一局域网");
            return 0;
        }

        var successes = 0;
        var token = CurrentToken();
        var trustedPeers = knownPeers.Where(peer => peer.PairingMatched && IsTrusted(peer.DeviceId)).ToList();
        if (trustedPeers.Count == 0)
        {
            SetStatus(knownPeers.Any(peer => peer.PairingMatched)
                ? "已发现设备，但尚未同意任何同步设备"
                : "已发现 STG 设备，但配对码不一致");
            return 0;
        }

        foreach (var peer in trustedPeers)
        {
            if (await ConnectAndSyncAsync(peer, token))
            {
                successes++;
            }
        }

        SetStatus(successes > 0 ? $"手动同步完成：{successes} 台设备" : "手动同步失败：没有设备响应");
        return successes;
    }

    public void ApprovePeer(string deviceId)
    {
        if (peers.TryGetValue(deviceId, out var existingPeer) && !existingPeer.PairingMatched)
        {
            existingPeer.LastStatus = "配对码不一致，不能同步";
            SetStatus($"配对码不一致，不能同意该设备：{existingPeer.DeviceName}");
            NotifyChanged();
            return;
        }

        store.TrustPeer(deviceId);
        if (peers.TryGetValue(deviceId, out var peer))
        {
            peer.LastStatus = "已同意，等待同步";
        }

        NotifyChanged();
    }

    public void RejectPeer(string deviceId)
    {
        store.RejectPeer(deviceId);
        if (peers.TryGetValue(deviceId, out var peer))
        {
            peer.LastStatus = "已拒绝";
        }

        NotifyChanged();
    }

    public void Dispose()
    {
        Stop();
    }

    private P2PDiscoveryBeacon CreateDiscoveryBeacon()
    {
        return new P2PDiscoveryBeacon(
            1,
            store.Settings.DeviceId,
            store.Settings.DeviceName,
            "windows",
            "V1.0.9",
            tcpPort,
            PairingVerifier(),
            SyncCapabilities.ToList(),
            DateTimeOffset.UtcNow);
    }

    private void OnBonjourPeerDiscovered(P2PDiscoveryBeacon beacon, IPAddress address)
    {
        if (!IsValidPeer(beacon))
        {
            return;
        }

        var peer = RegisterPeer(beacon, address);
        if (peer.PairingMatched && IsTrusted(peer.DeviceId) && ShouldAutoSync(peer.DeviceId))
        {
            _ = Task.Run(() => ConnectAndSyncAsync(peer, CurrentToken()));
        }
    }

    private async Task AcceptLoopAsync(TcpListener listener, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                var client = await listener.AcceptTcpClientAsync(token);
                _ = Task.Run(async () =>
                {
                    using (client)
                    {
                        await ReceiveAndReplyAsync(client, shouldReply: true, token);
                    }
                }, token);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }
            catch (Exception ex)
            {
                SetStatus($"接收同步连接失败：{ex.Message}");
                await DelayBeforeRetryAsync(token);
            }
        }
    }

    private async Task PeriodicSyncLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            var minutes = Math.Clamp(store.Settings.P2PSyncIntervalMinutes, 1, 1440);
            await DelayAsync(TimeSpan.FromMinutes(minutes), token);
            if (token.IsCancellationRequested || !store.Settings.P2PSyncEnabled)
            {
                break;
            }

            foreach (var peer in KnownPeers.Where(peer => peer.PairingMatched && IsTrusted(peer.DeviceId)))
            {
                await ConnectAndSyncAsync(peer, token);
            }
        }
    }

    private async Task<bool> ConnectAndSyncAsync(P2PPeerInfo peer, CancellationToken token)
    {
        try
        {
            if (!peer.PairingMatched)
            {
                SetPeerStatus(peer.DeviceId, "配对码不一致，不能同步");
                SetStatus($"配对码不一致，不能同步：{peer.DeviceName}");
                return false;
            }

            SetPeerStatus(peer.DeviceId, "正在同步");
            SetStatus($"正在同步 {peer.DeviceName}");
            using var client = new TcpClient();
            await client.ConnectAsync(peer.Address, peer.TcpPort, token);
            await SendSnapshotAsync(client, peer, token);
            await ReceiveAndReplyAsync(client, shouldReply: false, token);
            SetPeerStatus(peer.DeviceId, "同步完成", DateTimeOffset.UtcNow);
            SetStatus($"已同步 {peer.DeviceName}");
            return true;
        }
        catch (EndOfStreamException)
        {
            const string message = "对方未返回同步数据，请确认两端都已同意该设备并使用最新版本";
            SetPeerStatus(peer.DeviceId, $"同步失败：{message}");
            SetStatus($"同步 {peer.DeviceName} 未完成：{message}");
            return false;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            SetPeerStatus(peer.DeviceId, $"同步失败：{ex.Message}");
            SetStatus($"同步 {peer.DeviceName} 失败：{ex.Message}");
            return false;
        }
    }

    private async Task ReceiveAndReplyAsync(TcpClient client, bool shouldReply, CancellationToken token)
    {
        var stream = client.GetStream();
        var body = await ReadFrameAsync(stream, token);
        if (body is null)
        {
            return;
        }

        var result = HandleEnvelope(body, client.Client.RemoteEndPoint as IPEndPoint);
        if (shouldReply && result.Accepted)
        {
            await SendSnapshotAsync(client, result.SenderDeviceId, result.Capabilities, token);
            store.RecordPeerSync(result.SenderDeviceId, result.Capabilities);
        }
        else if (result.Accepted)
        {
            store.RecordPeerSync(result.SenderDeviceId, result.Capabilities);
        }

        if (result.Accepted)
        {
            SetStatus(result.Changed == 0 ? "同步完成：无新增数据" : $"同步完成：合并 {result.Changed} 条记录");
        }
    }

    private async Task SendSnapshotAsync(TcpClient client, P2PPeerInfo peer, CancellationToken token)
    {
        await SendSnapshotAsync(client, peer.DeviceId, peer.Capabilities, token);
    }

    private async Task SendSnapshotAsync(TcpClient client, string? peerDeviceId, IReadOnlyCollection<string> peerCapabilities, CancellationToken token)
    {
        var since = SupportsCapability(peerCapabilities, "delta_sync") && !string.IsNullOrWhiteSpace(peerDeviceId)
            ? store.SyncSince(peerDeviceId)
            : null;
        var envelope = EncryptSnapshot(store.MakeSyncSnapshot(since), peerCapabilities);
        var body = JsonSerializer.SerializeToUtf8Bytes(envelope, jsonOptions);
        var frame = new byte[body.Length + 4];
        BinaryPrimitives.WriteUInt32BigEndian(frame.AsSpan(0, 4), (uint)body.Length);
        body.CopyTo(frame.AsMemory(4));
        await client.GetStream().WriteAsync(frame, token);
    }

    private static async Task<byte[]?> ReadFrameAsync(NetworkStream stream, CancellationToken token)
    {
        var header = new byte[4];
        await stream.ReadExactlyAsync(header, token);
        var length = BinaryPrimitives.ReadUInt32BigEndian(header);
        if (length == 0 || length > MaxFrameBytes)
        {
            return null;
        }

        var body = new byte[length];
        await stream.ReadExactlyAsync(body, token);
        return body;
    }

    private P2PEnvelopeHandleResult HandleEnvelope(byte[] body, IPEndPoint? remoteEndPoint)
    {
        try
        {
            var envelope = JsonSerializer.Deserialize<P2PEncryptedEnvelope>(body, jsonOptions);
            var capabilities = AppSettings.NormalizeCapabilities(envelope?.Capabilities);
            if (envelope is null ||
                envelope.ProtocolVersion != 1 ||
                envelope.Type != "sync_snapshot" ||
                envelope.SenderDeviceId == store.Settings.DeviceId ||
                string.IsNullOrWhiteSpace(envelope.SenderDeviceId))
            {
                return P2PEnvelopeHandleResult.CreateRejected();
            }

            if (envelope.PairingVerifier != PairingVerifier())
            {
                RegisterInboundPeer(envelope, remoteEndPoint, pairingMatched: false);
                SetStatus($"发现 STG 设备但配对码不一致：{envelope.SenderDeviceName}");
                return P2PEnvelopeHandleResult.CreateRejected(envelope.SenderDeviceId, capabilities);
            }

            RegisterInboundPeer(envelope, remoteEndPoint);
            if (!IsTrusted(envelope.SenderDeviceId))
            {
                var rejected = IsRejected(envelope.SenderDeviceId);
                SetPeerStatus(envelope.SenderDeviceId, rejected ? "已拒绝，未同步" : "待确认，未同步");
                SetStatus(rejected
                    ? $"已拒绝设备尝试同步：{envelope.SenderDeviceName}"
                    : $"发现待确认设备：{envelope.SenderDeviceName}");
                return P2PEnvelopeHandleResult.CreateRejected(envelope.SenderDeviceId, capabilities);
            }

            var snapshotBytes = DecryptPayload(envelope.Payload, envelope.PayloadEncoding);
            var snapshot = JsonSerializer.Deserialize<SyncSnapshot>(snapshotBytes, jsonOptions);
            if (snapshot is null)
            {
                return P2PEnvelopeHandleResult.CreateRejected(envelope.SenderDeviceId, capabilities);
            }

            var changed = store.MergeSyncSnapshot(snapshot);
            return P2PEnvelopeHandleResult.CreateAccepted(envelope.SenderDeviceId, capabilities, changed);
        }
        catch (Exception ex) when (ex is JsonException or CryptographicException or FormatException or ArgumentException)
        {
            SetStatus($"同步数据无法解密或解析：{ex.Message}");
            return P2PEnvelopeHandleResult.CreateRejected();
        }
    }

    private P2PEncryptedEnvelope EncryptSnapshot(SyncSnapshot snapshot, IReadOnlyCollection<string> peerCapabilities)
    {
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(snapshot, jsonOptions);
        var payloadEncoding = SupportsCapability(peerCapabilities, "gzip") ? GzipPayloadEncoding : PlainPayloadEncoding;
        if (payloadEncoding == GzipPayloadEncoding)
        {
            plaintext = Gzip(plaintext);
        }

        var nonce = RandomNumberGenerator.GetBytes(12);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[16];
        using var aes = new AesGcm(PairingKey(), 16);
        aes.Encrypt(nonce, plaintext, ciphertext, tag);
        return new P2PEncryptedEnvelope(
            1,
            "sync_snapshot",
            store.Settings.DeviceId,
            store.Settings.DeviceName,
            "windows",
            tcpPort > 0 ? tcpPort : null,
            SyncCapabilities.ToList(),
            payloadEncoding,
            PairingVerifier(),
            Convert.ToBase64String(nonce.Concat(ciphertext).Concat(tag).ToArray()),
            DateTimeOffset.UtcNow);
    }

    private byte[] DecryptPayload(string payload, string? payloadEncoding)
    {
        var combined = Convert.FromBase64String(payload);
        if (combined.Length < 29)
        {
            throw new CryptographicException("加密数据长度不足");
        }

        var nonce = combined[..12];
        var tag = combined[^16..];
        var ciphertext = combined[12..^16];
        var plaintext = new byte[ciphertext.Length];
        using var aes = new AesGcm(PairingKey(), 16);
        aes.Decrypt(nonce, ciphertext, tag, plaintext);
        return (payloadEncoding ?? PlainPayloadEncoding).Trim().ToLowerInvariant() switch
        {
            "" or PlainPayloadEncoding => plaintext,
            GzipPayloadEncoding => Gunzip(plaintext),
            _ => throw new ArgumentException($"不支持的 P2P 载荷编码：{payloadEncoding}")
        };
    }

    private static byte[] Gzip(byte[] input)
    {
        using var output = new MemoryStream();
        using (var gzip = new GZipStream(output, CompressionLevel.Fastest, leaveOpen: true))
        {
            gzip.Write(input);
        }

        return output.ToArray();
    }

    private static byte[] Gunzip(byte[] input)
    {
        using var source = new MemoryStream(input);
        using var gzip = new GZipStream(source, CompressionMode.Decompress);
        using var output = new MemoryStream();
        gzip.CopyTo(output);
        return output.ToArray();
    }

    private static bool SupportsCapability(IEnumerable<string>? capabilities, string capability)
    {
        return AppSettings.NormalizeCapabilities(capabilities)
            .Contains(capability, StringComparer.OrdinalIgnoreCase);
    }

    private P2PPeerInfo RegisterPeer(P2PDiscoveryBeacon beacon, IPAddress address)
    {
        var pairingMatched = beacon.PairingVerifier == PairingVerifier();
        var trust = pairingMatched ? store.TrustStatus(beacon.DeviceId) : "配对码不一致";
        var peer = peers.AddOrUpdate(
            beacon.DeviceId,
            _ => new P2PPeerInfo
            {
                DeviceId = beacon.DeviceId,
                DeviceName = beacon.DeviceName,
                Platform = beacon.Platform,
                AppVersion = beacon.AppVersion,
                Address = address,
                TcpPort = beacon.TcpPort,
                LastSeenUtc = DateTimeOffset.UtcNow,
                PairingMatched = pairingMatched,
                LastStatus = pairingMatched ? trust : "配对码不一致，不能同步",
                Capabilities = AppSettings.NormalizeCapabilities(beacon.Capabilities)
            },
            (_, existing) =>
            {
                existing.DeviceName = beacon.DeviceName;
                existing.Platform = beacon.Platform;
                existing.AppVersion = beacon.AppVersion;
                existing.Address = address;
                existing.TcpPort = beacon.TcpPort;
                existing.LastSeenUtc = DateTimeOffset.UtcNow;
                existing.PairingMatched = pairingMatched;
                existing.Capabilities = AppSettings.NormalizeCapabilities(beacon.Capabilities);
                if (!pairingMatched)
                {
                    existing.LastStatus = "配对码不一致，不能同步";
                }
                else if (existing.LastStatus is "离线" or "待确认" or "已同意" or "已拒绝" or "配对码不一致，不能同步")
                {
                    existing.LastStatus = trust;
                }

                return existing;
            });

        SetStatus(pairingMatched
            ? (IsTrusted(peer.DeviceId) ? $"发现已同意设备：{peer.DeviceName}" : $"发现待确认设备：{peer.DeviceName}")
            : $"发现 STG 设备但配对码不一致：{peer.DeviceName}");
        NotifyChanged();
        return peer;
    }

    private P2PPeerInfo RegisterInboundPeer(P2PEncryptedEnvelope envelope, IPEndPoint? remoteEndPoint, bool pairingMatched = true)
    {
        var deviceId = envelope.SenderDeviceId.Trim();
        var address = remoteEndPoint?.Address ?? IPAddress.None;
        var port = envelope.SenderTcpPort ?? 0;
        var trust = pairingMatched ? store.TrustStatus(deviceId) : "配对码不一致";
        var peer = peers.AddOrUpdate(
            deviceId,
            _ => new P2PPeerInfo
            {
                DeviceId = deviceId,
                DeviceName = string.IsNullOrWhiteSpace(envelope.SenderDeviceName) ? "Unknown device" : envelope.SenderDeviceName,
                Platform = string.IsNullOrWhiteSpace(envelope.Platform) ? "unknown" : envelope.Platform,
                AppVersion = "unknown",
                Address = address,
                TcpPort = port,
                LastSeenUtc = DateTimeOffset.UtcNow,
                PairingMatched = pairingMatched,
                LastStatus = pairingMatched
                    ? (trust == "已同意" ? "已同意，等待同步" : trust)
                    : "配对码不一致，不能同步",
                Capabilities = AppSettings.NormalizeCapabilities(envelope.Capabilities)
            },
            (_, existing) =>
            {
                existing.DeviceName = string.IsNullOrWhiteSpace(envelope.SenderDeviceName) ? existing.DeviceName : envelope.SenderDeviceName;
                existing.Platform = string.IsNullOrWhiteSpace(envelope.Platform) ? existing.Platform : envelope.Platform;
                if (address != IPAddress.None)
                {
                    existing.Address = address;
                }
                if (port > 0)
                {
                    existing.TcpPort = port;
                }
                existing.LastSeenUtc = DateTimeOffset.UtcNow;
                existing.PairingMatched = pairingMatched;
                var capabilities = AppSettings.NormalizeCapabilities(envelope.Capabilities);
                if (capabilities.Count > 0)
                {
                    existing.Capabilities = capabilities;
                }
                if (!pairingMatched)
                {
                    existing.LastStatus = "配对码不一致，不能同步";
                }
                else if (existing.LastStatus is "离线" or "待确认" or "已同意" or "已拒绝" or "待确认，未同步" or "配对码不一致，不能同步")
                {
                    existing.LastStatus = trust == "已同意" ? "已同意，等待同步" : trust;
                }
                return existing;
            });

        NotifyChanged();
        return peer;
    }

    private bool IsValidPeer(P2PDiscoveryBeacon beacon)
    {
        return beacon.ProtocolVersion == 1 &&
            beacon.DeviceId != store.Settings.DeviceId &&
            beacon.TcpPort > 0 &&
            !string.IsNullOrWhiteSpace(beacon.PairingVerifier) &&
            !IsRejected(beacon.DeviceId);
    }

    private bool IsTrusted(string deviceId)
    {
        return store.Settings.TrustedPeerIds.Contains(deviceId, StringComparer.OrdinalIgnoreCase);
    }

    private bool IsRejected(string deviceId)
    {
        return store.Settings.RejectedPeerIds.Contains(deviceId, StringComparer.OrdinalIgnoreCase);
    }

    private bool ShouldAutoSync(string deviceId)
    {
        var now = DateTimeOffset.UtcNow;
        if (lastSyncAttempts.TryGetValue(deviceId, out var lastAttempt) &&
            now - lastAttempt < TimeSpan.FromSeconds(60))
        {
            return false;
        }

        lastSyncAttempts[deviceId] = now;
        return true;
    }

    private void SetPeerStatus(string deviceId, string peerStatus, DateTimeOffset? lastSyncUtc = null)
    {
        if (peers.TryGetValue(deviceId, out var peer))
        {
            peer.LastStatus = peerStatus;
            if (lastSyncUtc is not null)
            {
                peer.LastSyncUtc = lastSyncUtc;
            }

            NotifyChanged();
        }
    }

    private CancellationToken CurrentToken()
    {
        lock (gate)
        {
            return cancellation?.Token ?? CancellationToken.None;
        }
    }

    private byte[] PairingKey()
    {
        return SHA256.HashData(Encoding.UTF8.GetBytes($"STG-P2P-v1:{store.Settings.P2PPairingCode}"));
    }

    private string PairingVerifier()
    {
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"STG-P2P-verify:{store.Settings.P2PPairingCode}")))[..16].ToLowerInvariant();
    }

    private void SetStatus(string value)
    {
        lock (gate)
        {
            status = value;
        }

        NotifyChanged();
    }

    private void NotifyChanged()
    {
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private static async Task DelayBeforeRetryAsync(CancellationToken token)
    {
        await DelayAsync(TimeSpan.FromSeconds(1), token);
    }

    private static async Task DelayAsync(TimeSpan delay, CancellationToken token)
    {
        try
        {
            await Task.Delay(delay, token);
        }
        catch (OperationCanceledException)
        {
        }
    }
}

internal sealed class P2PPeerInfo
{
    public string DeviceId { get; init; } = "";
    public string DeviceName { get; set; } = "";
    public string Platform { get; set; } = "";
    public string AppVersion { get; set; } = "";
    public IPAddress Address { get; set; } = IPAddress.None;
    public int TcpPort { get; set; }
    public DateTimeOffset LastSeenUtc { get; set; }
    public DateTimeOffset? LastSyncUtc { get; set; }
    public bool PairingMatched { get; set; } = true;
    public string LastStatus { get; set; } = "";
    public List<string> Capabilities { get; set; } = [];
    public string Endpoint => $"{Address}:{TcpPort}";
}

internal sealed record P2PDiscoveryBeacon(
    [property: JsonPropertyName("protocol_version")] int ProtocolVersion,
    [property: JsonPropertyName("device_id")] string DeviceId,
    [property: JsonPropertyName("device_name")] string DeviceName,
    [property: JsonPropertyName("platform")] string Platform,
    [property: JsonPropertyName("app_version")] string AppVersion,
    [property: JsonPropertyName("tcp_port")] int TcpPort,
    [property: JsonPropertyName("pairing_verifier")] string PairingVerifier,
    [property: JsonPropertyName("capabilities")] List<string>? Capabilities,
    [property: JsonPropertyName("seen_at_utc")] DateTimeOffset SeenAtUtc);

internal sealed record P2PEncryptedEnvelope(
    [property: JsonPropertyName("protocol_version")] int ProtocolVersion,
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("sender_device_id")] string SenderDeviceId,
    [property: JsonPropertyName("sender_device_name")] string SenderDeviceName,
    [property: JsonPropertyName("platform")] string Platform,
    [property: JsonPropertyName("sender_tcp_port")] int? SenderTcpPort,
    [property: JsonPropertyName("capabilities")] List<string>? Capabilities,
    [property: JsonPropertyName("payload_encoding")] string? PayloadEncoding,
    [property: JsonPropertyName("pairing_verifier")] string PairingVerifier,
    [property: JsonPropertyName("payload")] string Payload,
    [property: JsonPropertyName("sent_at_utc")] DateTimeOffset SentAtUtc);

internal sealed record P2PEnvelopeHandleResult(
    bool Accepted,
    string SenderDeviceId,
    IReadOnlyCollection<string> Capabilities,
    int Changed)
{
    public static P2PEnvelopeHandleResult CreateAccepted(string senderDeviceId, IReadOnlyCollection<string> capabilities, int changed) =>
        new(true, senderDeviceId, capabilities, changed);

    public static P2PEnvelopeHandleResult CreateRejected(string senderDeviceId = "", IReadOnlyCollection<string>? capabilities = null) =>
        new(false, senderDeviceId, capabilities ?? [], 0);
}
