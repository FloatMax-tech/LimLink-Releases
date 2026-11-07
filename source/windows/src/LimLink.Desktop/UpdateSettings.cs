using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Input;
using LimLink.Updates;

namespace LimLink.Desktop;
internal sealed partial class MainViewModel
{
    private bool _checkingUpdates;
    public bool CheckingUpdates { get => _checkingUpdates; private set => Set(ref _checkingUpdates, value); }
    public ICommand CheckUpdatesCommand => new RelayCommand(_ => _ = CheckUpdatesAsync());
    private async Task CheckUpdatesAsync()
    {
        if (CheckingUpdates || _disposed) return;
        CheckingUpdates = true;
        try
        {
            var installed = Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0,0,0,0);
            var update = await UpdateClient.CheckAsync(installed, _lifetime.Token);
            if (_disposed) return;
            if (update is null) { MessageBox.Show(Owner!, L.T("updates_latest"), "LimLink"); return; }
            var preview = string.Join("\n", update.Notes.Split('\n').Take(12));
            if (preview.Length > 600) preview = preview[..600];
            if (preview.Length < update.Notes.Length) preview += "…";
            if (MessageBox.Show(Owner!, $"{L.T("updates_available")} · {update.Version}\n\n{preview}\n\n{L.T("updates_install_hint")}\n\n{L.T("updates_download")}?", "LimLink", MessageBoxButton.OKCancel) == MessageBoxResult.OK)
                Process.Start(new ProcessStartInfo(update.Url.AbsoluteUri) { UseShellExecute = true });
        }
        catch (OperationCanceledException) { }
        catch (NoReleaseException) { if (!_disposed) MessageBox.Show(Owner!, L.T("updates_none"), "LimLink"); }
        catch (Exception) { /* A failed update query must not interrupt local transfers. */ }
        finally { CheckingUpdates = false; }
    }
}
