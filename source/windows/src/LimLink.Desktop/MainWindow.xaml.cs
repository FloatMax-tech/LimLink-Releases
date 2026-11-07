using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace LimLink.Desktop;

public partial class MainWindow : Window
{
    private const double NarrowWidth = 900;
    private readonly MainViewModel _model;
    private bool? _narrow;
    private DispatcherTimer? _dragWatchdog;

    internal MainWindow(MainViewModel model)
    {
        InitializeComponent();
        _model = model;
        DataContext = model;
        model.Owner = this;
        void SyncForeground() => model.IsForeground = IsVisible && IsActive && WindowState != WindowState.Minimized;
        Activated += (_, _) => SyncForeground();
        Deactivated += (_, _) => SyncForeground();
        IsVisibleChanged += (_, _) => SyncForeground();
        StateChanged += (_, _) => SyncForeground();
        model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(MainViewModel.SettingsOpen) && model.SettingsOpen)
                Dispatcher.BeginInvoke(() => { NameBox.Focus(); NameBox.SelectAll(); }, DispatcherPriority.Input);
        };
        SourceInitialized += (_, _) => ApplyBackdrop();
        SizeChanged += (_, _) => UpdateLayoutMode();
        DragEnter += (_, e) => UpdateDrag(e);
        DragOver += (_, e) => UpdateDrag(e);
        DragLeave += OnDragLeave;
        Drop += OnDrop;
        PreviewKeyDown += OnPreviewKeyDown;
    }

    internal void ApplyBackdrop()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == 0) return;
        Native.SetDarkFrame(hwnd, App.IsDark);
        if (Native.TryEnableMica(hwnd))
        {
            Background = Brushes.Transparent;
            if (HwndSource.FromHwnd(hwnd)?.CompositionTarget is { } target) target.BackgroundColor = Colors.Transparent;
        }
        else SetResourceReference(BackgroundProperty, "WindowFallback");
    }

    private void UpdateLayoutMode()
    {
        var narrow = ActualWidth < NarrowWidth;
        if (narrow == _narrow) return;
        _narrow = narrow;
        Grid.SetRow(HeaderActions, narrow ? 1 : 0);
        Grid.SetColumn(HeaderActions, narrow ? 0 : 1);
        Grid.SetColumnSpan(HeaderActions, narrow ? 2 : 1);
        HeaderActions.Margin = new Thickness(0, narrow ? 8 : 0, 0, 0);
        LeftColumn.Width = narrow ? new GridLength(1, GridUnitType.Star) : new GridLength(410);
        GapColumn.Width = new GridLength(narrow ? 0 : 16);
        RightColumn.Width = narrow ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        Grid.SetRow(PeersCard, narrow ? 1 : 0);
        Grid.SetColumn(PeersCard, narrow ? 0 : 2);
        Grid.SetColumnSpan(PeersCard, narrow ? 3 : 1);
        PeersCard.Margin = new Thickness(0, narrow ? 12 : 0, 0, 0);
    }

    private bool DropAllowed(DragEventArgs e)
        => e.Data.GetDataPresent(DataFormats.FileDrop) && _model.CanAcceptDrop && !_model.HasOffer && !_model.SettingsOpen;

    private void UpdateDrag(DragEventArgs e)
    {
        var allowed = DropAllowed(e);
        e.Effects = allowed ? DragDropEffects.Copy : DragDropEffects.None;
        _model.IsDragOver = allowed;
        // DragOver repeats while the pointer is inside; silence means the drag left without another DragLeave.
        RestartDragWatchdog();
        e.Handled = true;
    }

    private void OnDragLeave(object sender, DragEventArgs e) => RestartDragWatchdog();

    private void RestartDragWatchdog()
    {
        _dragWatchdog ??= new DispatcherTimer(DispatcherPriority.Input, Dispatcher) { Interval = TimeSpan.FromMilliseconds(220) };
        if (!_dragWatchdog.IsEnabled) _dragWatchdog.Tick += OnDragWatchdogTick;
        _dragWatchdog.Stop();
        if (_model.IsDragOver) _dragWatchdog.Start();
    }

    private void OnDragWatchdogTick(object? sender, EventArgs e)
    {
        _dragWatchdog?.Stop();
        _model.IsDragOver = false;
    }

    private void OnDrop(object sender, DragEventArgs e)
    {
        var allowed = DropAllowed(e);
        _dragWatchdog?.Stop();
        _model.IsDragOver = false;
        if (allowed && e.Data.GetData(DataFormats.FileDrop) is string[] files) _model.DropFiles(files);
        e.Handled = true;
    }

    private void OnPeerRowClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: PeerItem peer } && _model.MultiSelectEnabled) _model.TogglePeerSelection(peer);
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape && _model.SettingsOpen) { _model.CloseSettingsCommand.Execute(null); e.Handled = true; }
        else if (e.Key == Key.Enter && _model.SettingsOpen && Keyboard.FocusedElement is not Button) { _model.SaveSettingsCommand.Execute(null); e.Handled = true; }
        else if (e.Key == Key.O && Keyboard.Modifiers == ModifierKeys.Control && !_model.SettingsOpen && !_model.HasOffer) { _model.ChooseFileCommand.Execute(null); e.Handled = true; }
    }
}
