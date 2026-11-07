using Forms = System.Windows.Forms;

namespace LimLink.Desktop;

internal sealed class TrayIcon : IDisposable
{
    private readonly Forms.NotifyIcon _icon;
    private readonly System.Drawing.Icon _image;
    private readonly Forms.ToolStripMenuItem _openItem;
    private readonly Forms.ToolStripMenuItem _exitItem;
    public event Action? OpenRequested;
    public event Action? ExitRequested;

    public TrayIcon()
    {
        _image = LoadIcon();
        var menu = new Forms.ContextMenuStrip();
        _openItem = new Forms.ToolStripMenuItem(Localization.Current.T("tray_open"), null, (_, _) => OpenRequested?.Invoke());
        _exitItem = new Forms.ToolStripMenuItem(Localization.Current.T("tray_exit"), null, (_, _) => ExitRequested?.Invoke());
        menu.Items.Add(_openItem);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(_exitItem);
        _icon = new Forms.NotifyIcon { Icon = _image, Text = "LimLink", ContextMenuStrip = menu, Visible = true };
        _icon.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) OpenRequested?.Invoke(); };
        Localization.Current.LanguageChanged += UpdateLanguage;
    }

    private void UpdateLanguage()
    {
        _openItem.Text = Localization.Current.T("tray_open");
        _exitItem.Text = Localization.Current.T("tray_exit");
    }

    private static System.Drawing.Icon LoadIcon()
    {
        try
        {
            using var stream = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/AppIcon.ico")).Stream;
            return new System.Drawing.Icon(stream, Forms.SystemInformation.SmallIconSize);
        }
        catch (Exception ex) when (ex is ArgumentException or IOException or System.ComponentModel.Win32Exception)
        {
            return System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? System.Drawing.SystemIcons.Application;
        }
    }

    public void SetText(string text) => _icon.Text = text.Length > 63 ? text[..63] : text;

    public void Dispose()
    {
        Localization.Current.LanguageChanged -= UpdateLanguage;
        _icon.Visible = false;
        _icon.ContextMenuStrip?.Dispose();
        _icon.Dispose();
        _image.Dispose();
    }
}
