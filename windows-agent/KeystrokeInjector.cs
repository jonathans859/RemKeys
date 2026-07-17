using System.Runtime.InteropServices;

namespace KeyBridgeAgent;

/// <summary>
/// Replays virtual-key transitions as real Windows keystrokes via
/// <c>SendInput</c> (user32.dll). One press line becomes a key-down INPUT, one
/// release line a key-up INPUT — so held modifiers and chords behave exactly as
/// if typed on a locally attached keyboard.
/// </summary>
public static class KeystrokeInjector
{
    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    /// <summary>
    /// Virtual keys that live in the "extended" block of the PC keyboard. They
    /// must carry <c>KEYEVENTF_EXTENDEDKEY</c> or Windows routes them to the
    /// wrong physical key (e.g. arrow keys vs. the numpad, right vs. left Alt).
    /// </summary>
    private static readonly HashSet<ushort> ExtendedKeys = new()
    {
        0xA3, // VK_RCONTROL
        0xA5, // VK_RMENU (Right Alt / AltGr)
        0x2D, // VK_INSERT
        0x2E, // VK_DELETE
        0x24, // VK_HOME
        0x23, // VK_END
        0x21, // VK_PRIOR (Page Up)
        0x22, // VK_NEXT (Page Down)
        0x25, // VK_LEFT
        0x26, // VK_UP
        0x27, // VK_RIGHT
        0x28, // VK_DOWN
        0x90, // VK_NUMLOCK
        0x6F, // VK_DIVIDE (numpad /)
        0x2C, // VK_SNAPSHOT (Print Screen)
        0x5B, // VK_LWIN
        0x5C, // VK_RWIN
        0x5D, // VK_APPS (context menu)
        0xAD, // VK_VOLUME_MUTE
        0xAE, // VK_VOLUME_DOWN
        0xAF, // VK_VOLUME_UP
        0xB0, // VK_MEDIA_NEXT_TRACK
        0xB1, // VK_MEDIA_PREV_TRACK
        0xB2, // VK_MEDIA_STOP
        0xB3, // VK_MEDIA_PLAY_PAUSE
    };

    /// <summary>
    /// Inject a single key transition. Returns false if the OS rejected the
    /// event (e.g. blocked by a UIPI / secure-desktop boundary), so the caller
    /// can log it.
    /// </summary>
    public static bool Send(ushort vk, bool pressed)
    {
        uint flags = pressed ? 0u : KEYEVENTF_KEYUP;
        if (ExtendedKeys.Contains(vk))
        {
            flags |= KEYEVENTF_EXTENDEDKEY;
        }

        var input = new INPUT
        {
            type = INPUT_KEYBOARD,
            U = new InputUnion
            {
                ki = new KEYBDINPUT
                {
                    wVk = vk,
                    wScan = 0,
                    dwFlags = flags,
                    time = 0,
                    dwExtraInfo = IntPtr.Zero,
                }
            }
        };

        var inputs = new[] { input };
        uint sent = SendInput(1, inputs, Marshal.SizeOf<INPUT>());
        return sent == 1;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }
}
