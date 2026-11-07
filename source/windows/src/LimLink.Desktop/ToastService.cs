using System.Security;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Windows.Data.Xml.Dom;
using Windows.UI.Notifications;

namespace LimLink.Desktop;

/// <summary>
/// Windows notifications for an unpackaged app. Buttons are handled in-process while LimLink runs;
/// consent requests expire with the receiver's 120 second decision window.
/// </summary>
internal sealed class ToastService
{
    public const string AppId = "LimLink.Desktop";
    private readonly ToastNotifier? _notifier;
    private readonly Dictionary<string, ToastNotification> _offers = [];
    public event Action<string, bool>? OfferDecided;
    public event Action? OpenRequested;

    public ToastService(string dataDirectory)
    {
        try
        {
            Register(dataDirectory);
            _notifier = ToastNotificationManager.CreateToastNotifier(AppId);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) { _notifier = null; }
    }

    /// <summary>False when notifications are unavailable or turned off for LimLink in Windows settings.</summary>
    public bool CanNotify
    {
        get
        {
            try { return _notifier is not null && _notifier.Setting == NotificationSetting.Enabled; }
            catch (Exception ex) when (ex is not OutOfMemoryException) { return false; }
        }
    }

    public void ShowOffer(IncomingOffer offer, string saveDirectory, DateTimeOffset deadline)
    {
        var xml = $"""
            <toast scenario="reminder" launch="open">
              <visual><binding template="ToastGeneric">
                <text>{E(Localization.Current.T("offer_toast_title", offer.SenderName))}</text>
                <text>{E(offer.FileName)} · {E(Format.Size(offer.Size))}</text>
                <text>{E(Localization.Current.T("offer_toast_save", saveDirectory))}</text>
                <text placement="attribution">{E(Localization.Current.T("offer_toast_expiry"))}</text>
              </binding></visual>
              <actions>
                <action content="{E(Localization.Current.T("accept"))}" arguments="accept:{E(offer.SessionId)}" activationType="foreground" />
                <action content="{E(Localization.Current.T("decline"))}" arguments="reject:{E(offer.SessionId)}" activationType="foreground" />
              </actions>
            </toast>
            """;
        var toast = Show(xml, deadline, Tag(offer.SessionId));
        if (toast is not null) _offers[offer.SessionId] = toast;
    }

    public void HideOffer(string sessionId)
    {
        if (_notifier is null || !_offers.Remove(sessionId, out var toast)) return;
        try { _notifier.Hide(toast); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
    }

    public void ShowInfo(string title, string body)
        => Show($"""<toast launch="open"><visual><binding template="ToastGeneric"><text>{E(title)}</text><text>{E(body)}</text></binding></visual></toast>""", DateTimeOffset.Now.AddMinutes(10), null);

    private ToastNotification? Show(string xml, DateTimeOffset expires, string? tag)
    {
        if (_notifier is null) return null;
        try
        {
            var document = new XmlDocument();
            document.LoadXml(xml);
            var toast = new ToastNotification(document) { ExpirationTime = expires };
            if (tag is not null) { toast.Tag = tag; toast.Group = "offers"; }
            toast.Activated += OnActivated;
            _notifier.Show(toast);
            return toast;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) { return null; }
    }

    private void OnActivated(ToastNotification sender, object args)
    {
        var arguments = (args as ToastActivatedEventArgs)?.Arguments ?? "";
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null) return;
        dispatcher.BeginInvoke(() =>
        {
            if (arguments.StartsWith("accept:", StringComparison.Ordinal)) OfferDecided?.Invoke(arguments[7..], true);
            else if (arguments.StartsWith("reject:", StringComparison.Ordinal)) OfferDecided?.Invoke(arguments[7..], false);
            else OpenRequested?.Invoke();
        });
    }

    /// <summary>Same geometry as tools/branding: ring radii 39 and 27 on a 108 unit black tile.</summary>
    private static BitmapSource RenderLogo(int size)
    {
        var scale = size / 108.0;
        var visual = new DrawingVisual();
        using (var context = visual.RenderOpen())
        {
            context.DrawRoundedRectangle(Brushes.Black, null, new Rect(0, 0, size, size), 24 * scale, 24 * scale);
            context.DrawEllipse(null, new Pen(Brushes.White, 12 * scale), new Point(size / 2.0, size / 2.0), 33 * scale, 33 * scale);
        }
        var bitmap = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        bitmap.Freeze();
        return bitmap;
    }

    private static string Tag(string sessionId) => sessionId.Length > 32 ? sessionId[..32] : sessionId;
    private static string E(string text) => SecurityElement.Escape(text) ?? "";

    private static void Register(string dataDirectory)
    {
        var icon = Path.Combine(dataDirectory, "notification-icon.png");
        if (!File.Exists(icon))
        {
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(RenderLogo(256)));
            using var file = File.Create(icon);
            encoder.Save(file);
        }
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Classes\AppUserModelId\" + AppId);
        key.SetValue("DisplayName", "LimLink");
        key.SetValue("IconUri", icon);
    }
}
