using System.Net;
using System.Net.Sockets;

namespace RemKeysAgent;

/// <summary>
/// Who may connect while lock screen support is on — one ordered scale rather
/// than a bag of booleans, because it is a single question with one answer:
/// how far out does the circle of machines allowed to type at this PC's lock
/// screen reach.
///
/// It exists only in lock-screen mode. The in-session agent accepts anyone who
/// can reach the port and always has: it types as the signed-in user, on that
/// user's own desktop, so a connection buys an attacker nothing they did not
/// already have. The service types on the secure desktop as LocalSystem, which
/// is what makes the question worth asking at all.
/// </summary>
public enum PeerAccess
{
    /// <summary>
    /// Tailscale's own address ranges only. The default: Tailscale
    /// authenticates and encrypts the link, so "reachable" already means
    /// "someone you let into your tailnet".
    /// </summary>
    Tailscale,

    /// <summary>
    /// Tailscale, plus ordinary private/link-local LAN addresses and this PC
    /// itself. For an install that never uses Tailscale — the apps are happy
    /// with any address both ends can reach — at the cost of trusting every
    /// device on the network the PC is plugged into.
    /// </summary>
    LocalNetwork,

    /// <summary>
    /// Anything that can reach the port, which is the same policy the
    /// in-session agent uses. On a PC whose port is exposed to the internet
    /// this hands the lock screen to whoever finds it.
    /// </summary>
    Any,
}

/// <summary>
/// Everything that decides, describes or parses a <see cref="PeerAccess"/>, in
/// one place: the listener's check, the tray menu's labels, the confirmation
/// dialogs and the log line all say the same thing because they all read it
/// from here.
/// </summary>
public static class PeerAccessPolicy
{
    /// <summary>Menu order — widest circle last, so the risky one is not first.</summary>
    public static readonly PeerAccess[] All =
    {
        PeerAccess.Tailscale,
        PeerAccess.LocalNetwork,
        PeerAccess.Any,
    };

    /// <summary>Menu-item text. Short, and a full noun phrase for a screen reader.</summary>
    public static string Label(PeerAccess access) => access switch
    {
        PeerAccess.LocalNetwork => "Tailscale or this local network",
        PeerAccess.Any => "Any address that can reach the port",
        _ => "Tailscale addresses only",
    };

    /// <summary>One sentence saying what choosing this actually allows.</summary>
    public static string Consequence(PeerAccess access, int port) => access switch
    {
        PeerAccess.LocalNetwork =>
            "Any device on the network this PC is plugged into — and any program running on this PC — " +
            "will be able to type at the lock screen, the sign-in screen and UAC prompts. Choose this " +
            "if you use RemKeys over a plain home or office network rather than Tailscale.",
        PeerAccess.Any =>
            $"Anything that can reach port {port} will be able to type at the lock screen, the sign-in " +
            "screen and UAC prompts — including from the internet, if this PC's port is forwarded or the " +
            "PC is on a public network. Only choose this if you know who can reach that port.",
        _ =>
            "Only machines in your tailnet will be able to type at the lock screen, the sign-in screen " +
            "and UAC prompts. This is the safest setting: Tailscale authenticates and encrypts the link.",
    };

    /// <summary>The value as it is written to appsettings.json.</summary>
    public static string Canonical(PeerAccess access) => access.ToString();

    /// <summary>
    /// Lenient parse: an unrecognised value is a typo in a hand-edited config,
    /// not a reason to refuse to start, so the caller falls back to the safest
    /// setting and says so.
    /// </summary>
    public static bool TryParse(string? text, out PeerAccess access)
    {
        access = PeerAccess.Tailscale;
        var trimmed = text?.Trim();
        if (string.IsNullOrEmpty(trimmed)) return false;

        switch (trimmed.Replace(" ", string.Empty).Replace("-", string.Empty).ToLowerInvariant())
        {
            case "tailscale":
                access = PeerAccess.Tailscale;
                return true;
            case "localnetwork":
            case "local":
            case "lan":
                access = PeerAccess.LocalNetwork;
                return true;
            case "any":
            case "all":
                access = PeerAccess.Any;
                return true;
            default:
                return false;
        }
    }

    /// <summary>
    /// The listener's actual decision.
    ///
    /// <paramref name="allowLoopback"/> is the legacy <c>AllowLoopbackPeers</c>
    /// escape hatch, which still widens <see cref="PeerAccess.Tailscale"/> for
    /// local testing. The other two settings allow loopback anyway: once any
    /// LAN address is accepted, a program on this PC can simply connect to the
    /// PC's own LAN address, so refusing 127.0.0.1 there would be theatre.
    /// </summary>
    public static bool Allows(PeerAccess access, IPAddress address, bool allowLoopback)
    {
        if (access == PeerAccess.Any) return true;

        if (IPAddress.IsLoopback(address)) return allowLoopback || access == PeerAccess.LocalNetwork;

        if (IsTailscaleAddress(address)) return true;

        return access == PeerAccess.LocalNetwork && IsPrivateAddress(address);
    }

    /// <summary>
    /// Why a refused peer was refused. It names the tray item that changes it,
    /// because this is the one setting that makes a working install look broken
    /// from the other end — and the log line, or the tray status it also
    /// becomes, is the only place the PC says anything about it.
    /// </summary>
    public static string Rejection(PeerAccess access) =>
        $"not allowed by \"{TrayText.PeerMenuTitle}: {Label(access)}\"";

    /// <summary>
    /// Tailscale hands out IPv4 from the CGNAT block 100.64.0.0/10 and IPv6
    /// from fd7a:115c:a1e0::/48. Anything else reached this port over a plain
    /// LAN or a forwarded port.
    /// </summary>
    public static bool IsTailscaleAddress(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();

        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            var octets = address.GetAddressBytes();
            return octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127;
        }

        if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            var bytes = address.GetAddressBytes();
            return bytes[0] == 0xFD && bytes[1] == 0x7A && bytes[2] == 0x11 && bytes[3] == 0x5C
                && bytes[4] == 0xA1 && bytes[5] == 0xE0;
        }

        return false;
    }

    /// <summary>
    /// An address a home or office network hands out: RFC 1918, plus IPv4
    /// link-local (169.254/16) and IPv6 unique-local (fc00::/7) and link-local
    /// (fe80::/10). Deliberately a fixed list rather than "whatever subnet this
    /// PC's adapters are on" — a rule the user can predict beats one that
    /// changes when a VPN or a docking station appears.
    /// </summary>
    public static bool IsPrivateAddress(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();

        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            var o = address.GetAddressBytes();
            if (o[0] == 10) return true;
            if (o[0] == 172 && o[1] >= 16 && o[1] <= 31) return true;
            if (o[0] == 192 && o[1] == 168) return true;
            if (o[0] == 169 && o[1] == 254) return true;
            return false;
        }

        if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            if (address.IsIPv6LinkLocal) return true;
            var bytes = address.GetAddressBytes();
            return (bytes[0] & 0xFE) == 0xFC; // fc00::/7
        }

        return false;
    }
}

/// <summary>
/// Menu wording shared by the tray and by the log lines that refer to it, so a
/// rejection in the log names the item the user has to go and change.
/// </summary>
public static class TrayText
{
    public const string PeerMenuTitle = "Who may type at the lock screen";
}
