using System.Runtime.InteropServices;

namespace LimLink.Desktop;

internal static partial class Native
{
    private const int DwmUseImmersiveDarkMode = 20;
    private const int DwmSystemBackdropType = 38;
    private const int BackdropMainWindow = 2;
    private static readonly Guid DownloadsFolder = new("374DE290-123F-4565-9164-39C4925E467B");

    [StructLayout(LayoutKind.Sequential)]
    private struct Margins { public int Left, Right, Top, Bottom; }

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);
    [LibraryImport("dwmapi.dll")]
    private static partial int DwmExtendFrameIntoClientArea(nint hwnd, ref Margins margins);
    [LibraryImport("shell32.dll", StringMarshalling = StringMarshalling.Utf16)]
    internal static partial int SetCurrentProcessExplicitAppUserModelID(string appId);
    [LibraryImport("shell32.dll")]
    private static partial int SHGetKnownFolderPath(in Guid id, uint flags, nint token, out nint path);
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetForegroundWindow(nint hwnd);

    [StructLayout(LayoutKind.Sequential)]
    private struct FlashInfo { public uint Size; public nint Hwnd; public uint Flags; public uint Count; public uint Timeout; }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool FlashWindowEx(ref FlashInfo info);

    /// <summary>Flashes the taskbar button until the window comes to the foreground.</summary>
    public static void FlashTaskbar(nint hwnd)
    {
        if (hwnd == 0) return;
        const uint FlashTray = 0x2, FlashUntilForeground = 0xC;
        var info = new FlashInfo { Size = (uint)Marshal.SizeOf<FlashInfo>(), Hwnd = hwnd, Flags = FlashTray | FlashUntilForeground };
        _ = FlashWindowEx(ref info);
    }

    public static void SetDarkFrame(nint hwnd, bool dark)
    {
        var value = dark ? 1 : 0;
        _ = DwmSetWindowAttribute(hwnd, DwmUseImmersiveDarkMode, ref value, sizeof(int));
    }

    /// <summary>Mica needs Windows 11 22H2. Returns false when the caller should paint a solid background.</summary>
    public static bool TryEnableMica(nint hwnd)
    {
        if (Environment.OSVersion.Version.Build < 22621) return false;
        var backdrop = BackdropMainWindow;
        if (DwmSetWindowAttribute(hwnd, DwmSystemBackdropType, ref backdrop, sizeof(int)) != 0) return false;
        var margins = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
        return DwmExtendFrameIntoClientArea(hwnd, ref margins) == 0;
    }

    public static string DownloadsPath()
    {
        if (SHGetKnownFolderPath(DownloadsFolder, 0, 0, out var pointer) == 0)
        {
            try { if (Marshal.PtrToStringUni(pointer) is { Length: > 0 } path) return path; }
            finally { Marshal.FreeCoTaskMem(pointer); }
        }
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
    }
}
