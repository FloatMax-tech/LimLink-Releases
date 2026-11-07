using RecentEntry = LimLink.Files.RecentTransferRecord;
using LimLink.Files;
namespace LimLink.Desktop;

internal enum StartupState { Starting, Ready, Failed }
internal enum ComposerState { Empty, Selected, Sending, Done, Failed }
internal enum PeerState { Idle, Sending, Delivered }
internal enum StepState { Todo, Now, Done }

internal sealed class PeerItem : Observable
{
    private DiscoveryPeer _peer;
    private PeerState _state;
    private double _fraction;
    private bool _spinning;
    private string _status = "";
    private bool _canSend;
    private bool _dimmed;
    private bool _selected;

    public PeerItem(DiscoveryPeer peer) => _peer = peer;
    public DiscoveryPeer Peer { get => _peer; set { if (Set(ref _peer, value)) { OnPropertyChanged(nameof(DisplayName)); OnPropertyChanged(nameof(TypeLabel)); OnPropertyChanged(nameof(Glyph)); OnPropertyChanged(nameof(Subtitle)); } } }
    public string Fingerprint => _peer.Fingerprint;
    public DateTimeOffset DeliveredAt { get; set; }

    /// <summary>Windows hosts add "-" plus the first six fingerprint characters to their DNS-SD instance name.</summary>
    public string DisplayName
    {
        get
        {
            var suffix = "-" + _peer.Fingerprint[..Math.Min(6, _peer.Fingerprint.Length)];
            return _peer.Name.Length > suffix.Length && _peer.Name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase) ? _peer.Name[..^suffix.Length] : _peer.Name;
        }
    }

    public string TypeLabel => _peer.DeviceType.ToLowerInvariant() switch
    {
        "windows" => "Windows",
        "android" => "Android",
        "mac" => "Mac",
        "iphone" => "iPhone",
        "ipad" => "iPad",
        _ => Localization.Current.T("device_type_fallback"),
    };

    public void RefreshLocalized()
    {
        OnPropertyChanged(nameof(TypeLabel));
        OnPropertyChanged(nameof(Subtitle));
    }

    public string Glyph => _peer.DeviceType.ToLowerInvariant() switch
    {
        "windows" => "\uE977",
        "mac" => "\uE7F8",
        "iphone" or "android" => "\uE8EA",
        "ipad" => "\uE70A",
        _ => "\uE772",
    };

    public PeerState State { get => _state; set { if (Set(ref _state, value)) { OnPropertyChanged(nameof(Subtitle)); OnPropertyChanged(nameof(IsLive)); } } }
    public double Fraction { get => _fraction; set => Set(ref _fraction, value); }
    public bool Spinning { get => _spinning; set => Set(ref _spinning, value); }
    public string Status { get => _status; set { if (Set(ref _status, value)) OnPropertyChanged(nameof(Subtitle)); } }
    public string Subtitle => _state == PeerState.Idle ? TypeLabel : _status;
    public bool IsLive => _state == PeerState.Sending;
    public bool CanSend { get => _canSend; set => Set(ref _canSend, value); }
    public bool Dimmed { get => _dimmed; set => Set(ref _dimmed, value); }
    public bool Selected { get => _selected; set => Set(ref _selected, value); }
}

internal sealed class OfferItem : Observable
{
    private int _secondsLeft = 120;
    public OfferItem(IncomingOffer offer, string saveDirectory)
    {
        Offer = offer;
        SaveDirectory = saveDirectory;
        Deadline = DateTimeOffset.Now.AddSeconds(120);
    }
    public IncomingOffer Offer { get; }
    public string SaveDirectory { get; }
    public DateTimeOffset Deadline { get; }
    public TaskCompletionSource<bool> Decision { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public string SessionId => Offer.SessionId;
    public string Title => Localization.Current.T("offer_title", Offer.SenderName);
    public string FileName => Offer.FileName;
    public string Detail => Localization.Current.T("offer_detail", Format.Size(Offer.Size), SaveDirectory);
    public string Countdown => Localization.Current.T("offer_countdown", _secondsLeft);
    public void Tick()
    {
        var left = (int)Math.Max(0, Math.Ceiling((Deadline - DateTimeOffset.Now).TotalSeconds));
        Set(ref _secondsLeft, left, nameof(Countdown));
    }
    public void RefreshLocalized()
    {
        OnPropertyChanged(nameof(Title));
        OnPropertyChanged(nameof(Detail));
        OnPropertyChanged(nameof(Countdown));
    }
}

internal sealed class ReceiveItem : Observable
{
    private long _received;
    public ReceiveItem(ReceiveProgress progress) { SessionId = progress.SessionId; SenderName = progress.SenderName; FileName = progress.FileName; Total = progress.TotalBytes; }
    public string SessionId { get; }
    public string SenderName { get; }
    public string FileName { get; }
    public long Total { get; }
    private bool _completed;
    public bool Completed { get => _completed; set { if (Set(ref _completed, value)) { OnPropertyChanged(nameof(Title)); OnPropertyChanged(nameof(Progress)); } } }
    public DateTimeOffset? CompletedAt { get; set; }
    private string? _savedPath;
    public string? SavedPath { get => _savedPath; set => Set(ref _savedPath, value); }
    public string Title => Localization.Current.T(Completed ? "received_title" : "receiving_title", SenderName);
    public double Fraction => Total == 0 ? 0 : (double)_received / Total;
    public string Progress => Completed ? Localization.Current.T("verified_complete") : $"{Format.Size(_received)} / {Format.Size(Total)} · {Format.Percent(Fraction)}%";
    public void RefreshLocalized() { OnPropertyChanged(nameof(Title)); OnPropertyChanged(nameof(Progress)); }
    public long Received
    {
        get => _received;
        set { if (Set(ref _received, value)) { OnPropertyChanged(nameof(Fraction)); OnPropertyChanged(nameof(Progress)); } }
    }
}

internal sealed class RecentItem(RecentEntry entry) : Observable
{
    public RecentEntry Entry { get; private set; } = entry;
    public void Update(RecentEntry value) { Entry = value; Refresh(); OnPropertyChanged(string.Empty); }
    public string Name => Entry.FileName;
    public string Glyph => Entry.Received ? "\uE896" : "\uE898";
    public string Detail => (Entry.Received ? Localization.Current.T("recent_received", Entry.PeerName) : Localization.Current.T("recent_sent", Entry.PeerName)) + " · " + Format.When(Entry.Time);
    public bool CanPreview => Entry.Path is not null;
    public bool CanReveal => Entry.Path is not null && File.Exists(Entry.Path);
    public bool IsImage => Entry.Path is not null && FilePreviewPolicy.Classify(Entry.Path) == PreviewKind.Image;
    public bool CanDelete => Entry.Received && CanReveal;
    public bool CanOpenLocation => CanReveal || IsImage && Entry.PhotoPath is { } photo && File.Exists(photo);
    public bool CanRetryPhoto => Entry.Received && IsImage && Entry.PhotoError is not null;
    public string LocationLabel => Localization.Current.T(IsImage ? "open_photos" : "open_containing_folder");
    public string PhotoStatus => Entry.PhotoError is not null ? Localization.Current.T("photo_save_failed") : Entry.PhotoPath is not null ? Localization.Current.T("photo_saved") : "";
    public void Refresh() => OnPropertyChanged(string.Empty);
}

internal sealed class StepItem(string label, bool isLast = false) : Observable
{
    private StepState _state;
    private string _label = label;
    public string Label { get => _label; set => Set(ref _label, value); }
    public bool IsLast { get; } = isLast;
    public StepState State { get => _state; set => Set(ref _state, value); }
}
