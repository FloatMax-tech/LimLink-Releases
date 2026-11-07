using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace LimLink.Desktop;

/// <summary>
/// The shared LimLink progress ring. A spinning quarter arc means waiting; determinate values glide
/// to their target, and <see cref="DrawIn"/> rings sweep from empty whenever they become visible.
/// </summary>
internal sealed class RingProgress : FrameworkElement
{
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(nameof(Value), typeof(double), typeof(RingProgress), new FrameworkPropertyMetadata(0d, (d, e) => ((RingProgress)d).OnValueChanged((double)e.OldValue, (double)e.NewValue)));
    public static readonly DependencyProperty ThicknessProperty = DependencyProperty.Register(nameof(Thickness), typeof(double), typeof(RingProgress), new FrameworkPropertyMetadata(8d, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty TrackBrushProperty = DependencyProperty.Register(nameof(TrackBrush), typeof(Brush), typeof(RingProgress), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty RingBrushProperty = DependencyProperty.Register(nameof(RingBrush), typeof(Brush), typeof(RingProgress), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty IsSpinningProperty = DependencyProperty.Register(nameof(IsSpinning), typeof(bool), typeof(RingProgress), new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsRender, (d, _) => ((RingProgress)d).UpdateSpin()));
    public static readonly DependencyProperty DrawInProperty = DependencyProperty.Register(nameof(DrawIn), typeof(bool), typeof(RingProgress), new FrameworkPropertyMetadata(false));
    private static readonly DependencyProperty ShownValueProperty = DependencyProperty.Register("ShownValue", typeof(double), typeof(RingProgress), new FrameworkPropertyMetadata(0d, FrameworkPropertyMetadataOptions.AffectsRender));

    public double Value { get => (double)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }
    public double Thickness { get => (double)GetValue(ThicknessProperty); set => SetValue(ThicknessProperty, value); }
    public Brush? TrackBrush { get => (Brush?)GetValue(TrackBrushProperty); set => SetValue(TrackBrushProperty, value); }
    public Brush? RingBrush { get => (Brush?)GetValue(RingBrushProperty); set => SetValue(RingBrushProperty, value); }
    public bool IsSpinning { get => (bool)GetValue(IsSpinningProperty); set => SetValue(IsSpinningProperty, value); }
    public bool DrawIn { get => (bool)GetValue(DrawInProperty); set => SetValue(DrawInProperty, value); }
    private double ShownValue => (double)GetValue(ShownValueProperty);

    public RingProgress()
    {
        RenderTransformOrigin = new Point(0.5, 0.5);
        IsVisibleChanged += (_, e) =>
        {
            UpdateSpin();
            if (e.NewValue is true && DrawIn) Glide(0, Value, 900);
        };
    }

    private void OnValueChanged(double oldValue, double newValue)
    {
        // Large backwards jumps (a new transfer) snap; forward progress glides.
        if (!IsVisible || !Motion.Enabled || newValue < oldValue - 0.25) Snap(newValue);
        else Glide(null, newValue, 380);
    }

    private void Snap(double value)
    {
        BeginAnimation(ShownValueProperty, null);
        SetValue(ShownValueProperty, value);
    }

    private void Glide(double? from, double to, double milliseconds)
    {
        if (!Motion.Enabled) { Snap(to); return; }
        var animation = new DoubleAnimation(to, TimeSpan.FromMilliseconds(milliseconds)) { EasingFunction = new ExponentialEase { EasingMode = EasingMode.EaseOut, Exponent = 4 } };
        if (from is { } start) animation.From = start;
        BeginAnimation(ShownValueProperty, animation, HandoffBehavior.SnapshotAndReplace);
    }

    private void UpdateSpin()
    {
        var spin = IsSpinning && IsVisible && Motion.Enabled;
        if (spin == RenderTransform is RotateTransform) return;
        if (!spin) { RenderTransform = Transform.Identity; return; }
        var rotate = new RotateTransform();
        RenderTransform = rotate;
        rotate.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, 360, TimeSpan.FromSeconds(1.2)) { RepeatBehavior = RepeatBehavior.Forever });
    }

    protected override void OnRender(DrawingContext dc)
    {
        var size = Math.Min(ActualWidth, ActualHeight);
        if (size <= 0) return;
        var thickness = Math.Min(Thickness, size / 2);
        var radius = (size - thickness) / 2;
        var center = new Point(ActualWidth / 2, ActualHeight / 2);
        if (TrackBrush is not null) dc.DrawEllipse(null, new Pen(TrackBrush, thickness), center, radius, radius);
        var value = IsSpinning ? 0.25 : Math.Clamp(ShownValue, 0, 1);
        if (value <= 0.001 || RingBrush is null) return;
        var pen = new Pen(RingBrush, thickness) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        if (value >= 0.9999) { dc.DrawEllipse(null, pen, center, radius, radius); return; }
        var angle = value * 2 * Math.PI;
        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            context.BeginFigure(new Point(center.X, center.Y - radius), false, false);
            context.ArcTo(new Point(center.X + radius * Math.Sin(angle), center.Y - radius * Math.Cos(angle)), new Size(radius, radius), 0, value > 0.5, SweepDirection.Clockwise, true, false);
        }
        geometry.Freeze();
        dc.DrawGeometry(null, pen, geometry);
    }
}
