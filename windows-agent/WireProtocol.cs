namespace KeyBridgeAgent;

/// <summary>
/// Parser for the wire format shared with the Apple apps:
/// <code>key &lt;vk&gt; pressed=&lt;0|1&gt;</code>
/// one line per key transition, and
/// <code>char &lt;codepoint&gt;</code>
/// one line per Unicode character to type (a full down+up, injected via
/// KEYEVENTF_UNICODE so it is independent of the active layout). This is the
/// C# mirror of the Swift <c>KeyEvent.parse</c> / <c>CharEvent.parse</c>;
/// keep the two sides in sync.
/// </summary>
public static class WireProtocol
{
    public static bool TryParse(string line, out ushort vk, out bool pressed)
    {
        vk = 0;
        pressed = false;

        var fields = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length != 3) return false;
        if (fields[0] != "key") return false;
        if (!ushort.TryParse(fields[1], out vk)) return false;

        switch (fields[2])
        {
            case "pressed=1": pressed = true; return true;
            case "pressed=0": pressed = false; return true;
            default: return false;
        }
    }

    public static bool TryParseChar(string line, out int codepoint)
    {
        codepoint = 0;

        var fields = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length != 2) return false;
        if (fields[0] != "char") return false;
        if (!int.TryParse(fields[1], out codepoint)) return false;
        // Valid Unicode scalar: in range and not a surrogate half.
        if (codepoint < 0 || codepoint > 0x10FFFF) return false;
        if (codepoint is >= 0xD800 and <= 0xDFFF) return false;
        return true;
    }
}
