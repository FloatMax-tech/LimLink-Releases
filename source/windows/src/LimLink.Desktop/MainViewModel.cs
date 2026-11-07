using RecentEntry = LimLink.Files.RecentTransferRecord;
using LimLink.Files;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Net.Sockets;
using System.Windows;
using System.Windows.Input;
using System.Windows.Shell;
using System.Windows.Threading;

namespace LimLink.Desktop;

internal sealed partial class MainViewModel : Observable, IAsyncDisposable
{
    private readonly string _data;
    private readonly ToastService _toasts;
    private readonly Dispatcher _ui;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly DispatcherTimer _clock;
    private readonly DispatcherTimer _noticeTimer;
    private readonly Dictionary<string, long> _receiveThrottle = [];
    private readonly List<RecentEntry> _recent;
    private readonly PictureExportStore _pictureExports;
    private readonly VerifiedReceiveCompletions _completedReceiveSessions = new();
    private bool _resumedPictureExports;
    private bool _editAutoSaveReceivedImages;
    private LimLinkNode? _node;
    private LanDiscovery? _discovery;
    private CancellationTokenSource? _sending;
    private CancellationTokenSource? _doneReset;
    private bool _multiSelect;
    private PeerItem? _target;
    private bool _changingHost;
    private bool _disposed;
    private int _step = -1;
    private DateTime _speedAt;
    private long _speedBytes;
    private double _rate;

    private StartupState _startup = StartupState.Starting;
    private string _startupError = "";
    private ComposerState _composer = ComposerState.Empty;
    private readonly List<string> _files = [];
    private string? _filePath;
    private string _fileName = "";
    private long _fileSize;
    private double _sendFraction;
    private bool _sendSpinning;
    private string _sendPercent = "";
    private string _sendBytes = "";
    private string _sendStatus = "";
    private string _speedText = "";
    private string _remainingText = "";
    private string _resultTitle = "";
    private string _resultDetail = "";
    private string _notice = "";
    private bool _noticeIsError;
    private bool _hasNotice;
    private OfferItem? _currentOffer;
    private string _moreOffers = "";
    private TaskbarItemProgressState _taskbarState;
    private double _taskbarValue;
    private bool _isDragOver;
    private bool _settingsOpen;
    private string _editName = "";
    private string _editDirectory = "";
    private bool _editCloseToTray;
    private string _settingsError = "";
    private string _editLanguage = "";

    public MainViewModel(string dataDirectory, ToastService toasts, Dispatcher ui)
    {
        _data = dataDirectory;
        _toasts = toasts;
        _ui = ui;
        Settings = AppSettings.Load(dataDirectory);
        _recent = RecentStore.Load(dataDirectory);
        var pictures = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
        _pictureExports = new PictureExportStore(Path.Combine(dataDirectory, "picture-exports.json"), Path.Combine(pictures, "LimLink"));
        foreach (var entry in _recent.Take(4)) Recent.Add(new RecentItem(entry));
        _toasts.OfferDecided += (sid, accept) => { if (Offers.FirstOrDefault(o => o.SessionId == sid) is { } offer) Resolve(offer, accept); };
        Localization.Current.LanguageChanged += OnLanguageChanged;
        Steps.Add(new StepItem(L.T("step_connect")));
        Steps.Add(new StepItem(L.T("step_accept")));
        Steps.Add(new StepItem(L.T("step_transfer")));
        Steps.Add(new StepItem(L.T("step_verify"), isLast: true));
        _clock = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => Tick(), ui);
        _clock.Start();
        _noticeTimer = new DispatcherTimer(DispatcherPriority.Background, ui) { Interval = TimeSpan.FromSeconds(6) };
        _noticeTimer.Tick += (_, _) => { _noticeTimer.Stop(); Notice = ""; };

        OpenBindingPickerCommand = new RelayCommand(_ => BindingPickerOpen = true);
        CloseBindingPickerCommand = new RelayCommand(_ => BindingPickerOpen = false);
        BindCommand = new RelayCommand(p => { if (p is PeerItem peer) _ = BindAsync(peer); });
        UnbindCommand = new RelayCommand(p => { if (p is DeviceBinding record) _ = UnbindAsync(record); });
        CancelBindingCommand = new RelayCommand(_ => _bindingCancellation?.Cancel());
        AcceptBindingCommand = new RelayCommand(_ => _bindingConsent?.TrySetResult(true));
        RejectBindingCommand = new RelayCommand(_ => _bindingConsent?.TrySetResult(false));
        ChooseFileCommand = new RelayCommand(_ => ChooseFile());
        RemoveFileCommand = new RelayCommand(_ => ClearFile());
        SendCommand = new RelayCommand(p => { if (p is PeerItem peer) _ = SendAsync(peer); });
        SendSelectedCommand = new RelayCommand(_ => { var selected = Peers.Where(p => p.Selected).ToList(); if (selected.Count > 0) _ = SendManyAsync(selected); });
        CancelSendCommand = new RelayCommand(_ => _sending?.Cancel());
        DoneCommand = new RelayCommand(_ => ClearFile());
        RetryCommand = new RelayCommand(_ => { if (_target is { } peer && Peers.Contains(peer)) _ = SendAsync(peer); else Composer = ComposerState.Selected; });
        BackCommand = new RelayCommand(_ => Composer = _filePath is null ? ComposerState.Empty : ComposerState.Selected);
        AcceptCommand = new RelayCommand(_ => { if (HasOffer && CurrentOffer is { } offer) Resolve(offer, true); });
        RejectCommand = new RelayCommand(_ => { if (HasOffer && CurrentOffer is { } offer) Resolve(offer, false); });
        OpenReceiveFolderCommand = new RelayCommand(_ => OpenFolder(Settings.ReceiveDirectory));
        ChangeReceiveFolderCommand = new RelayCommand(_ => _ = ChangeReceiveFolderAsync());
        OpenSettingsCommand = new RelayCommand(_ => OpenSettings());
        CloseSettingsCommand = new RelayCommand(_ => SettingsOpen = false);
        OpenPrivacyPolicyCommand = new RelayCommand(_ => OpenLegalDocument(privacy: true));
        OpenUsageTermsCommand = new RelayCommand(_ => OpenLegalDocument(privacy: false));
        SaveSettingsCommand = new RelayCommand(_ => _ = SaveSettingsAsync());
        BrowseSettingsFolderCommand = new RelayCommand(_ => { if (PickFolder(EditDirectory) is { } folder) EditDirectory = folder; });
        RetryStartCommand = new RelayCommand(_ => _ = StartAsync());
        DismissNoticeCommand = new RelayCommand(_ => Notice = "");
        RevealCommand = new RelayCommand(p => { if (p is RecentItem { Entry.Path: { } path }) Reveal(path); });
        OpenRecentCommand = new RelayCommand(p => { if (p is RecentItem { Entry.Path: { } path }) PreviewFile(path); });
        PreviewSelectedCommand = new RelayCommand(_ => PreviewSelectedFiles());
        RevealSelectedCommand = new RelayCommand(_ => { if (_files.Count == 1) Reveal(_files[0]); else PreviewSelectedFiles(); });
        PreviewPathCommand = new RelayCommand(p => { if (p is string path) PreviewFile(path); });
        OpenLocationCommand = new RelayCommand(p => { if (p is RecentItem item) OpenRecentLocation(item); });
        RetryPhotoCommand = new RelayCommand(p => { if (p is RecentItem item) _ = ExportPictureAsync(item.Entry); });
        DeleteRecentCommand = new RelayCommand(p => { if (p is RecentItem item) DeleteRecentFile(item); });
        RemoveRecentCommand = new RelayCommand(p => { if (p is RecentItem item) RemoveRecent(item.Entry); });
    }

    public AppSettings Settings { get; }
    public Window? Owner { get; set; }
    /// <summary>Updated on the UI thread; read from transfer threads without touching WPF objects.</summary>
    private volatile bool _foreground = true;
    public bool IsForeground { get => _foreground; set => _foreground = value; }
    public event Action<string>? TrayTextChanged;
    /// <summary>An incoming offer needs the user; true means no notification could be shown, so the window must appear.</summary>
    public event Action<bool>? AttentionRequested;

    public ObservableCollection<PeerItem> Peers { get; } = [];
    public ObservableCollection<OfferItem> Offers { get; } = [];
    public ObservableCollection<ReceiveItem> Receives { get; } = [];
    public ObservableCollection<RecentItem> Recent { get; } = [];
    public ObservableCollection<StepItem> Steps { get; } = [];

    public ICommand OpenBindingPickerCommand { get; }
    public ICommand CloseBindingPickerCommand { get; }
    private bool _bindingPickerOpen;
    public bool BindingPickerOpen { get => _bindingPickerOpen; private set => Set(ref _bindingPickerOpen, value); }
    public ICommand BindCommand { get; }
    public ICommand UnbindCommand { get; }
    public ICommand CancelBindingCommand { get; }
    public ICommand AcceptBindingCommand { get; }
    public ICommand RejectBindingCommand { get; }
    public ObservableCollection<DeviceBinding> BoundDevices { get; } = [];
    private CancellationTokenSource? _bindingCancellation;
    private TaskCompletionSource<bool>? _bindingConsent;
    private bool _bindingConsentOpen, _bindingWaiting;
    private string _bindingAlias = "";
    public bool BindingConsentOpen { get => _bindingConsentOpen; private set => Set(ref _bindingConsentOpen, value); }
    public bool BindingWaiting { get => _bindingWaiting; private set => Set(ref _bindingWaiting, value); }
    public string BindingAlias { get => _bindingAlias; private set => Set(ref _bindingAlias, value); }
    public ICommand ChooseFileCommand { get; }
    public ICommand RemoveFileCommand { get; }
    public ICommand SendCommand { get; }
    public ICommand SendSelectedCommand { get; }
    public ICommand CancelSendCommand { get; }
    public ICommand DoneCommand { get; }
    public ICommand RetryCommand { get; }
    public ICommand BackCommand { get; }
    public ICommand AcceptCommand { get; }
    public ICommand RejectCommand { get; }
    public ICommand OpenReceiveFolderCommand { get; }
    public ICommand ChangeReceiveFolderCommand { get; }
    public ICommand OpenSettingsCommand { get; }
    public ICommand CloseSettingsCommand { get; }
    public ICommand OpenPrivacyPolicyCommand { get; }
    public ICommand OpenUsageTermsCommand { get; }
    public ICommand SaveSettingsCommand { get; }
    public ICommand BrowseSettingsFolderCommand { get; }
    public ICommand RetryStartCommand { get; }
    public ICommand DismissNoticeCommand { get; }
    public ICommand RevealCommand { get; }
    public ICommand OpenRecentCommand { get; }
    public ICommand PreviewSelectedCommand { get; }
    public ICommand PreviewPathCommand { get; }
    public ICommand RevealSelectedCommand { get; }
    public ICommand OpenLocationCommand { get; }
    public ICommand RetryPhotoCommand { get; }
    public bool EditAutoSaveReceivedImages { get => _editAutoSaveReceivedImages; set => Set(ref _editAutoSaveReceivedImages, value); }
    public ICommand DeleteRecentCommand { get; }
    public ICommand RemoveRecentCommand { get; }

    public string DeviceName => Settings.DeviceName;
    public string ReceiveDirectory => Settings.ReceiveDirectory;
    public StartupState Startup { get => _startup; private set { if (Set(ref _startup, value)) UpdatePeerSummary(); } }
    public string StartupError { get => _startupError; private set => Set(ref _startupError, value); }
    public ComposerState Composer { get => _composer; private set { if (Set(ref _composer, value)) UpdateCanSend(); } }
    public string FileName { get => _fileName; private set => Set(ref _fileName, value); }
    public string FileSizeText => Format.Size(_fileSize);
    public double SendFraction { get => _sendFraction; private set => Set(ref _sendFraction, value); }
    public bool SendSpinning { get => _sendSpinning; private set => Set(ref _sendSpinning, value); }
    public string SendPercent { get => _sendPercent; private set => Set(ref _sendPercent, value); }
    public string SendBytes { get => _sendBytes; private set => Set(ref _sendBytes, value); }
    public string SendStatus { get => _sendStatus; private set => Set(ref _sendStatus, value); }
    public string SpeedText { get => _speedText; private set => Set(ref _speedText, value); }
    public string RemainingText { get => _remainingText; private set => Set(ref _remainingText, value); }
    public bool ShowStats => _step == 2 && _speedText.Length > 0;
    public string ResultTitle { get => _resultTitle; private set => Set(ref _resultTitle, value); }
    public string ResultDetail { get => _resultDetail; private set => Set(ref _resultDetail, value); }
    // Clearing keeps the old text so the bar can fade out with it.
    public string Notice
    {
        get => _notice;
        private set
        {
            if (value.Length > 0) Set(ref _notice, value);
            Set(ref _hasNotice, value.Length > 0, nameof(HasNotice));
        }
    }
    public bool HasNotice => _hasNotice;
    public bool NoticeIsError { get => _noticeIsError; private set => Set(ref _noticeIsError, value); }
    // Kept after the last offer resolves so the dialog can fade out with its content.
    public OfferItem? CurrentOffer { get => _currentOffer; private set { if (value is not null) Set(ref _currentOffer, value); OnPropertyChanged(nameof(HasOffer)); } }
    public bool HasOffer => Offers.Count > 0;
    public string MoreOffers { get => _moreOffers; private set => Set(ref _moreOffers, value); }
    public string PeerCount => Peers.Count == 0 ? "" : L.T("peer_count", Peers.Count);
    public string BatchButtonText => L.T("send_to_devices", SelectedCount);
    /// <summary>Multi-select sends the same file to several devices in turn.</summary>
    public bool MultiSelectEnabled
    {
        get => _multiSelect;
        set
        {
            if (!Set(ref _multiSelect, value)) return;
            if (!value) foreach (var peer in Peers) peer.Selected = false;
            OnPropertyChanged(nameof(SelectedCount));
            OnPropertyChanged(nameof(BatchButtonText));
            OnPropertyChanged(nameof(BatchCanSend));
            UpdateCanSend();
        }
    }
    public int SelectedCount => Peers.Count(p => p.Selected);
    public bool BatchCanSend => _multiSelect && SelectedCount > 0 && Startup == StartupState.Ready && _files.Count > 0 && _sending is null && !_changingHost;

    public void TogglePeerSelection(PeerItem peer)
    {
        if (!_multiSelect || _sending is not null) return;
        peer.Selected = !peer.Selected;
        OnPropertyChanged(nameof(SelectedCount));
        OnPropertyChanged(nameof(BatchButtonText));
        OnPropertyChanged(nameof(BatchCanSend));
    }

    public bool ShowRadar => Startup != StartupState.Failed && Peers.Count == 0;
    public string RadarText => Startup == StartupState.Starting ? L.T("radar_starting") : L.T("radar_searching");
    public IReadOnlyList<LanguageOption> Languages => Localization.Current.Options;
    public bool HasRecent => Recent.Count > 0;
    public TaskbarItemProgressState TaskbarState { get => _taskbarState; private set => Set(ref _taskbarState, value); }
    public double TaskbarValue { get => _taskbarValue; private set => Set(ref _taskbarValue, value); }
    public bool IsDragOver { get => _isDragOver; set => Set(ref _isDragOver, value); }
    public bool CanAcceptDrop => _sending is null && !_changingHost;
    public bool SettingsOpen { get => _settingsOpen; private set => Set(ref _settingsOpen, value); }
    public string EditName { get => _editName; set => Set(ref _editName, value); }
    public string EditDirectory { get => _editDirectory; set => Set(ref _editDirectory, value); }
    public bool EditCloseToTray { get => _editCloseToTray; set => Set(ref _editCloseToTray, value); }
    public string SettingsError { get => _settingsError; private set => Set(ref _settingsError, value); }
    public string EditLanguage { get => _editLanguage; set => Set(ref _editLanguage, value); }
    private static Localization L => Localization.Current;

    public async Task StartAsync()
    {
        if (_changingHost || _disposed) return;
        _changingHost = true;
        Startup = StartupState.Starting;
        UpdateCanSend();
        LimLinkNode? node = null;
        LanDiscovery? discovery = null;
        try
        {
            node = await LimLinkNode.StartAsync(new LimLinkNodeOptions { DataDirectory = _data, ReceiveDirectory = Settings.ReceiveDirectory, DeviceAlias = Settings.DeviceName, ConfirmReceive = ConfirmAsync, ConfirmBinding = ConfirmBindingAsync, LoggerFactory = ActivityLoggerFactory.Instance, Trace = message => ActivityLog.Write("kestrel", message) }, _lifetime.Token);
            node.Receiver.ReceiveProgressChanged += OnReceiveProgress;
            discovery = new LanDiscovery(Settings.DeviceName, node.Fingerprint, node.Port, node.AppPolicy);
            discovery.PeersChanged += peers => Ui(() => SetPeers(peers));
            discovery.Error += error => Ui(() => ShowNotice(L.T("discovery_interrupted", error.Message), true));
            _node = node;
            node.Binding.Changed += () => Ui(RefreshBindings);
            RefreshBindings();
            if (node.Binding.StorageError is not null) ShowNotice(L.T("binding_storage_error"), true);
            _discovery = discovery;
            SetPeers(discovery.Peers);
            Startup = StartupState.Ready;
            if (!_resumedPictureExports) { _resumedPictureExports = true; _ = ResumePictureExportsAsync(); }
            ActivityLog.Write("node", $"ready name=\"{Settings.DeviceName}\" port={node.Port} receive=\"{Settings.ReceiveDirectory}\" fp={node.Fingerprint[..8]}");
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            if (discovery is not null) await discovery.DisposeAsync();
            if (node is not null) await node.DisposeAsync();
            _node = null;
            _discovery = null;
            SetPeers([]);
            if (_lifetime.IsCancellationRequested) return;
            ActivityLog.Write("node", "start failed: " + ex.Message);
            StartupError = ex switch
            {
                IOException when ex.Message.Contains("IPv4", StringComparison.Ordinal) => L.T("startup_no_lan"),
                UnauthorizedAccessException => L.T("startup_receive_unavailable"),
                SocketException socket => L.T("startup_port_unavailable", socket.SocketErrorCode),
                _ => L.T("startup_failed", ex.Message),
            };
            Startup = StartupState.Failed;
        }
        finally
        {
            _changingHost = false;
            UpdateCanSend();
            UpdateActivity();
        }
    }

    private void RefreshBindings()
    {
        BoundDevices.Clear();
        if (_node is not null) foreach (var record in _node.Binding.Bindings) BoundDevices.Add(record);
    }
    private async Task BindAsync(PeerItem peer)
    {
        if (_node is null || _bindingCancellation is not null) return;
        BindingPickerOpen = false;
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        _bindingCancellation = cancel; BindingWaiting = true; BindingAlias = peer.DisplayName;
        try { using var client = _node.CreateClient(); await client.BindAsync(peer.Peer, cancellationToken: cancel.Token); ShowNotice(L.T("binding_done"), false); RefreshBindings(); }
        catch (OperationCanceledException) { ShowNotice(L.T("binding_cancelled"), false); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { ShowNotice(L.T("binding_failed"), true); }
        finally { _bindingCancellation = null; BindingWaiting = false; }
    }
    private async Task UnbindAsync(DeviceBinding record)
    {
        if (_node is null) return;
        try
        {
            using var client = _node.CreateClient();
            var notified = await client.UnbindAsync(record.PeerFingerprint, Peers.FirstOrDefault(p => p.Peer.Fingerprint == record.PeerFingerprint)?.Peer, _lifetime.Token);
            ShowNotice(L.T(notified ? "binding_removed" : "binding_removed_offline"), false);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) { ShowNotice(L.T("binding_storage_error"), true); }
        finally { RefreshBindings(); }
    }
    private async Task<bool> ConfirmBindingAsync(BindingOffer offer, CancellationToken token)
    {
        var decision = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        Ui(() => { if (token.IsCancellationRequested) return; _bindingConsent = decision; BindingAlias = offer.Alias; BindingConsentOpen = true; AttentionRequested?.Invoke(true); });
        try { return await decision.Task.WaitAsync(token); }
        finally { Ui(() => { if (_bindingConsent == decision) { _bindingConsent = null; BindingConsentOpen = false; } }); }
    }

    private async Task StopNodeAsync()
    {
        _bindingCancellation?.Cancel();
        _bindingConsent?.TrySetResult(false);
        var discovery = _discovery;
        var node = _node;
        _discovery = null;
        _node = null;
        if (discovery is not null) await discovery.DisposeAsync();
        if (node is not null) await node.DisposeAsync();
        foreach (var offer in Offers.ToArray()) Resolve(offer, false);
        Receives.Clear();
    }

    private void Ui(Action action)
    {
        if (_disposed) return;
        _ui.BeginInvoke(() => { if (!_disposed) action(); });
    }

    private void SetPeers(IReadOnlyList<DiscoveryPeer> peers)
    {
        var present = peers.Select(p => p.Fingerprint).ToHashSet();
        for (var i = Peers.Count - 1; i >= 0; i--)
            if (!present.Contains(Peers[i].Fingerprint) && Peers[i] != _target) Peers.RemoveAt(i);
        for (var i = 0; i < peers.Count; i++)
        {
            var existing = Peers.FirstOrDefault(p => p.Fingerprint == peers[i].Fingerprint);
            if (existing is null) Peers.Insert(Math.Min(i, Peers.Count), new PeerItem(peers[i]));
            else existing.Peer = peers[i];
        }
        UpdatePeerSummary();
        UpdateCanSend();
        ActivityLog.Write("discovery", peers.Count == 0 ? "no peers" : string.Join(", ", peers.Select(p => $"{p.Name}/{p.DeviceType}/{p.Host}")));
    }

    private void UpdatePeerSummary()
    {
        OnPropertyChanged(nameof(PeerCount));
        OnPropertyChanged(nameof(ShowRadar));
        OnPropertyChanged(nameof(RadarText));
        OnPropertyChanged(nameof(SelectedCount));
        OnPropertyChanged(nameof(BatchButtonText));
        OnPropertyChanged(nameof(BatchCanSend));
    }

    private void UpdateCanSend()
    {
        var ready = Startup == StartupState.Ready && !_changingHost && _files.Count > 0 && _sending is null && Composer is ComposerState.Selected or ComposerState.Failed or ComposerState.Done;
        foreach (var peer in Peers)
        {
            peer.CanSend = ready;
            peer.Dimmed = _sending is not null && peer != _target;
        }
        OnPropertyChanged(nameof(CanAcceptDrop));
        OnPropertyChanged(nameof(BatchCanSend));
    }

    // ---------- file selection ----------

    private void ChooseFile()
    {
        if (!CanAcceptDrop) return;
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = L.T("file_dialog_title"), CheckFileExists = true, Multiselect = true };
        if (dialog.ShowDialog(Owner) == true) SelectFiles(dialog.FileNames);
    }

    public void OpenFile(string path)
    {
        if (CanAcceptDrop) SelectFile(path);
        else ShowNotice(L.T("notice_cannot_pick"), true);
    }

    public void DropFiles(string[] paths)
    {
        IsDragOver = false;
        if (!CanAcceptDrop) return;
        SelectFiles(paths);
    }

    private void SelectFile(string path) => SelectFiles([path]);

    /// <summary>Appends files to the queue. Every file is sent to each chosen device in turn.</summary>
    private void SelectFiles(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return;
        var skipped = 0;
        foreach (var path in paths)
        {
            if (Directory.Exists(path)) { skipped++; continue; }
            var info = new FileInfo(path);
            if (!info.Exists || info.Length > TransferLimits.MaximumFileBytes) { skipped++; continue; }
            if (_files.Contains(info.FullName, StringComparer.OrdinalIgnoreCase)) continue;
            _files.Add(info.FullName);
        }
        if (_files.Count == 0) { ShowNotice(L.T("notice_no_files"), true); return; }
        CancelDoneReset();
        _filePath = _files[0];
        _fileSize = _files.Sum(p => new FileInfo(p).Length);
        FileName = _files.Count == 1 ? Path.GetFileName(_files[0]) : L.T("files_count", _files.Count);
        OnPropertyChanged(nameof(FileSizeText));
        Composer = ComposerState.Selected;
        UpdateCanSend();
        if (skipped > 0) ShowNotice(L.T("notice_skipped", skipped), true);
    }

    private void ScheduleDoneReset()
    {
        _doneReset?.Cancel();
        _doneReset?.Dispose();
        var reset = new CancellationTokenSource();
        _doneReset = reset;
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(TimeSpan.FromSeconds(3), reset.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            Ui(() =>
            {
                if (Composer != ComposerState.Done || _sending is not null) return;
                _files.Clear();
                _filePath = null;
                _fileSize = 0;
                FileName = "";
                Composer = ComposerState.Empty;
                UpdateCanSend();
            });
        });
    }

    private void CancelDoneReset()
    {
        _doneReset?.Cancel();
        _doneReset?.Dispose();
        _doneReset = null;
    }

    private void ClearFile()
    {
        if (_sending is not null) return;
        CancelDoneReset();
        _files.Clear();
        _filePath = null;
        _fileSize = 0;
        FileName = "";
        Composer = ComposerState.Empty;
    }

    // ---------- sending ----------

    private Task SendAsync(PeerItem peer) => SendManyAsync([peer]);

    /// <summary>Sends the selected file to each device in turn; the panel stays in the sending state between peers.</summary>
    private async Task SendManyAsync(IReadOnlyList<PeerItem> peers)
    {
        if (_changingHost || _node is null || _files.Count == 0 || _sending is not null || peers.Count == 0) return;
        var files = _files.ToArray();
        var name = files.Length == 1 ? Path.GetFileName(files[0]) : L.T("files_count", files.Length);
        var total = peers.Count * files.Length;
        CancelDoneReset();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        _sending = cancellation;
        foreach (var peer in peers) peer.Selected = false;
        OnPropertyChanged(nameof(SelectedCount));
        OnPropertyChanged(nameof(BatchButtonText));
        OnPropertyChanged(nameof(BatchCanSend));
        Composer = ComposerState.Sending;
        UpdateCanSend();
        UpdateActivity();
        var ok = 0;
        var failed = 0;
        string? lastError = null;
        try
        {
            for (var i = 0; i < peers.Count; i++)
            {
                foreach (var file in files)
                {
                    try
                    {
                        SendStatus = L.T("send_status_batch", ok + failed + 1, total, Path.GetFileName(file));
                        var error = await SendOneAsync(peers[i], file, cancellation.Token);
                        if (error is null) ok++; else { failed++; lastError = error; }
                    }
                    catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
                    {
                        failed += total - (ok + failed);
                        if (_lifetime.IsCancellationRequested) return;
                        if (ok == 0) { Composer = ComposerState.Selected; ShowNotice(L.T("notice_send_cancelled"), false); }
                        else { Composer = ComposerState.Failed; ResultTitle = L.T("result_cancelled"); ResultDetail = L.T("result_cancelled_detail", ok); }
                        ActivityLog.Write("send", $"batch cancelled ok={ok} failed={failed}");
                        return;
                    }
                }
            }
            if (failed == 0)
            {
                SetStep(4);
                SendFraction = 1;
                ResultTitle = L.T("result_delivered");
                ResultDetail = peers.Count == 1 && files.Length == 1 ? L.T("result_delivered_single", peers[0].DisplayName, name) : L.T("result_delivered_multi", ok, peers.Count);
                Composer = ComposerState.Done;
                ScheduleDoneReset();
                if (!IsForeground) _toasts.ShowInfo(L.T("toast_delivered"), peers.Count == 1 ? L.T("toast_delivered_single", peers[0].DisplayName, name) : L.T("toast_delivered_multi", ok, name));
            }
            else
            {
                ResultTitle = ok > 0 ? L.T("result_partial") : L.T("result_failed");
                ResultDetail = ok > 0 ? L.T("result_partial_detail", ok, failed) : lastError ?? L.T("result_incomplete");
                Composer = ComposerState.Failed;
                ActivityLog.Write("send", $"batch finished ok={ok} failed={failed} last={lastError}");
            }
        }
        finally
        {
            _sending = null;
            UpdateCanSend();
            UpdateActivity();
        }
    }

    private async Task<string?> SendOneAsync(PeerItem peer, string path, CancellationToken cancellationToken)
    {
        if (_lifetime.IsCancellationRequested) throw new OperationCanceledException();
        if (_target is not null && _target != peer && _target.State != PeerState.Delivered) _target.State = PeerState.Idle;
        _target = peer;
        peer.State = PeerState.Sending;
        _rate = 0;
        _speedBytes = 0;
        _speedAt = DateTime.UtcNow;
        SetStep(-1);
        SendFraction = 0;
        SendSpinning = true;
        SendPercent = "";
        SendBytes = Format.Size(new FileInfo(path).Length);
        SendStatus = L.T("send_preparing_file");
        peer.Spinning = true;
        peer.Status = L.T("send_preparing");
        try
        {
            using var client = _node!.CreateClient();
            var result = await client.SendFileAsync(peer.Peer, path, Path.Combine(_data, "send-staging"), new Progress<TransferProgress>(p => OnSendProgress(peer, p)), cancellationToken);
            peer.State = PeerState.Delivered;
            peer.Status = L.T("send_just_delivered");
            peer.DeliveredAt = DateTimeOffset.Now;
            AddRecent(new RecentEntry(Path.GetFileName(path), peer.DisplayName, false, path, DateTimeOffset.Now));
            ActivityLog.Write("send", $"sent \"{result.FinalName}\" to \"{peer.DisplayName}\"");
            return null;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            peer.State = PeerState.Idle;
            throw;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            peer.State = PeerState.Idle;
            ActivityLog.Write("send", $"failed to \"{peer.DisplayName}\": {ex.GetType().Name} {ex.Message}");
            return DescribeSendError(ex, peer.DisplayName);
        }
        finally
        {
            peer.Spinning = false;
        }
    }

    private void OnSendProgress(PeerItem peer, TransferProgress p)
    {
        if (_sending is null || _target != peer) return;
        var name = peer.DisplayName;
        switch (p.State)
        {
            case "Preparing file":
                SetStep(-1); SendStatus = L.T("send_preparing_file"); peer.Status = L.T("send_preparing"); break;
            case "Connecting":
                SetStep(0); SendStatus = L.T("send_connecting", name); peer.Status = L.T("send_connecting_short"); break;
            case "Waiting for receiver approval":
                SetStep(1); SendStatus = L.T("send_waiting", name); peer.Status = L.T("send_waiting_short"); break;
            case "Sending" when p.BytesSent >= p.TotalBytes:
                SetStep(3); SendStatus = L.T("send_verifying", name); peer.Status = L.T("send_verifying_short"); break;
            case "Sending":
                SetStep(2); SendStatus = L.T("send_sending", name); break;
        }
        var spinning = _step is < 2;
        SendSpinning = spinning;
        peer.Spinning = spinning;
        var fraction = p.TotalBytes == 0 ? (_step >= 3 ? 1 : 0) : (double)p.BytesSent / p.TotalBytes;
        SendFraction = fraction;
        peer.Fraction = fraction;
        SendPercent = spinning ? "" : $"{Format.Percent(fraction)}%";
        SendBytes = $"{Format.Size(p.BytesSent)} / {Format.Size(p.TotalBytes)}";
        if (_step == 2)
        {
            peer.Status = L.T("send_progress", Format.Percent(fraction));
            var now = DateTime.UtcNow;
            var elapsed = (now - _speedAt).TotalSeconds;
            if (elapsed >= 0.5)
            {
                var instant = (p.BytesSent - _speedBytes) / elapsed;
                _rate = _rate == 0 ? instant : _rate * 0.7 + instant * 0.3;
                _speedAt = now;
                _speedBytes = p.BytesSent;
                if (_rate > 0)
                {
                    SpeedText = Format.Size((long)_rate) + "/s";
                    RemainingText = Format.Remaining((p.TotalBytes - p.BytesSent) / _rate);
                }
            }
        }
        OnPropertyChanged(nameof(ShowStats));
        UpdateActivity();
    }

    private void SetStep(int step)
    {
        if (step == 2 && _step < 2) { _speedAt = DateTime.UtcNow; _speedBytes = 0; _rate = 0; SpeedText = ""; RemainingText = ""; }
        _step = step;
        for (var i = 0; i < Steps.Count; i++) Steps[i].State = i < step ? StepState.Done : i == step ? StepState.Now : StepState.Todo;
        OnPropertyChanged(nameof(ShowStats));
    }

    private string DescribeSendError(Exception ex, string name) => ex switch
    {
        TransferException { Code: "E_REJECTED" } or TransferException { Code: "E_INVALID_STATE" } when _step <= 1 => L.T("error_rejected", name),
        TransferException { Code: "E_DECISION_TIMEOUT" } => L.T("error_timeout", name),
        TransferException { Code: "E_BUSY" } => L.T("error_busy", name),
        TransferException { Code: "E_APP_MISMATCH" } => L.T("error_mismatch"),
        TransferException { Code: "E_FILE_TOO_LARGE" } => L.T("error_too_large"),
        TransferException { Code: "E_CHECKSUM_MISMATCH" } => L.T("error_checksum"),
        TransferException { Code: "E_WRITE_FAILED" } => L.T("error_write", name),
        TransferException { Code: "E_SESSION_EXPIRED" or "E_SESSION_CANCELLED" or "E_SESSION_NOT_FOUND" } => L.T("error_session"),
        TransferException transfer => L.T("error_transfer_prefix", transfer.Message),
        OperationCanceledException when _step == 1 => L.T("error_timeout", name),
        OperationCanceledException => L.T("error_connection_timeout"),
        LimLinkConnectionException { Failure: LimLinkConnectionFailure.FingerprintMismatch } => L.T("error_fingerprint"),
        LimLinkConnectionException or SocketException => L.T("error_connect", name),
        System.Security.Authentication.AuthenticationException => L.T("error_tls", name),
        FileNotFoundException => L.T("error_file_missing"),
        UnauthorizedAccessException => L.T("error_no_read"),
        IOException => L.T("error_connection_lost"),
        _ => L.T("error_transfer_prefix", ex.Message),
    };

    // ---------- receiving ----------

    private async Task<bool> ConfirmAsync(IncomingOffer offer, CancellationToken cancellationToken)
    {
        var item = new OfferItem(offer, Settings.ReceiveDirectory);
        ActivityLog.Write("consent", $"offer \"{offer.FileName}\" {offer.Size} from \"{offer.SenderName}\" session={offer.SessionId[..8]} foreground={IsForeground}");
        Ui(() =>
        {
            if (cancellationToken.IsCancellationRequested) { item.Decision.TrySetResult(false); return; }
            Offers.Add(item);
            RefreshOffer();
            if (!IsForeground)
            {
                _toasts.ShowOffer(offer, item.SaveDirectory, item.Deadline);
                AttentionRequested?.Invoke(!_toasts.CanNotify);
            }
        });
        using var registration = cancellationToken.Register(() => Ui(() => Resolve(item, false)));
        return await item.Decision.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
    }

    private void Resolve(OfferItem offer, bool accept)
    {
        var reason = new System.Diagnostics.StackTrace().GetFrame(1)?.GetMethod()?.Name ?? "?";
        ActivityLog.Write("consent", $"decision {(accept ? "accept" : "decline")} by={reason} session={offer.SessionId[..8]}");
        offer.Decision.TrySetResult(accept);
        _toasts.HideOffer(offer.SessionId);
        if (Offers.Remove(offer)) RefreshOffer();
    }

    private void RefreshOffer()
    {
        CurrentOffer = Offers.FirstOrDefault();
        if (HasOffer) CurrentOffer?.Tick();
        MoreOffers = Offers.Count > 1 ? L.T("offer_more", Offers.Count - 1) : "";
    }

    /// <summary>Raised under the receiver lock; dispatch only, throttled per session.</summary>
    private void OnReceiveProgress(ReceiveProgress progress)
    {
        if (progress.State == ReceiveState.Receiving && progress.ReceivedBytes > 0 && progress.ReceivedBytes < progress.TotalBytes)
        {
            var now = Environment.TickCount64;
            if (_receiveThrottle.TryGetValue(progress.SessionId, out var last) && now - last < 120) return;
            _receiveThrottle[progress.SessionId] = now;
        }
        else if (progress.State != ReceiveState.Receiving) _receiveThrottle.Remove(progress.SessionId);
        Ui(() => ApplyReceive(progress));
    }

    private void ApplyReceive(ReceiveProgress progress)
    {
        var item = Receives.FirstOrDefault(r => r.SessionId == progress.SessionId);
        switch (progress.State)
        {
            case ReceiveState.Receiving:
                if (item is null) Receives.Add(item = new ReceiveItem(progress));
                item.Received = progress.ReceivedBytes;
                break;
            case ReceiveState.Completed:
                if (progress.SavedPath is null || !_completedReceiveSessions.TryAccept(progress)) return;
                if (item is null) Receives.Add(item = new ReceiveItem(progress));
                item.Received = progress.TotalBytes; item.SavedPath = progress.SavedPath; item.Completed = true; item.CompletedAt = DateTimeOffset.Now;
                ActivityLog.Write("receive", $"saved \"{progress.SavedPath}\" from \"{progress.SenderName}\"");
                var exportPending = Settings.AutoSaveReceivedImages && FilePreviewPolicy.Classify(progress.SavedPath) == PreviewKind.Image;
                var received = new RecentEntry(progress.FileName, progress.SenderName, true, progress.SavedPath, DateTimeOffset.Now, progress.SessionId, PhotoExportPending: exportPending);
                AddRecent(received);
                if (IsForeground) ShowNotice(L.T("receive_notice", progress.FileName, progress.SenderName), false);
                else _toasts.ShowInfo(L.T("toast_received_title"), L.T("toast_received_body", progress.FileName, progress.SenderName));
                if (exportPending) _ = ExportPictureAsync(received);
                break;
            case ReceiveState.Failed:
                ActivityLog.Write("receive", $"failed \"{progress.FileName}\" from \"{progress.SenderName}\"");
                if (item is not null) Receives.Remove(item);
                ShowNotice(L.T("receive_failed_notice", progress.FileName), true);
                break;
        }
        UpdateActivity();
    }

    private void AddRecent(RecentEntry entry)
    {
        _recent.Insert(0, entry);
        if (_recent.Count > RecentStore.Limit) _recent.RemoveAt(_recent.Count - 1);
        RecentStore.Save(_data, _recent);
        Recent.Insert(0, new RecentItem(entry));
        while (Recent.Count > 4) Recent.RemoveAt(Recent.Count - 1);
        OnPropertyChanged(nameof(HasRecent));
    }

    private void RemoveRecent(RecentEntry entry)
    {
        _recent.Remove(entry);
        RecentStore.Save(_data, _recent);
        if (Recent.FirstOrDefault(r => r.Entry == entry) is { } item) Recent.Remove(item);
        // Refill from the stored history so the card keeps showing up to four entries.
        foreach (var next in _recent.Where(e => Recent.All(r => r.Entry != e)).Take(4 - Recent.Count)) Recent.Add(new RecentItem(next));
        OnPropertyChanged(nameof(HasRecent));
    }

    /// <summary>Received files go to the Recycle Bin, so deletion stays recoverable; sent files are never touched.</summary>
    private void DeleteRecentFile(RecentItem item)
    {
        if (!item.Entry.Received || item.Entry.Path is not { } path) return;
        try
        {
            if (File.Exists(path)) Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(path, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
            RemoveRecent(item.Entry);
            ShowNotice(L.T("deleted_toast", item.Name), false);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException) { ShowNotice(L.T("delete_failed", ex.Message), true); }
    }

    private void PreviewFile(string path)
    {
        try { var preview = new FilePreviewWindow(path) { Owner = Owner }; preview.Show(); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { ShowNotice(L.T("preview_failed"), true); }
    }
    private void PreviewSelectedFiles()
    {
        if (_files.Count == 1) { PreviewFile(_files[0]); return; }
        if (_files.Count > 1) new SelectedFilesWindow(_files.ToArray(), PreviewFile, Reveal) { Owner = Owner }.ShowDialog();
    }
    private void OpenRecentLocation(RecentItem item)
    {
        if (item.Entry.Path is not { } path) return;
        try
        {
            if (item.IsImage) FilePreviewWindow.OpenPhoto(item.Entry.PhotoPath is { } photo && File.Exists(photo) ? photo : path);
            else FilePreviewWindow.Reveal(path);
        }
        catch (FileNotFoundException) { ShowNotice(L.T("file_moved"), true); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { ShowNotice(L.T("open_failed", ex.Message), true); }
    }
    private async Task ResumePictureExportsAsync()
    {
        foreach (var entry in PictureExportRecovery.Pending(_recent, Settings.AutoSaveReceivedImages).ToArray())
            await ExportPictureAsync(entry);
    }
    private async Task ExportPictureAsync(RecentEntry entry)
    {
        if (entry.Path is not { } path) return;
        try
        {
            var result = await _pictureExports.ExportAsync(entry.ReceiptId ?? $"legacy:{path}:{entry.Time.UtcTicks}", path, _lifetime.Token);
            if (_disposed) return;
            var current = _recent.FirstOrDefault(e => e.ReceiptId == entry.ReceiptId && e.Path == entry.Path && e.Time == entry.Time);
            if (current is not null)
            {
                var replacement = current with { PhotoPath = result.Path, PhotoError = result.Success ? null : result.Error ?? "failed", PhotoExportPending = false };
                _recent[_recent.IndexOf(current)] = replacement;
                Recent.FirstOrDefault(r => r.Entry == current)?.Update(replacement);
                RecentStore.Save(_data, _recent);
            }
            if (!result.Success) ShowNotice(L.T("photo_save_failed"), true);
        }
        catch (OperationCanceledException) { }
    }

    // ---------- taskbar, tray and timers ----------

    private void UpdateActivity()
    {
        string tray;
        if (_sending is not null)
        {
            var spinning = _step < 2;
            TaskbarState = spinning ? TaskbarItemProgressState.Indeterminate : TaskbarItemProgressState.Normal;
            TaskbarValue = SendFraction;
            tray = spinning ? "LimLink · " + SendStatus : L.T("tray_sending", Format.Percent(SendFraction));
        }
        else if (Receives.Any(r => !r.Completed))
        {
            var active = Receives.Where(r => !r.Completed).ToArray();
            var total = active.Sum(r => r.Total);
            var fraction = total == 0 ? 0 : (double)active.Sum(r => r.Received) / total;
            TaskbarState = TaskbarItemProgressState.Normal;
            TaskbarValue = fraction;
            tray = L.T("tray_receiving", Format.Percent(fraction));
        }
        else
        {
            TaskbarState = TaskbarItemProgressState.None;
            tray = Startup == StartupState.Ready ? L.T("tray_ready") : "LimLink";
        }
        TrayTextChanged?.Invoke(tray);
    }

    private void Tick()
    {
        foreach (var completed in Receives.Where(r => r.CompletedAt is { } at && DateTimeOffset.Now - at > TimeSpan.FromSeconds(5)).ToArray()) Receives.Remove(completed);
        // The receiver stops waiting after 120 seconds; close its prompt too so nobody accepts a dead session.
        foreach (var expired in Offers.Where(o => o.Deadline <= DateTimeOffset.Now).ToArray())
        {
            ActivityLog.Write("consent", $"expired session={expired.SessionId[..8]}");
            Resolve(expired, false);
        }
        foreach (var offer in Offers) offer.Tick();
        foreach (var peer in Peers.Where(p => p.State == PeerState.Delivered && DateTimeOffset.Now - p.DeliveredAt > TimeSpan.FromSeconds(6)))
            peer.State = PeerState.Idle;
        if (DateTime.Now.Second % 30 == 0) foreach (var item in Recent) item.Refresh();
    }

    private void ShowNotice(string text, bool error)
    {
        NoticeIsError = error;
        Notice = text;
        _noticeTimer.Stop();
        _noticeTimer.Interval = TimeSpan.FromSeconds(error ? 10 : 6);
        _noticeTimer.Start();
    }

    // ---------- settings ----------

    private void OpenLegalDocument(bool privacy)
    {
        var document = new LegalDocumentWindow(privacy);
        if (Owner is not null) document.Owner = Owner;
        document.ShowDialog();
    }

    private void OpenSettings()
    {
        EditName = Settings.DeviceName;
        EditDirectory = Settings.ReceiveDirectory;
        EditCloseToTray = Settings.CloseToTray;
        EditAutoSaveReceivedImages = Settings.AutoSaveReceivedImages;
        EditLanguage = Settings.Language;
        SettingsError = "";
        SettingsOpen = true;
    }

    private async Task SaveSettingsAsync()
    {
        if (AppSettings.ValidateName(EditName) is { } invalid) { SettingsError = invalid; return; }
        var error = await ApplyHostChangeAsync(EditName.Trim(), EditDirectory.Trim());
        if (error is not null) { SettingsError = error; return; }
        Settings.CloseToTray = EditCloseToTray;
        Settings.AutoSaveReceivedImages = EditAutoSaveReceivedImages;
        Settings.Language = EditLanguage;
        Localization.Current.SetLanguage(EditLanguage);
        Settings.Save(_data);
        SettingsOpen = false;
    }

    private async Task ChangeReceiveFolderAsync()
    {
        if (PickFolder(Settings.ReceiveDirectory) is not { } folder) return;
        if (await ApplyHostChangeAsync(Settings.DeviceName, folder) is { } error) ShowNotice(error, true);
        else ShowNotice(L.T("receive_folder_changed"), false);
    }

    /// <summary>The listener and discovery record carry the name and receive folder, so changes restart the node.</summary>
    private async Task<string?> ApplyHostChangeAsync(string name, string directory)
    {
        var sameName = name == Settings.DeviceName;
        var sameDirectory = string.Equals(Path.GetFullPath(directory), Path.GetFullPath(Settings.ReceiveDirectory), StringComparison.OrdinalIgnoreCase);
        if (sameName && sameDirectory) return null;
        if (_sending is not null) return L.T("settings_sending_error");
        if (_changingHost) return L.T("settings_reconnecting");
        try { Directory.CreateDirectory(directory); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return L.T("folder_in_use", ex.Message); }
        _changingHost = true;
        UpdateCanSend();
        try
        {
            if (_node is not null && !await _node.Receiver.TrySuspendOffersAsync(_lifetime.Token)) return L.T("settings_suspend_failed");
            await StopNodeAsync();
        }
        catch (OperationCanceledException) { return null; }
        finally { _changingHost = false; }
        Settings.DeviceName = name;
        Settings.ReceiveDirectory = Path.GetFullPath(directory);
        Settings.Save(_data);
        OnPropertyChanged(nameof(DeviceName));
        OnPropertyChanged(nameof(ReceiveDirectory));
        await StartAsync();
        return null;
    }

    private string? PickFolder(string initial)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = L.T("folder_dialog_title"), Multiselect = false };
        if (Directory.Exists(initial)) dialog.InitialDirectory = initial;
        return dialog.ShowDialog(Owner) == true ? dialog.FolderName : null;
    }

    private void OpenFolder(string path)
    {
        try { Directory.CreateDirectory(path); Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true }); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { ShowNotice(L.T("open_folder_failed", ex.Message), true); }
    }

    private void Reveal(string path)
    {
        try { FilePreviewWindow.Reveal(path); }
        catch (FileNotFoundException) { ShowNotice(L.T("file_moved"), true); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { ShowNotice(L.T("open_failed", ex.Message), true); }
    }

    public void MarkTrayNoticeShown() { Settings.TrayNoticeShown = true; Settings.Save(_data); }

    private void OnLanguageChanged()
    {
        if (Steps.Count == 4)
        {
            Steps[0].Label = L.T("step_connect");
            Steps[1].Label = L.T("step_accept");
            Steps[2].Label = L.T("step_transfer");
            Steps[3].Label = L.T("step_verify");
        }
        foreach (var peer in Peers) peer.RefreshLocalized();
        foreach (var offer in Offers) offer.RefreshLocalized();
        foreach (var receive in Receives) receive.RefreshLocalized();
        foreach (var recent in Recent) recent.Refresh();
        OnPropertyChanged(string.Empty);
        UpdateActivity();
        RefreshOffer();
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        Localization.Current.LanguageChanged -= OnLanguageChanged;
        _clock.Stop();
        _noticeTimer.Stop();
        CancelDoneReset();
        _lifetime.Cancel();
        _sending?.Cancel();
        foreach (var offer in Offers.ToArray()) Resolve(offer, false);
        await StopNodeAsync();
        _disposed = true;
        _lifetime.Dispose();
    }
}
