using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace KeyBridgeAgent;

/// <summary>
/// The Win32 surface the service/helper split needs: duplicating the service's
/// own LocalSystem token into the console session, launching a process onto a
/// named desktop, and asking which desktop currently receives input.
/// </summary>
internal static class Native
{
    // ---- Session / token -------------------------------------------------

    [DllImport("kernel32.dll")]
    internal static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern nint GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CloseHandle(nint handle);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool OpenProcessToken(nint processHandle, uint desiredAccess, out nint tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DuplicateTokenEx(
        nint existingToken,
        uint desiredAccess,
        nint tokenAttributes,
        int impersonationLevel,
        int tokenType,
        out nint newToken);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetTokenInformation(
        nint token,
        int tokenInformationClass,
        ref uint tokenInformation,
        uint tokenInformationLength);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CreateProcessAsUserW(
        nint token,
        string? applicationName,
        // StringBuilder, not string: CreateProcess* may write into the command
        // line buffer, and a Unicode `string` parameter is pinned rather than
        // copied — it would be scribbling on a managed string.
        StringBuilder? commandLine,
        nint processAttributes,
        nint threadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
        uint creationFlags,
        nint environment,
        string? currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("userenv.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CreateEnvironmentBlock(out nint environment, nint token, [MarshalAs(UnmanagedType.Bool)] bool inherit);

    [DllImport("userenv.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DestroyEnvironmentBlock(nint environment);

    [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool WTSQuerySessionInformationW(
        nint server, uint sessionId, int infoClass, out nint buffer, out uint bytesReturned);

    [DllImport("wtsapi32.dll")]
    internal static extern void WTSFreeMemory(nint memory);

    // ---- Desktops --------------------------------------------------------

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern nint OpenInputDesktop(uint flags, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint desiredAccess);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CloseDesktop(nint desktop);

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern nint GetThreadDesktop(uint threadId);

    [DllImport("kernel32.dll")]
    internal static extern uint GetCurrentThreadId();

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetUserObjectInformationW(
        nint obj, int index, [Out] byte[] info, uint length, out uint lengthNeeded);

    // ---- Constants -------------------------------------------------------

    internal const uint TOKEN_DUPLICATE = 0x0002;
    internal const uint TOKEN_QUERY = 0x0008;
    internal const uint MAXIMUM_ALLOWED = 0x02000000;
    internal const int SecurityImpersonation = 2;
    internal const int TokenPrimary = 1;
    internal const int TokenSessionId = 12;

    internal const uint CREATE_UNICODE_ENVIRONMENT = 0x0400;
    internal const uint CREATE_NO_WINDOW = 0x08000000;

    internal const int UOI_NAME = 2;
    internal const int WTSUserName = 5;
    internal const int WTSDomainName = 7;
    internal const uint INVALID_SESSION = 0xFFFFFFFF;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct STARTUPINFO
    {
        public int cb;
        public string? lpReserved;
        public string? lpDesktop;
        public string? lpTitle;
        public int dwX, dwY, dwXSize, dwYSize;
        public int dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public nint lpReserved2;
        public nint hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PROCESS_INFORMATION
    {
        public nint hProcess;
        public nint hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    // ---- Helpers ---------------------------------------------------------

    /// <summary>
    /// Name of the desktop currently receiving input on this process's window
    /// station — "Default" for the normal desktop, "Winlogon" for the lock
    /// screen, the sign-in screen and the UAC prompt. Returns null if it can't
    /// be determined (callers must treat that as "don't know", never as
    /// "not me").
    /// </summary>
    internal static string? GetInputDesktopName()
    {
        var desktop = OpenInputDesktop(0, false, MAXIMUM_ALLOWED);
        if (desktop == 0) return null;
        try { return GetUserObjectName(desktop); }
        finally { CloseDesktop(desktop); }
    }

    /// <summary>Name of the desktop this thread is attached to.</summary>
    internal static string? GetThreadDesktopName()
    {
        // Not closed on purpose: GetThreadDesktop returns a handle owned by
        // the system that must not be passed to CloseDesktop.
        var desktop = GetThreadDesktop(GetCurrentThreadId());
        return desktop == 0 ? null : GetUserObjectName(desktop);
    }

    private static string? GetUserObjectName(nint handle)
    {
        var buffer = new byte[512];
        if (!GetUserObjectInformationW(handle, UOI_NAME, buffer, (uint)buffer.Length, out var needed))
        {
            if (needed == 0 || needed > 64 * 1024) return null;
            buffer = new byte[needed];
            if (!GetUserObjectInformationW(handle, UOI_NAME, buffer, (uint)buffer.Length, out _)) return null;
        }
        var text = Encoding.Unicode.GetString(buffer);
        var terminator = text.IndexOf('\0');
        return terminator >= 0 ? text[..terminator] : text;
    }

    /// <summary>
    /// Domain-qualified user name signed in to <paramref name="sessionId"/>, or
    /// null if nobody is. Used when restoring the logon task on uninstall,
    /// where the caller is LocalSystem and has no "current user" of its own.
    /// </summary>
    internal static string? GetSessionUserName(uint sessionId)
    {
        var user = QuerySessionString(sessionId, WTSUserName);
        if (string.IsNullOrWhiteSpace(user)) return null;
        var domain = QuerySessionString(sessionId, WTSDomainName);
        return string.IsNullOrWhiteSpace(domain) ? user : $"{domain}\\{user}";
    }

    private static string? QuerySessionString(uint sessionId, int infoClass)
    {
        if (!WTSQuerySessionInformationW(0, sessionId, infoClass, out var buffer, out _)) return null;
        try { return Marshal.PtrToStringUni(buffer); }
        finally { WTSFreeMemory(buffer); }
    }

    /// <summary>
    /// Launch <paramref name="commandLine"/> as LocalSystem inside
    /// <paramref name="sessionId"/>, attached to <paramref name="desktop"/>.
    /// The service's own token is duplicated and re-homed to the target session
    /// — LocalSystem holds the SeAssignPrimaryToken and SeIncreaseQuota
    /// privileges this needs, which is exactly why the supervisor is a service.
    /// </summary>
    internal static Process? StartOnDesktop(string commandLine, uint sessionId, string desktop, string workingDirectory)
    {
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE | TOKEN_QUERY, out var processToken))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken failed.");
        }

        nint duplicated = 0;
        nint environment = 0;
        try
        {
            if (!DuplicateTokenEx(processToken, MAXIMUM_ALLOWED, 0, SecurityImpersonation, TokenPrimary, out duplicated))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "DuplicateTokenEx failed.");
            }

            var session = sessionId;
            if (!SetTokenInformation(duplicated, TokenSessionId, ref session, sizeof(uint)))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetTokenInformation(TokenSessionId) failed.");
            }

            if (!CreateEnvironmentBlock(out environment, duplicated, false))
            {
                environment = 0; // non-fatal: inherit the service's environment
            }

            var startupInfo = new STARTUPINFO
            {
                cb = Marshal.SizeOf<STARTUPINFO>(),
                lpDesktop = $"WinSta0\\{desktop}",
            };

            // No CREATE_BREAKAWAY_FROM_JOB on purpose: helpers are meant to die
            // with the service, and the flag fails outright inside a job that
            // does not permit breakaway.
            var flags = CREATE_NO_WINDOW;
            if (environment != 0) flags |= CREATE_UNICODE_ENVIRONMENT;

            var mutableCommandLine = new StringBuilder(commandLine, commandLine.Length + 1);
            if (!CreateProcessAsUserW(
                    duplicated, null, mutableCommandLine, 0, 0, false,
                    flags, environment, workingDirectory, ref startupInfo, out var info))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    $"CreateProcessAsUser onto WinSta0\\{desktop} in session {sessionId} failed.");
            }

            CloseHandle(info.hThread);
            CloseHandle(info.hProcess);
            try
            {
                return Process.GetProcessById(info.dwProcessId);
            }
            catch (ArgumentException)
            {
                // Died before we could grab a handle. Null tells the supervisor
                // to back off and try again rather than treating it as running.
                return null;
            }
        }
        finally
        {
            if (environment != 0) DestroyEnvironmentBlock(environment);
            if (duplicated != 0) CloseHandle(duplicated);
            CloseHandle(processToken);
        }
    }
}
