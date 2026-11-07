using System.Windows;
using System.Windows.Controls;

namespace LimLink.Desktop;

/// <summary>Every queued selection has its own preview/location action; no arbitrary first-file shortcut.</summary>
internal sealed class SelectedFilesWindow : Window
{
    public SelectedFilesWindow(IReadOnlyList<string> files, Action<string> preview, Action<string> reveal)
    {
        Title = Localization.Current.T("preview"); Width = 620; Height = 420; MinWidth = 400; MinHeight = 260;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        SetResourceReference(BackgroundProperty, "LayerSolid"); SetResourceReference(ForegroundProperty, "Ink");
        var stack = new StackPanel { Margin = new Thickness(20) };
        foreach (var file in files)
        {
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
            var location = new Button { Content = Localization.Current.T("open_containing_folder"), Margin = new Thickness(8, 0, 0, 0) };
            location.SetResourceReference(StyleProperty, "WinButton"); location.Click += (_, _) => reveal(file); DockPanel.SetDock(location, Dock.Right); row.Children.Add(location);
            var open = new Button { Content = Path.GetFileName(file), HorizontalContentAlignment = HorizontalAlignment.Left };
            open.SetResourceReference(StyleProperty, "GhostPill"); open.Click += (_, _) => preview(file); row.Children.Add(open); stack.Children.Add(row);
        }
        Content = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }
}
