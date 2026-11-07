using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace LimLink.Desktop;

internal enum MotionKind { None, Fade, Rise, Drop, Pop, Burst, Shake }

/// <summary>
/// Entrance motion that plays whenever an element becomes visible (state panels, overlays, list items).
/// Items inside an ItemsControl are staggered by index. Honors the Windows "Animation effects" setting.
/// </summary>
internal static class Motion
{
    public static readonly DependencyProperty AppearProperty = DependencyProperty.RegisterAttached("Appear", typeof(MotionKind), typeof(Motion), new PropertyMetadata(MotionKind.None, OnAppearChanged));
    public static readonly DependencyProperty DelayProperty = DependencyProperty.RegisterAttached("Delay", typeof(double), typeof(Motion), new PropertyMetadata(0d));
    /// <summary>Replaces a Visibility binding: shows immediately (playing Appear) and fades out before collapsing.</summary>
    public static readonly DependencyProperty IsShownProperty = DependencyProperty.RegisterAttached("IsShown", typeof(bool), typeof(Motion), new PropertyMetadata(false, OnShownChanged));

    public static bool GetIsShown(DependencyObject element) => (bool)element.GetValue(IsShownProperty);
    public static void SetIsShown(DependencyObject element, bool value) => element.SetValue(IsShownProperty, value);

    public static MotionKind GetAppear(DependencyObject element) => (MotionKind)element.GetValue(AppearProperty);
    public static void SetAppear(DependencyObject element, MotionKind value) => element.SetValue(AppearProperty, value);
    /// <summary>Delay in milliseconds.</summary>
    public static double GetDelay(DependencyObject element) => (double)element.GetValue(DelayProperty);
    public static void SetDelay(DependencyObject element, double value) => element.SetValue(DelayProperty, value);

    public static bool Enabled => SystemParameters.ClientAreaAnimation;

    private static readonly IEasingFunction Smooth = new ExponentialEase { EasingMode = EasingMode.EaseOut, Exponent = 5 };
    private static readonly IEasingFunction Spring = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.45 };

    private static void OnAppearChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not FrameworkElement element) return;
        element.IsVisibleChanged -= OnVisibleChanged;
        if ((MotionKind)e.NewValue != MotionKind.None) element.IsVisibleChanged += OnVisibleChanged;
    }

    private static void OnShownChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not FrameworkElement element) return;
        if (e.NewValue is true)
        {
            element.BeginAnimation(UIElement.OpacityProperty, null);
            element.Visibility = Visibility.Visible;
            return;
        }
        if (!Enabled || !element.IsVisible) { element.Visibility = Visibility.Collapsed; return; }
        var fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(170)) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseIn } };
        fade.Completed += (_, _) =>
        {
            if (!GetIsShown(element)) element.Visibility = Visibility.Collapsed;
            element.BeginAnimation(UIElement.OpacityProperty, null);
        };
        element.BeginAnimation(UIElement.OpacityProperty, fade);
        var (scale, _) = Transforms(element);
        var shrink = new DoubleAnimation(0.98, TimeSpan.FromMilliseconds(170)) { FillBehavior = FillBehavior.Stop };
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, shrink);
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, shrink);
    }

    private static void OnVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (e.NewValue is true && sender is FrameworkElement element) Play(element, GetAppear(element));
    }

    public static void Play(FrameworkElement element, MotionKind kind)
    {
        if (!Enabled || kind == MotionKind.None) return;
        var delay = TimeSpan.FromMilliseconds(GetDelay(element) + StaggerIndex(element) * 45);
        var (scale, translate) = Transforms(element);
        switch (kind)
        {
            case MotionKind.Fade:
                Animate(element, UIElement.OpacityProperty, 0, 1, delay, 220, Smooth);
                break;
            case MotionKind.Rise:
                Animate(element, UIElement.OpacityProperty, 0, 1, delay, 320, Smooth);
                Animate(translate, TranslateTransform.YProperty, 14, 0, delay, 520, Smooth);
                break;
            case MotionKind.Drop:
                Animate(element, UIElement.OpacityProperty, 0, 1, delay, 260, Smooth);
                Animate(translate, TranslateTransform.YProperty, -10, 0, delay, 420, Smooth);
                break;
            case MotionKind.Pop:
                Animate(element, UIElement.OpacityProperty, 0, 1, delay, 200, Smooth);
                Animate(scale, ScaleTransform.ScaleXProperty, 0.9, 1, delay, 420, Spring);
                Animate(scale, ScaleTransform.ScaleYProperty, 0.9, 1, delay, 420, Spring);
                break;
            case MotionKind.Burst:
                // The element's own opacity should be 0 so it vanishes when the animation is released.
                Animate(element, UIElement.OpacityProperty, 0.6, 0, delay, 900, Smooth);
                Animate(scale, ScaleTransform.ScaleXProperty, 0.92, 1.4, delay, 900, Smooth);
                Animate(scale, ScaleTransform.ScaleYProperty, 0.92, 1.4, delay, 900, Smooth);
                break;
            case MotionKind.Shake:
                Shake(translate, delay);
                break;
        }
    }

    private static int StaggerIndex(FrameworkElement element)
    {
        if (VisualTreeHelper.GetParent(element) is not ContentPresenter presenter) return 0;
        var owner = ItemsControl.ItemsControlFromItemContainer(presenter);
        var index = owner?.ItemContainerGenerator.IndexFromContainer(presenter) ?? 0;
        return Math.Clamp(index, 0, 6);
    }

    private static (ScaleTransform Scale, TranslateTransform Translate) Transforms(FrameworkElement element)
    {
        if (element.RenderTransform is TransformGroup { Children: [ScaleTransform s, TranslateTransform t] }) return (s, t);
        var scale = new ScaleTransform();
        var translate = new TranslateTransform();
        element.RenderTransformOrigin = new Point(0.5, 0.5);
        element.RenderTransform = new TransformGroup { Children = { scale, translate } };
        return (scale, translate);
    }

    /// <summary>Holds the start value during the delay, then releases the animation so triggers and setters apply again.</summary>
    private static void Animate(IAnimatable target, DependencyProperty property, double from, double to, TimeSpan delay, double milliseconds, IEasingFunction easing)
    {
        var animation = new DoubleAnimationUsingKeyFrames { FillBehavior = FillBehavior.HoldEnd };
        animation.KeyFrames.Add(new DiscreteDoubleKeyFrame(from, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        if (delay > TimeSpan.Zero) animation.KeyFrames.Add(new DiscreteDoubleKeyFrame(from, KeyTime.FromTimeSpan(delay)));
        animation.KeyFrames.Add(new EasingDoubleKeyFrame(to, KeyTime.FromTimeSpan(delay + TimeSpan.FromMilliseconds(milliseconds)), easing));
        animation.Completed += (_, _) => target.BeginAnimation(property, null);
        target.BeginAnimation(property, animation);
    }

    private static void Shake(TranslateTransform translate, TimeSpan delay)
    {
        var animation = new DoubleAnimationUsingKeyFrames();
        double[] offsets = [0, -9, 8, -6, 4, -2, 0];
        for (var i = 0; i < offsets.Length; i++)
            animation.KeyFrames.Add(new EasingDoubleKeyFrame(offsets[i], KeyTime.FromTimeSpan(delay + TimeSpan.FromMilliseconds(i * 65)), new SineEase()));
        animation.Completed += (_, _) => translate.BeginAnimation(TranslateTransform.XProperty, null);
        translate.BeginAnimation(TranslateTransform.XProperty, animation);
    }
}
