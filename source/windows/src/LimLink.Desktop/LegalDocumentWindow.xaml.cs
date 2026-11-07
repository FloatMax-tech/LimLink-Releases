using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;

namespace LimLink.Desktop;

public partial class LegalDocumentWindow : Window
{
    private readonly bool _privacy;

    internal LegalDocumentWindow(bool privacy)
    {
        InitializeComponent();
        _privacy = privacy;
        OnlineDocumentButton.SetBinding(ContentControl.ContentProperty, new Binding($"[{(privacy ? "legal_online_privacy" : "legal_online_terms")}]")
        {
            Source = Localization.Current,
            Mode = BindingMode.OneWay,
        });
        SetBinding(TitleProperty, new Binding($"[{(privacy ? "privacy_policy" : "usage_terms")}]")
        {
            Source = Localization.Current,
            Mode = BindingMode.OneWay,
        });
        PrivacyContent.Visibility = privacy ? Visibility.Visible : Visibility.Collapsed;
        UsageContent.Visibility = privacy ? Visibility.Collapsed : Visibility.Visible;
        Width = Math.Min(Width, SystemParameters.WorkArea.Width);
        Height = Math.Min(Height, SystemParameters.WorkArea.Height);
        Loaded += (_, _) => DocumentScroll.Focus();
    }

    private void OpenOnlineDocument(object sender, RoutedEventArgs e)
    {
        // Resolve at click time so changing the app language also changes an open document's link.
        var url = Localization.Current.T(_privacy ? "legal_privacy_url" : "legal_terms_url");
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            MessageBox.Show(this, Localization.Current.T("open_failed", ex.Message), Title,
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }
}
