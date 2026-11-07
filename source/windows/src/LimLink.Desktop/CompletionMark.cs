using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace LimLink.Desktop;

/// <summary>Verified completion transforms a ring into a checkmark; reduced motion shows the final check immediately.</summary>
internal sealed class CompletionMark : FrameworkElement
{
    public static readonly DependencyProperty BrushProperty = DependencyProperty.Register(nameof(Brush), typeof(Brush), typeof(CompletionMark), new FrameworkPropertyMetadata(Brushes.ForestGreen, FrameworkPropertyMetadataOptions.AffectsRender));
    private static readonly DependencyProperty ProgressProperty = DependencyProperty.Register("Progress", typeof(double), typeof(CompletionMark), new FrameworkPropertyMetadata(1d, FrameworkPropertyMetadataOptions.AffectsRender));
    public Brush Brush { get => (Brush)GetValue(BrushProperty); set => SetValue(BrushProperty, value); }
    public CompletionMark()
    {
        IsVisibleChanged += (_, e) => { if (e.NewValue is true) Animate(); };
        Loaded += (_, _) => Animate();
        System.Windows.Automation.AutomationProperties.SetName(this, Localization.Current.T("verified_complete"));
    }
    private void Animate()
    {
        BeginAnimation(ProgressProperty, null); SetValue(ProgressProperty, 1d);
        if (Motion.Enabled) BeginAnimation(ProgressProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(720)) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } });
    }
    protected override void OnRender(DrawingContext dc)
    {
        var size = Math.Min(ActualWidth, ActualHeight); if (size <= 0) return;
        var p = Math.Clamp((double)GetValue(ProgressProperty), 0, 1);
        var x = (ActualWidth - size) / 2; var y = (ActualHeight - size) / 2;
        var pen = new Pen(Brush, Math.Max(3, size * .07)) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        dc.PushOpacity(1 - p); dc.DrawEllipse(null, pen, new Point(x + size / 2, y + size / 2), size * .39, size * .39); dc.Pop();
        var a = new Point(x + size * .23, y + size * .51); var b = new Point(x + size * .44, y + size * .71); var c = new Point(x + size * .79, y + size * .32);
        var draw = Math.Clamp((p - .2) / .8, 0, 1);
        if (draw <= .4) dc.DrawLine(pen, a, Interpolate(a, b, draw / .4));
        else { dc.DrawLine(pen, a, b); dc.DrawLine(pen, b, Interpolate(b, c, (draw - .4) / .6)); }
    }
    private static Point Interpolate(Point a, Point b, double p) => new(a.X + (b.X - a.X) * p, a.Y + (b.Y - a.Y) * p);
}
