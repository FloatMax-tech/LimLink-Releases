using System.ComponentModel;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Win32;

namespace LimLink.Desktop;

public partial class App : Application
{
    private const string InstanceName = @"Local\LimLink.Desktop.Instance";
    private const string ShowSignalName = @"Local\LimLink.Desktop.Show";
    private Mutex? _instance;
    private EventWaitHandle? _showSignal;
    private RegisteredWaitHandle? _showWait;
    private MainWindow? _window;
    private MainViewModel? _model;
    private TrayIcon? _tray;
    private ToastService? _toasts;
    private string? _openRequest;
    private bool _dark;
    private bool _exiting;

    public static bool IsDark => Current is App { _dark: true };

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LimLink");
        Directory.CreateDirectory(data);
        Localization.Current.SetLanguage(AppSettings.Load(data).Language);
        ActivityLog.Init(data);
        _openRequest = Path.Combine(data, "open-request.txt");
        // "LimLink.exe <file>" (or dropping a file on the icon) preselects that file.
        var file = e.Args.Select(FullPathOrNull).FirstOrDefault(File.Exists);
        _instance = new Mutex(true, InstanceName, out var first);
        _showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, ShowSignalName);
        if (!first)
        {
            if (file is not null) TryWrite(_openRequest, file);
            _showSignal.Set();
            Shutdown();
            return;
        }
        TryDelete(_openRequest);
        _showWait = ThreadPool.RegisterWaitForSingleObject(_showSignal, (_, _) => Dispatcher.BeginInvoke(OnShowSignal), null, Timeout.Infinite, false);
        _ = Native.SetCurrentProcessExplicitAppUserModelID(ToastService.AppId);
        DispatcherUnhandledException += (_, args) => LogCrash(data, args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, args) => LogCrash(data, args.ExceptionObject as Exception);
        ApplyTheme(SystemUsesDarkTheme());
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;

        _toasts = new ToastService(data);
        _toasts.OpenRequested += ShowWindow;
        _model = new MainViewModel(data, _toasts, Dispatcher);
        _window = new MainWindow(_model);
        _window.Closing += OnWindowClosing;
        _tray = new TrayIcon();
        _tray.OpenRequested += ShowWindow;
        _tray.ExitRequested += () => _ = ExitAsync();
        _model.TrayTextChanged += text => _tray?.SetText(text);
        _model.AttentionRequested += mustShow =>
        {
            // Raised from the receiver's thread; window APIs must run on the dispatcher.
            Dispatcher.BeginInvoke(() =>
            {
                ActivityLog.Write("ui", $"offer attention mustShow={mustShow} visible={_window?.IsVisible} active={_window?.IsActive}");
                ShowWindow();
                if (_window is not null) Native.FlashTaskbar(new WindowInteropHelper(_window).Handle);
            });
        };
        _window.Show();
        if (file is not null) _model.OpenFile(file);
        await _model.StartAsync();
    }

    private void OnShowSignal()
    {
        ShowWindow();
        if (_openRequest is null || !File.Exists(_openRequest)) return;
        try
        {
            var path = File.ReadAllText(_openRequest).Trim();
            File.Delete(_openRequest);
            if (File.Exists(path)) _model?.OpenFile(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    private static string? FullPathOrNull(string argument)
    {
        try { return Path.GetFullPath(argument); }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException) { return null; }
    }

    private static void TryWrite(string path, string text)
    {
        try { File.WriteAllText(path, text); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    private void ShowWindow()
    {
        if (_window is null || _exiting) return;
        ActivityLog.Write("ui", "show window");
        _window.Show();
        if (_window.WindowState == WindowState.Minimized) _window.WindowState = WindowState.Normal;
        _window.Activate();
        Native.SetForegroundWindow(new WindowInteropHelper(_window).Handle);
    }

    private void OnWindowClosing(object? sender, CancelEventArgs e)
    {
        if (_exiting || _model is null || _window is null) return;
        e.Cancel = true;
        if (!_model.Settings.CloseToTray) { _ = ExitAsync(); return; }
        _window.Hide();
        if (!_model.Settings.TrayNoticeShown)
        {
            _toasts?.ShowInfo(Localization.Current.T("tray_notice_title"), Localization.Current.T("tray_notice_body"));
            _model.MarkTrayNoticeShown();
        }
    }

    private async Task ExitAsync()
    {
        if (_exiting) return;
        _exiting = true;
        _window?.Hide();
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        if (_model is not null) await _model.DisposeAsync();
        _tray?.Dispose();
        _showWait?.Unregister(null);
        _window?.Close();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _showSignal?.Dispose();
        _instance?.Dispose();
        base.OnExit(e);
    }

    private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category is not (UserPreferenceCategory.General or UserPreferenceCategory.Color)) return;
        Dispatcher.BeginInvoke(() =>
        {
            var dark = SystemUsesDarkTheme();
            if (dark != _dark) ApplyTheme(dark);
        });
    }

    private void ApplyTheme(bool dark)
    {
        _dark = dark;
        var colors = new ResourceDictionary { Source = new Uri(dark ? "pack://application:,,,/Theme/Dark.xaml" : "pack://application:,,,/Theme/Light.xaml") };
        Resources.MergedDictionaries[0] = colors;
        _window?.ApplyBackdrop();
    }

    private static void LogCrash(string dataDirectory, Exception? exception)
    {
        try { File.AppendAllText(Path.Combine(dataDirectory, "crash.log"), $"[{DateTimeOffset.Now:O}] {exception}{Environment.NewLine}"); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    private static bool SystemUsesDarkTheme()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("AppsUseLightTheme") is int light && light == 0;
    }
}
