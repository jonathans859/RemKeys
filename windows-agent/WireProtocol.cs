namespace KeyBridgeAgent;

/// <summary>
/// Parser for the wire format shared with the Apple apps:
/// <code>key &lt;vk&gt; pressed=&lt;0|1&gt;</code>
/// one line per key transition. This is the C# mirror of the Swift
/// <c>KeyEvent.parse</c>; keep the two in sync.
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
}
