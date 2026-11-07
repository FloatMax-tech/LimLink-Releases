using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Windows.Data.Pdf;
using Windows.Storage;
using Windows.Storage.Streams;
using LimLink.Files;

namespace LimLink.Desktop;

/// <summary>Native offline preview. No browser, shell preview handlers or automatic external-file execution.</summary>
internal sealed class FilePreviewWindow : Window
{
    private readonly string _path;
    private readonly CancellationTokenSource _closed = new();
    private readonly ContentControl _content = new();
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
    private readonly StackPanel _navigation = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Button _previous;
    private readonly Button _next;
    private readonly TextBlock _pageLabel = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 12, 0) };
    private PdfDocument? _pdf;
    private IRandomAccessStream? _pdfStream;
    private MediaElement? _media;
    private uint _page;
    private bool _rendering;
    private static Localization L => Localization.Current;

    public FilePreviewWindow(string path)
    {
        _path = Path.GetFullPath(path);
        Title = L.T("preview") + " · " + Path.GetFileName(path);
        Width = 860; Height = 660; MinWidth = 420; MinHeight = 340;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        SetResourceReference(BackgroundProperty, "LayerSolid");
        SetResourceReference(ForegroundProperty, "Ink");
        var root = new DockPanel { Margin = new Thickness(20) };
        var toolbar = new WrapPanel { Margin = new Thickness(0, 0, 0, 12) };
        toolbar.Children.Add(Button("open_containing_folder", (_, _) => TryAction(() => Reveal(_path))));
        if (FilePreviewPolicy.Classify(_path) == PreviewKind.Image) toolbar.Children.Add(Button("open_photos", (_, _) => TryAction(() => OpenPhoto(_path))));
        if (FilePreviewPolicy.CanOpenExternally(_path)) toolbar.Children.Add(Button("open_with", (_, _) => TryAction(() => OpenWith(_path))));
        toolbar.Children.Add(Button("close_preview", (_, _) => Close()));
        DockPanel.SetDock(toolbar, Dock.Top); root.Children.Add(toolbar);
        var footer = new StackPanel(); footer.Children.Add(_navigation); footer.Children.Add(_status);
        DockPanel.SetDock(footer, Dock.Bottom); root.Children.Add(footer);
        _previous = Button("previous_page", async (_, _) => { if (_page > 0) { _page--; await RenderPageAsync(); } });
        _next = Button("next_page", async (_, _) => { if (_pdf is not null && _page + 1 < _pdf.PageCount) { _page++; await RenderPageAsync(); } });
        _navigation.Children.Add(_previous); _navigation.Children.Add(_pageLabel); _navigation.Children.Add(_next);
        _navigation.Visibility = Visibility.Collapsed;
        _status.Text = L.T("preview_loading");
        root.Children.Add(_content); Content = root;
        Loaded += async (_, _) => await LoadPreviewAsync();
        Closed += (_, _) =>
        {
            _closed.Cancel();
            if (_media is not null) { _media.Stop(); _media.Close(); _media.Source = null; }
            _content.Content = null;
            _pdf = null; _pdfStream?.Dispose(); _pdfStream = null;
            // Active native operations observe the cancelled token before releasing their streams.
        };
    }
    private static Button Button(string key, RoutedEventHandler handler)
    {
        var button = new Button { Content = L.T(key), Margin = new Thickness(0, 0, 8, 4), Padding = new Thickness(12, 4, 12, 4), MinHeight = 32 };
        button.SetResourceReference(StyleProperty, "WinButton"); button.Click += handler; return button;
    }
    private async Task LoadPreviewAsync()
    {
        try
        {
            if (!File.Exists(_path)) { Fail("file_moved"); return; }
            switch (FilePreviewPolicy.Classify(_path))
            {
                case PreviewKind.Image:
                    var bitmap = await Task.Run(() => LoadImage(_path, _closed.Token), _closed.Token);
                    _closed.Token.ThrowIfCancellationRequested(); ShowImage(bitmap); _status.Text = ""; break;
                case PreviewKind.Text:
                    var text = await FilePreviewPolicy.ReadTextAsync(_path, _closed.Token);
                    _closed.Token.ThrowIfCancellationRequested();
                    _content.Content = new TextBox { Text = text.Text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, FontFamily = new FontFamily("Consolas"), FontSize = 14, Padding = new Thickness(12) };
                    _status.Text = text.Truncated ? L.T("preview_text_truncated") : ""; break;
                case PreviewKind.Pdf:
                    if (new FileInfo(_path).Length > 512L * 1024 * 1024) throw new IOException("Preview size limit.");
                    var file = await StorageFile.GetFileFromPathAsync(_path).AsTask(_closed.Token);
                    var stream = await file.OpenAsync(FileAccessMode.Read).AsTask(_closed.Token);
                    if (_closed.IsCancellationRequested) { stream.Dispose(); return; }
                    _pdfStream = stream;
                    _pdf = await PdfDocument.LoadFromStreamAsync(stream).AsTask(_closed.Token);
                    _closed.Token.ThrowIfCancellationRequested();
                    if (_pdf.PageCount == 0) throw new IOException("Empty PDF.");
                    _navigation.Visibility = Visibility.Visible; await RenderPageAsync(); break;
                case PreviewKind.Video:
                case PreviewKind.Audio:
                    if (!await FilePreviewPolicy.HasNativeMediaHeaderAsync(_path, _closed.Token)) { Fail("preview_failed"); return; }
                    _closed.Token.ThrowIfCancellationRequested(); LoadMedia(); break;
                default: Fail("preview_unsupported"); break;
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            if (!_closed.IsCancellationRequested) { ActivityLog.Write("preview", ex.GetType().Name); Fail("preview_failed"); }
        }
    }
    private static BitmapSource LoadImage(string path, CancellationToken token)
    {
        if (new FileInfo(path).Length > 256L * 1024 * 1024) throw new IOException("Preview size limit.");
        token.ThrowIfCancellationRequested();
        using var stream = File.OpenRead(path);
        var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None);
        var frame = decoder.Frames[0];
        var width = frame.PixelWidth; var height = frame.PixelHeight;
        if (width <= 0 || height <= 0 || (long)width * height > 200_000_000) throw new IOException("Invalid image dimensions.");
        stream.Position = 0;
        var scale = Math.Min(1d, (double)FilePreviewPolicy.MaximumImageDimension / Math.Max(width, height));
        var image = new BitmapImage(); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad;
        image.DecodePixelWidth = Math.Max(1, (int)(width * scale)); image.DecodePixelHeight = Math.Max(1, (int)(height * scale));
        image.StreamSource = stream; image.EndInit(); image.Freeze(); token.ThrowIfCancellationRequested(); return image;
    }
    private void ShowImage(BitmapSource image) => _content.Content = new Image { Source = image, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private async Task RenderPageAsync()
    {
        var document = _pdf;
        if (document is null || _rendering || _closed.IsCancellationRequested) return;
        _rendering = true; _previous.IsEnabled = false; _next.IsEnabled = false;
        try
        {
            using var page = document.GetPage(_page);
            var w = page.Size.Width; var h = page.Size.Height;
            if (!double.IsFinite(w) || !double.IsFinite(h) || w <= 0 || h <= 0) throw new IOException("Invalid page dimensions.");
            var scale = Math.Min(2048d / w, 2048d / h);
            using var rendered = new InMemoryRandomAccessStream();
            await page.RenderToStreamAsync(rendered, new PdfPageRenderOptions { DestinationWidth = (uint)Math.Max(1, w * scale), DestinationHeight = (uint)Math.Max(1, h * scale) }).AsTask(_closed.Token);
            _closed.Token.ThrowIfCancellationRequested();
            rendered.Seek(0);
            using var stream = rendered.AsStreamForRead();
            var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad; bitmap.StreamSource = stream; bitmap.EndInit(); bitmap.Freeze();
            ShowImage(bitmap); _pageLabel.Text = L.T("preview_page", _page + 1, document.PageCount); _status.Text = "";
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) when (ex is not OutOfMemoryException) { if (!_closed.IsCancellationRequested) Fail("preview_failed"); }
        finally
        {
            _rendering = false;
            if (!_closed.IsCancellationRequested) { _previous.IsEnabled = _page > 0; _next.IsEnabled = _pdf is not null && _page + 1 < _pdf.PageCount; }
        }
    }
    private void LoadMedia()
    {
        var media = new MediaElement { Source = new Uri(_path), LoadedBehavior = MediaState.Manual, UnloadedBehavior = MediaState.Close, Stretch = Stretch.Uniform };
        _media = media;
        media.MediaFailed += (_, _) => { media.Stop(); media.Close(); Fail("preview_failed"); };
        media.MediaOpened += (_, _) => _status.Text = L.T("preview_media_hint");
        var panel = new DockPanel();
        var controls = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        controls.Children.Add(Button("play_media", (_, _) => media.Play()));
        controls.Children.Add(Button("pause_media", (_, _) => media.Pause()));
        controls.Children.Add(Button("stop_media", (_, _) => media.Stop()));
        DockPanel.SetDock(controls, Dock.Bottom); panel.Children.Add(controls); panel.Children.Add(media); _content.Content = panel;
        _status.Text = L.T("preview_media_hint");
        // Start only after an explicit Play action.
    }
    private void TryAction(Action action)
    {
        try { action(); }
        catch (FileNotFoundException) { _status.Text = L.T("file_moved"); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { _status.Text = L.T("open_failed", ex.Message); }
    }
    private void Fail(string key)
    {
        _status.Text = L.T(key);
        _content.Content = new TextBlock { Text = L.T(key), TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 520, FontSize = 16 };
    }
    internal static void Reveal(string path)
    {
        if (!File.Exists(path)) throw new FileNotFoundException(null, path);
        var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe")) { UseShellExecute = false };
        info.ArgumentList.Add("/select,"); info.ArgumentList.Add(Path.GetFullPath(path)); Process.Start(info);
    }
    internal static void OpenPhoto(string path)
    {
        if (!File.Exists(path)) throw new FileNotFoundException(null, path);
        if (FilePreviewPolicy.Classify(path) != PreviewKind.Image) throw new NotSupportedException();
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }
    internal static void OpenWith(string path)
    {
        if (!File.Exists(path)) throw new FileNotFoundException(null, path);
        if (!FilePreviewPolicy.CanOpenExternally(path)) throw new NotSupportedException();
        var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "rundll32.exe")) { UseShellExecute = false };
        info.ArgumentList.Add("shell32.dll,OpenAs_RunDLL"); info.ArgumentList.Add(Path.GetFullPath(path)); Process.Start(info);
    }
}
