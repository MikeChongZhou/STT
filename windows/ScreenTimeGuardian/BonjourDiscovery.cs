using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;

namespace ScreenTimeGuardian;

internal sealed class BonjourDiscovery : IDisposable
{
    private const int MdnsPort = 5353;
    private const ushort TypeA = 1;
    private const ushort TypePtr = 12;
    private const ushort TypeTxt = 16;
    private const ushort TypeSrv = 33;
    private const ushort TypeAny = 255;
    private const ushort ClassIn = 1;
    private const string ServiceType = "_stg-sync._tcp.local.";
    private static readonly IPAddress MdnsAddress = IPAddress.Parse("224.0.0.251");

    private readonly Func<P2PDiscoveryBeacon> beaconFactory;
    private readonly Action<P2PDiscoveryBeacon, IPAddress> onPeerDiscovered;
    private readonly Action<string> onStatus;
    private readonly ConcurrentDictionary<string, BonjourServiceState> serviceStates = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, IPAddress> hostAddresses = new(StringComparer.OrdinalIgnoreCase);
    private readonly object socketGate = new();

    private UdpClient? udp;
    private string instanceName = "";
    private string hostName = "";

    public BonjourDiscovery(
        Func<P2PDiscoveryBeacon> beaconFactory,
        Action<P2PDiscoveryBeacon, IPAddress> onPeerDiscovered,
        Action<string> onStatus)
    {
        this.beaconFactory = beaconFactory;
        this.onPeerDiscovered = onPeerDiscovered;
        this.onStatus = onStatus;
    }

    public void Start(CancellationToken token)
    {
        lock (socketGate)
        {
            if (udp is not null)
            {
                return;
            }

            var socket = new UdpClient(AddressFamily.InterNetwork);
            socket.ExclusiveAddressUse = false;
            socket.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            socket.Client.Bind(new IPEndPoint(IPAddress.Any, MdnsPort));
            socket.JoinMulticastGroup(MdnsAddress);
            socket.MulticastLoopback = true;
            socket.Ttl = 255;
            udp = socket;
        }

        UpdateNames();
        _ = Task.Run(() => ReceiveLoopAsync(token), token);
        _ = Task.Run(() => AnnounceLoopAsync(token), token);
    }

    public void Dispose()
    {
        lock (socketGate)
        {
            udp?.Dispose();
            udp = null;
        }
    }

    private async Task ReceiveLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            UdpReceiveResult result;
            try
            {
                var socket = CurrentSocket();
                if (socket is null)
                {
                    return;
                }

                result = await socket.ReceiveAsync(token);
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
                onStatus($"Bonjour 接收失败：{ex.Message}");
                await DelayAsync(TimeSpan.FromSeconds(1), token);
                continue;
            }

            ProcessMessage(result.Buffer, result.RemoteEndPoint.Address);
        }
    }

    private async Task AnnounceLoopAsync(CancellationToken token)
    {
        await DelayAsync(TimeSpan.FromMilliseconds(300), token);
        while (!token.IsCancellationRequested)
        {
            try
            {
                await SendQueryAsync();
                await SendAnnouncementAsync();
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                onStatus($"Bonjour 发布失败：{ex.Message}");
            }

            await DelayAsync(TimeSpan.FromSeconds(10), token);
        }
    }

    private void ProcessMessage(byte[] data, IPAddress remoteAddress)
    {
        if (!DnsMessage.TryParse(data, out var message))
        {
            return;
        }

        if (!message.IsResponse && message.Questions.Any(IsQuestionForThisService))
        {
            _ = SendAnnouncementAsync();
        }

        var changedInstances = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var record in message.Records)
        {
            if (record.Type == TypePtr &&
                IsSameName(record.Name, ServiceType) &&
                !string.IsNullOrWhiteSpace(record.TargetName))
            {
                var state = serviceStates.GetOrAdd(record.TargetName, name => new BonjourServiceState(name));
                state.LastSeenAt = DateTimeOffset.UtcNow;
                changedInstances.Add(state.InstanceName);
                continue;
            }

            if (record.Type == TypeSrv && IsServiceInstance(record.Name))
            {
                var state = serviceStates.GetOrAdd(record.Name, name => new BonjourServiceState(name));
                state.Port = record.Port;
                state.HostName = record.TargetName;
                state.LastSeenAt = DateTimeOffset.UtcNow;
                changedInstances.Add(state.InstanceName);
                continue;
            }

            if (record.Type == TypeTxt && IsServiceInstance(record.Name))
            {
                var state = serviceStates.GetOrAdd(record.Name, name => new BonjourServiceState(name));
                foreach (var pair in record.Txt)
                {
                    state.Txt[pair.Key] = pair.Value;
                }

                state.LastSeenAt = DateTimeOffset.UtcNow;
                changedInstances.Add(state.InstanceName);
                continue;
            }

            if (record.Type == TypeA && record.Address is not null)
            {
                hostAddresses[record.Name] = record.Address;
                foreach (var state in serviceStates.Values.Where(state => IsSameName(state.HostName, record.Name)))
                {
                    changedInstances.Add(state.InstanceName);
                }
            }
        }

        foreach (var instance in changedInstances)
        {
            if (serviceStates.TryGetValue(instance, out var state))
            {
                TryEmitPeer(state, remoteAddress);
            }
        }
    }

    private void TryEmitPeer(BonjourServiceState state, IPAddress remoteAddress)
    {
        if (!state.Txt.TryGetValue("device_id", out var deviceId) ||
            string.IsNullOrWhiteSpace(deviceId) ||
            !state.Txt.TryGetValue("pairing_verifier", out var pairingVerifier) ||
            string.IsNullOrWhiteSpace(pairingVerifier))
        {
            return;
        }

        var port = state.Port;
        if (port <= 0 && state.Txt.TryGetValue("tcp_port", out var portText))
        {
            _ = int.TryParse(portText, out port);
        }

        if (port <= 0)
        {
            return;
        }

        var address = remoteAddress;
        if (!string.IsNullOrWhiteSpace(state.HostName) &&
            hostAddresses.TryGetValue(state.HostName, out var hostAddress))
        {
            address = hostAddress;
        }

        var beacon = new P2PDiscoveryBeacon(
            1,
            deviceId,
            state.Txt.GetValueOrDefault("device_name", "Unknown device"),
            state.Txt.GetValueOrDefault("platform", "unknown"),
            state.Txt.GetValueOrDefault("app_version", "unknown"),
            port,
            pairingVerifier,
            ParseCapabilities(state.Txt.GetValueOrDefault("capabilities", "")),
            DateTimeOffset.UtcNow);

        onPeerDiscovered(beacon, address);
    }

    private async Task SendQueryAsync()
    {
        var packet = DnsWriter.CreateQuery(ServiceType, TypePtr);
        await SendAsync(packet);
    }

    private async Task SendAnnouncementAsync()
    {
        UpdateNames();
        var beacon = beaconFactory();
        if (beacon.TcpPort <= 0)
        {
            return;
        }

        var packet = DnsWriter.CreateAnnouncement(
            ServiceType,
            instanceName,
            hostName,
            beacon,
            LocalIPv4Addresses());
        await SendAsync(packet);
    }

    private async Task SendAsync(byte[] packet)
    {
        var socket = CurrentSocket();
        if (socket is null)
        {
            return;
        }

        await socket.SendAsync(packet, packet.Length, new IPEndPoint(MdnsAddress, MdnsPort));
    }

    private UdpClient? CurrentSocket()
    {
        lock (socketGate)
        {
            return udp;
        }
    }

    private void UpdateNames()
    {
        var beacon = beaconFactory();
        var safeDevice = DnsWriter.SafeLabel(beacon.DeviceName, "stg-device");
        var safeHost = DnsWriter.SafeLabel(Environment.MachineName, "stg-host");
        var suffix = beacon.DeviceId.Length > 6 ? beacon.DeviceId[..6] : beacon.DeviceId;
        instanceName = $"{safeDevice}-{suffix}.{ServiceType}";
        hostName = $"{safeHost}-{suffix}.local.";
    }

    private static IReadOnlyList<IPAddress> LocalIPv4Addresses()
    {
        return NetworkInterface.GetAllNetworkInterfaces()
            .Where(network => network.OperationalStatus == OperationalStatus.Up)
            .Where(network => network.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(network => network.GetIPProperties().UnicastAddresses)
            .Select(address => address.Address)
            .Where(address => address.AddressFamily == AddressFamily.InterNetwork)
            .Where(address => !IPAddress.IsLoopback(address))
            .Where(address => !address.ToString().StartsWith("169.254.", StringComparison.Ordinal))
            .Distinct()
            .ToList();
    }

    private static bool IsQuestionForThisService(DnsQuestion question)
    {
        if (question.Type is not (TypePtr or TypeSrv or TypeTxt or TypeA or TypeAny))
        {
            return false;
        }

        return IsSameName(question.Name, ServiceType) || IsServiceInstance(question.Name);
    }

    private static bool IsServiceInstance(string name)
    {
        return NormalizeName(name).EndsWith($".{ServiceType}", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsSameName(string? left, string? right)
    {
        return NormalizeName(left) == NormalizeName(right);
    }

    private static string NormalizeName(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return "";
        }

        return value.EndsWith('.') ? value.ToLowerInvariant() : $"{value.ToLowerInvariant()}.";
    }

    private static List<string> ParseCapabilities(string value)
    {
        return value
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(item => item.ToLowerInvariant())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
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

    private sealed class BonjourServiceState
    {
        public BonjourServiceState(string instanceName)
        {
            InstanceName = NormalizeName(instanceName);
        }

        public string InstanceName { get; }
        public string HostName { get; set; } = "";
        public int Port { get; set; }
        public Dictionary<string, string> Txt { get; } = new(StringComparer.OrdinalIgnoreCase);
        public DateTimeOffset LastSeenAt { get; set; }
    }

    private sealed record DnsQuestion(string Name, ushort Type);

    private sealed record DnsRecord(
        string Name,
        ushort Type,
        string TargetName,
        int Port,
        Dictionary<string, string> Txt,
        IPAddress? Address);

    private sealed class DnsMessage
    {
        public bool IsResponse { get; private init; }
        public IReadOnlyList<DnsQuestion> Questions { get; private init; } = Array.Empty<DnsQuestion>();
        public IReadOnlyList<DnsRecord> Records { get; private init; } = Array.Empty<DnsRecord>();

        public static bool TryParse(byte[] data, out DnsMessage message)
        {
            message = new DnsMessage();
            try
            {
                var reader = new DnsReader(data);
                _ = reader.ReadUInt16();
                var flags = reader.ReadUInt16();
                var qdCount = reader.ReadUInt16();
                var anCount = reader.ReadUInt16();
                var nsCount = reader.ReadUInt16();
                var arCount = reader.ReadUInt16();
                var questions = new List<DnsQuestion>();
                var records = new List<DnsRecord>();

                for (var index = 0; index < qdCount; index++)
                {
                    questions.Add(new DnsQuestion(reader.ReadName(), reader.ReadUInt16()));
                    _ = reader.ReadUInt16();
                }

                var recordCount = anCount + nsCount + arCount;
                for (var index = 0; index < recordCount; index++)
                {
                    records.Add(reader.ReadRecord());
                }

                message = new DnsMessage
                {
                    IsResponse = (flags & 0x8000) != 0,
                    Questions = questions,
                    Records = records
                };
                return true;
            }
            catch
            {
                return false;
            }
        }
    }

    private sealed class DnsReader
    {
        private readonly byte[] data;
        private int position;

        public DnsReader(byte[] data)
        {
            this.data = data;
        }

        public ushort ReadUInt16()
        {
            Ensure(2);
            var value = (ushort)((data[position] << 8) | data[position + 1]);
            position += 2;
            return value;
        }

        private uint ReadUInt32()
        {
            Ensure(4);
            var value = ((uint)data[position] << 24) |
                ((uint)data[position + 1] << 16) |
                ((uint)data[position + 2] << 8) |
                data[position + 3];
            position += 4;
            return value;
        }

        public string ReadName()
        {
            var labels = new List<string>();
            var jumped = false;
            var jumpReturn = 0;
            var jumpCount = 0;

            while (true)
            {
                Ensure(1);
                var length = data[position++];
                if (length == 0)
                {
                    break;
                }

                if ((length & 0xC0) == 0xC0)
                {
                    Ensure(1);
                    var pointer = ((length & 0x3F) << 8) | data[position++];
                    if (!jumped)
                    {
                        jumpReturn = position;
                    }

                    position = pointer;
                    jumped = true;
                    if (++jumpCount > 16)
                    {
                        throw new FormatException("Too many DNS compression jumps.");
                    }
                    continue;
                }

                if ((length & 0xC0) != 0 || position + length > data.Length)
                {
                    throw new FormatException("Invalid DNS label.");
                }

                labels.Add(Encoding.UTF8.GetString(data, position, length));
                position += length;
            }

            if (jumped)
            {
                position = jumpReturn;
            }

            return string.Join(".", labels) + ".";
        }

        public DnsRecord ReadRecord()
        {
            var name = ReadName();
            var type = ReadUInt16();
            _ = ReadUInt16();
            _ = ReadUInt32();
            var dataLength = ReadUInt16();
            var dataStart = position;
            var dataEnd = dataStart + dataLength;
            if (dataEnd > data.Length)
            {
                throw new FormatException("Invalid DNS RDATA length.");
            }

            var targetName = "";
            var port = 0;
            var txt = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            IPAddress? address = null;

            if (type == TypePtr)
            {
                targetName = ReadName();
            }
            else if (type == TypeSrv)
            {
                _ = ReadUInt16();
                _ = ReadUInt16();
                port = ReadUInt16();
                targetName = ReadName();
            }
            else if (type == TypeTxt)
            {
                while (position < dataEnd)
                {
                    var length = data[position++];
                    if (length == 0 || position + length > dataEnd)
                    {
                        continue;
                    }

                    var entry = Encoding.UTF8.GetString(data, position, length);
                    position += length;
                    var separator = entry.IndexOf('=');
                    if (separator > 0)
                    {
                        txt[entry[..separator]] = entry[(separator + 1)..];
                    }
                }
            }
            else if (type == TypeA && dataLength == 4)
            {
                address = new IPAddress(data.Skip(position).Take(4).ToArray());
            }

            position = dataEnd;
            return new DnsRecord(name, type, targetName, port, txt, address);
        }

        private void Ensure(int count)
        {
            if (position + count > data.Length)
            {
                throw new FormatException("Unexpected end of DNS packet.");
            }
        }
    }

    private static class DnsWriter
    {
        public static byte[] CreateQuery(string serviceType, ushort queryType)
        {
            var bytes = new List<byte>();
            WriteUInt16(bytes, 0);
            WriteUInt16(bytes, 0);
            WriteUInt16(bytes, 1);
            WriteUInt16(bytes, 0);
            WriteUInt16(bytes, 0);
            WriteUInt16(bytes, 0);
            WriteName(bytes, serviceType);
            WriteUInt16(bytes, queryType);
            WriteUInt16(bytes, ClassIn);
            return bytes.ToArray();
        }

        public static byte[] CreateAnnouncement(
            string serviceType,
            string instanceName,
            string hostName,
            P2PDiscoveryBeacon beacon,
            IReadOnlyList<IPAddress> addresses)
        {
            var answerCount = (ushort)(3 + addresses.Count);
            var bytes = new List<byte>();
            WriteUInt16(bytes, 0);
            WriteUInt16(bytes, 0x8400);
            WriteUInt16(bytes, 0);
            WriteUInt16(bytes, answerCount);
            WriteUInt16(bytes, 0);
            WriteUInt16(bytes, 0);

            WriteRecord(bytes, serviceType, TypePtr, ClassIn, 120, rdata => WriteName(rdata, instanceName));
            WriteRecord(bytes, instanceName, TypeSrv, 0x8000 | ClassIn, 120, rdata =>
            {
                WriteUInt16(rdata, 0);
                WriteUInt16(rdata, 0);
                WriteUInt16(rdata, (ushort)beacon.TcpPort);
                WriteName(rdata, hostName);
            });
            WriteRecord(bytes, instanceName, TypeTxt, 0x8000 | ClassIn, 120, rdata =>
            {
                WriteTxt(rdata, "device_id", beacon.DeviceId);
                WriteTxt(rdata, "device_name", beacon.DeviceName);
                WriteTxt(rdata, "platform", beacon.Platform);
                WriteTxt(rdata, "app_version", beacon.AppVersion);
                WriteTxt(rdata, "pairing_verifier", beacon.PairingVerifier);
                WriteTxt(rdata, "tcp_port", beacon.TcpPort.ToString());
                WriteTxt(rdata, "capabilities", string.Join(",", beacon.Capabilities ?? []));
            });

            foreach (var address in addresses)
            {
                WriteRecord(bytes, hostName, TypeA, 0x8000 | ClassIn, 120, rdata => rdata.AddRange(address.GetAddressBytes()));
            }

            return bytes.ToArray();
        }

        public static string SafeLabel(string value, string fallback)
        {
            var safe = new string(value
                .Trim()
                .Select(character => char.IsLetterOrDigit(character) || character == '-' ? character : '-')
                .ToArray())
                .Trim('-');

            if (string.IsNullOrWhiteSpace(safe))
            {
                safe = fallback;
            }

            return safe.Length <= 40 ? safe : safe[..40].Trim('-');
        }

        private static void WriteRecord(List<byte> bytes, string name, ushort type, int dnsClass, uint ttl, Action<List<byte>> writeRdata)
        {
            WriteName(bytes, name);
            WriteUInt16(bytes, type);
            WriteUInt16(bytes, (ushort)dnsClass);
            WriteUInt32(bytes, ttl);
            var lengthOffset = bytes.Count;
            WriteUInt16(bytes, 0);
            var start = bytes.Count;
            writeRdata(bytes);
            var dataLength = bytes.Count - start;
            bytes[lengthOffset] = (byte)(dataLength >> 8);
            bytes[lengthOffset + 1] = (byte)dataLength;
        }

        private static void WriteName(List<byte> bytes, string name)
        {
            foreach (var label in name.TrimEnd('.').Split('.', StringSplitOptions.RemoveEmptyEntries))
            {
                var rawLabel = Encoding.UTF8.GetBytes(label);
                var length = Math.Min(rawLabel.Length, 63);
                bytes.Add((byte)length);
                bytes.AddRange(rawLabel.Take(length));
            }

            bytes.Add(0);
        }

        private static void WriteTxt(List<byte> bytes, string key, string value)
        {
            var raw = Encoding.UTF8.GetBytes($"{key}={value}");
            var length = Math.Min(raw.Length, 255);
            bytes.Add((byte)length);
            bytes.AddRange(raw.Take(length));
        }

        private static void WriteUInt16(List<byte> bytes, int value)
        {
            bytes.Add((byte)(value >> 8));
            bytes.Add((byte)value);
        }

        private static void WriteUInt32(List<byte> bytes, uint value)
        {
            bytes.Add((byte)(value >> 24));
            bytes.Add((byte)(value >> 16));
            bytes.Add((byte)(value >> 8));
            bytes.Add((byte)value);
        }
    }
}
