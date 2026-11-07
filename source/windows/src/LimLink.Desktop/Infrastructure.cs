using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;

namespace LimLink.Desktop;

internal abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }
    protected void OnPropertyChanged([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

internal sealed class RelayCommand(Action<object?> execute) : ICommand
{
    public event EventHandler? CanExecuteChanged { add { } remove { } }
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => execute(parameter);
}

internal sealed class InverseBoolVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value is true ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

internal sealed class NullVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object parameter, CultureInfo culture) => value is null ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

internal sealed class TextVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object parameter, CultureInfo culture) => string.IsNullOrEmpty(value as string) ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Visible when the value's name is one of the '|' separated names in the parameter.</summary>
internal sealed class EnumVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object parameter, CultureInfo culture)
        => value is not null && parameter is string names && names.Split('|').Contains(value.ToString()) ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

internal sealed class HalfCornerConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => new CornerRadius(value is double h ? h / 2 : 0);
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

internal static class Format
{
    // Decimal units, matching the 5 GB limit and the Apple clients.
    public static string Size(long bytes)
    {
        if (bytes < 1000) return Localization.Current.T("bytes", Math.Max(bytes, 0));
        string[] units = ["KB", "MB", "GB", "TB"];
        double value = bytes;
        var unit = -1;
        do { value /= 1000; unit++; } while (value >= 1000 && unit < units.Length - 1);
        return (value < 100 ? value.ToString("0.#", CultureInfo.InvariantCulture) : value.ToString("0", CultureInfo.InvariantCulture)) + " " + units[unit];
    }

    public static string Remaining(double seconds) => seconds switch
    {
        < 1 => Localization.Current.T("less_than_second"),
        < 60 => Localization.Current.T("seconds", Math.Ceiling(seconds)),
        < 3600 => Localization.Current.T("minutes", Math.Ceiling(seconds / 60)),
        _ => Localization.Current.T("hours", (seconds / 3600).ToString("0.#", CultureInfo.InvariantCulture)),
    };

    public static string When(DateTimeOffset time)
    {
        var now = DateTimeOffset.Now;
        var age = now - time;
        var clock = time.ToString("HH:mm", CultureInfo.InvariantCulture);
        if (age < TimeSpan.FromMinutes(1)) return Localization.Current.T("just_now");
        if (age < TimeSpan.FromHours(1)) return Localization.Current.T("minutes_ago", (int)age.TotalMinutes);
        if (time.Date == now.Date) return Localization.Current.T("today", clock);
        if (time.Date == now.Date.AddDays(-1)) return Localization.Current.T("yesterday", clock);
        return Localization.Current.T("month_day", time.Month, time.Day);
    }

    public static int Percent(double fraction) => (int)Math.Floor(Math.Clamp(fraction, 0, 1) * 100);
}
