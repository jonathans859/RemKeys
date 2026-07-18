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
    private const uint KEYEVENTF_UNICODE = 0x0004;
    private const uint KEYEVENTF_SCANCODE = 0x0008;

    /// <summary>
    /// Layout-sensitive keys (letters, digits, punctuation) are injected as
    /// <b>scancodes</b>, not VKs. The Apple senders report physical key
    /// positions (HID usages) translated to VKs with their US-layout meaning;
    /// injecting that VK on a PC with a different layout types the wrong
    /// character (German QWERTZ: the key labeled Z arrives as VK_Y and types
    /// "y"). Injecting the US scancode for the position instead lets the PC's
    /// active layout decide the character — exactly as if the keyboard were
    /// attached locally. Maps US-positional VK → PC/AT set-1 make code.
    /// This table must stay fixed (never MapVirtualKey) because the PC's own
    /// layout would translate these VKs to the wrong positions. Keys absent
    /// here are layout-independent and get their scan code from
    /// MapVirtualKeyW at send time instead.
    /// </summary>
    private static readonly Dictionary<ushort, ushort> LayoutSensitiveScanCodes = new()
    {
        // Letters (VK_A..VK_Z = 0x41..0x5A)
        [0x41] = 0x1E, // A
        [0x42] = 0x30, // B
        [0x43] = 0x2E, // C
        [0x44] = 0x20, // D
        [0x45] = 0x12, // E
        [0x46] = 0x21, // F
        [0x47] = 0x22, // G
        [0x48] = 0x23, // H
        [0x49] = 0x17, // I
        [0x4A] = 0x24, // J
        [0x4B] = 0x25, // K
        [0x4C] = 0x26, // L
        [0x4D] = 0x32, // M
        [0x4E] = 0x31, // N
        [0x4F] = 0x18, // O
        [0x50] = 0x19, // P
        [0x51] = 0x10, // Q
        [0x52] = 0x13, // R
        [0x53] = 0x1F, // S
        [0x54] = 0x14, // T
        [0x55] = 0x16, // U
        [0x56] = 0x2F, // V
        [0x57] = 0x11, // W
        [0x58] = 0x2D, // X
        [0x59] = 0x15, // Y (US position; German layout makes this Z)
        [0x5A] = 0x2C, // Z
        // Top-row digits (VK_0..VK_9 = 0x30..0x39)
        [0x31] = 0x02, // 1
        [0x32] = 0x03, // 2
        [0x33] = 0x04, // 3
        [0x34] = 0x05, // 4
        [0x35] = 0x06, // 5
        [0x36] = 0x07, // 6
        [0x37] = 0x08, // 7
        [0x38] = 0x09, // 8
        [0x39] = 0x0A, // 9
        [0x30] = 0x0B, // 0
        // Punctuation (US OEM keys)
        [0xBD] = 0x0C, // VK_OEM_MINUS   (-)
        [0xBB] = 0x0D, // VK_OEM_PLUS    (=)
        [0xDB] = 0x1A, // VK_OEM_4       ([)
        [0xDD] = 0x1B, // VK_OEM_6       (])
        [0xDC] = 0x2B, // VK_OEM_5       (\)
        [0xBA] = 0x27, // VK_OEM_1       (;)
        [0xDE] = 0x28, // VK_OEM_7       (')
        [0xC0] = 0x29, // VK_OEM_3       (`)
        [0xBC] = 0x33, // VK_OEM_COMMA   (,)
        [0xBE] = 0x34, // VK_OEM_PERIOD  (.)
        [0xBF] = 0x35, // VK_OEM_2       (/)
        [0xE2] = 0x56, // VK_OEM_102     (ISO extra key next to left Shift)
    };

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
        bool extended = ExtendedKeys.Contains(vk);

        // Scancode-primary injection for every key that has a scan code, not
        // just the layout-sensitive ones: games reading Raw Input or
        // DirectInput identify keys by scan code and silently drop events
        // whose make code is 0, so VK-only events reach normal apps but
        // vanish in games (arrows, F-keys, modifiers). With a scan code the
        // system derives the VK itself, exactly like a physically attached
        // keyboard.
        if (!LayoutSensitiveScanCodes.TryGetValue(vk, out ushort scan))
        {
            // Layout-independent keys resolve at runtime. Quirks (verified
            // against MapVirtualKeyW output): the nav cluster comes back
            // WITHOUT its E0 prefix (VK_LEFT -> 0x4B, colliding with numpad
            // 4 — the ExtendedKeys flag above is what disambiguates);
            // VK_SNAPSHOT returns the Alt+SysRq code 0x54 instead of E0 37;
            // VK_PAUSE returns the multi-byte E1 sequence, which KEYBDINPUT
            // cannot express, so it stays a VK-only event.
            uint mapped = vk switch
            {
                0x2C => 0xE037, // VK_SNAPSHOT: real PrintScreen make code
                0x13 => 0,      // VK_PAUSE: E1-prefixed, keep the VK path
                _ => MapVirtualKeyW(vk, MAPVK_VK_TO_VSC_EX),
            };
            if ((mapped >> 8) == 0xE0)
            {
                extended = true;
            }
            scan = (ushort)(mapped & 0xFF);
        }

        ushort sendVk = vk;
        if (scan != 0)
        {
            flags |= KEYEVENTF_SCANCODE;
            sendVk = 0;
        }
        if (extended)
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
                    wVk = sendVk,
                    wScan = scan,
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

    /// <summary>
    /// Type one Unicode character (full down+up) via KEYEVENTF_UNICODE, which
    /// delivers the character itself regardless of the active layout — the
    /// path for the iOS virtual-input screen's plain text, where "ü" must be
    /// "ü" and not whatever key sits at that position. Characters outside the
    /// BMP go out as their surrogate pair, which is exactly what the unicode
    /// injection path expects in wScan.
    /// </summary>
    public static bool SendUnicode(int codepoint)
    {
        string units = char.ConvertFromUtf32(codepoint);
        var inputs = new INPUT[units.Length * 2];
        for (int i = 0; i < units.Length; i++)
        {
            inputs[i] = UnicodeInput(units[i], up: false);
            inputs[units.Length + i] = UnicodeInput(units[i], up: true);
        }
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        return sent == inputs.Length;
    }

    private static INPUT UnicodeInput(char unit, bool up) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion
        {
            ki = new KEYBDINPUT
            {
                wVk = 0,
                wScan = unit,
                dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0u),
                time = 0,
                dwExtraInfo = IntPtr.Zero,
            }
        }
    };

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    private const uint MAPVK_VK_TO_VSC_EX = 4;

    [DllImport("user32.dll")]
    private static extern uint MapVirtualKeyW(uint uCode, uint uMapType);

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
