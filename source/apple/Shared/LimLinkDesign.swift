import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Shared by the iOS and macOS apps.

// MARK: - Tokens (docs/handoff-2026-10-18.md §3)

enum Palette {
    static let ink = Color(light: 0x000000, dark: 0xFFFFFF)
    static let paper = Color(light: 0xF2F2F7, dark: 0x000000)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let signal = Color(light: 0x1FBF8F, dark: 0x34E0B0)
    /// Signal green for small text, which needs more contrast on white.
    static let signalText = Color(light: 0x14A37A, dark: 0x34E0B0)
    static let danger = Color(light: 0xFF3B30, dark: 0xFF453A)
    static let secondary = Color(light: 0x6E6E73, dark: 0x98989F)
    static let faint = Color(light: 0xAEAEB2, dark: 0x636366)
    static let pause = Color(light: 0x8E8E93, dark: 0x98989D)
    static let fill = Color(light: 0x000000, lightAlpha: 0.05, dark: 0xFFFFFF, darkAlpha: 0.07)
    static let fill2 = Color(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.12)
    static let stroke = Color(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.10)
    static let track = Color(light: 0x000000, lightAlpha: 0.10, dark: 0xFFFFFF, darkAlpha: 0.16)
    static let scrim = Color(light: 0x000000, lightAlpha: 0.32, dark: 0x000000, darkAlpha: 0.55)
    static let dangerSoft = Color(light: 0xFF3B30, lightAlpha: 0.09, dark: 0xFF453A, darkAlpha: 0.14)
    static let buttonForeground = Color(light: 0xFFFFFF, dark: 0x000000)
}

enum Radius {
    static let hero: CGFloat = 30
    static let device: CGFloat = 24
    static let card: CGFloat = 20
}

extension Color {
    init(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
        #endif
    }
}

#if canImport(UIKit)
private typealias PlatformColor = UIColor
#else
private typealias PlatformColor = NSColor
#endif

private extension PlatformColor {
    convenience init(hex: UInt32, alpha: CGFloat) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Fires when the app returns to the foreground: from the background on iOS, on reactivation on macOS.
private struct ResumeObserver: ViewModifier {
    let onLeave: () -> Void
    let onResume: () -> Void
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var left = false
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content.onChange(of: scenePhase) { _, phase in
            if phase == .background { left = true; onLeave() }
            else if phase == .active, left { left = false; onResume() }
        }
        #else
        // A Mac window stays visible while inactive, so only replay after it was hidden or minimized.
        content
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in replay() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in replay() }
        #endif
    }

    private func replay() {
        onLeave()
        DispatchQueue.main.async { onResume() }
    }
}

// MARK: - Motion (docs/handoff-2026-10-18.md §4)

enum Motion {
    /// Exponential ease-out, matching the Windows `ExponentialEase` (exponent 5).
    static func smooth(_ seconds: Double) -> Animation { .timingCurve(0.16, 1, 0.3, 1, duration: seconds) }
    /// Back ease-out used for pops (amplitude ≈ 0.45).
    static func pop(_ seconds: Double) -> Animation { .timingCurve(0.34, 1.45, 0.64, 1, duration: seconds) }
    static let press = Animation.easeOut(duration: 0.09)
    static let release = Animation.spring(duration: 0.45, bounce: 0.5)
    static let ringGlide = smooth(0.38)
    static let ringDraw = smooth(0.9)

    /// Per-item list stagger: 45ms, capped at six items.
    static func stagger(_ index: Int) -> Double { Double(min(max(index, 0), 6)) * 0.045 }
}

/// Rise-and-fade entrance: 14pt → 0 over 520ms, opacity over 320ms. Optionally replays when the
/// app returns from the background.
struct RiseIn: ViewModifier {
    var delay: Double = 0
    var distance: CGFloat = 14
    var replaysOnResume = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var settled = false

    func body(content: Content) -> some View {
        let animated = content
            .opacity(visible || reduceMotion ? 1 : 0)
            .offset(y: settled || reduceMotion ? 0 : distance)
            .onAppear(perform: play)
        if replaysOnResume {
            animated.modifier(ResumeObserver(onLeave: reset, onResume: play))
        } else {
            animated
        }
    }

    private func reset() {
        guard !reduceMotion else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { visible = false; settled = false }
    }

    private func play() {
        guard !reduceMotion else { visible = true; settled = true; return }
        withAnimation(Motion.smooth(0.32).delay(delay)) { visible = true }
        withAnimation(Motion.smooth(0.52).delay(delay)) { settled = true }
    }
}

/// Slides down from above (toasts): -10 → 0 over 420ms.
struct DropIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : -10)
            .onAppear {
                guard !reduceMotion else { shown = true; return }
                withAnimation(Motion.smooth(0.26)) { shown = true }
                withAnimation(Motion.smooth(0.42)) { shown = true }
            }
    }
}

extension View {
    func riseIn(delay: Double = 0, replaysOnResume: Bool = false) -> some View {
        modifier(RiseIn(delay: delay, replaysOnResume: replaysOnResume))
    }

    /// Horizontal warning shake: 0, -9, 8, -6, 4, -2, 0 at 65ms per frame.
    func shake(trigger: Int) -> some View { modifier(Shake(trigger: trigger)) }

    /// Pops in (0.9 → 1) when it appears, after `delay`.
    func popIn(delay: Double = 0, from scale: CGFloat = 0.9) -> some View { modifier(PopIn(delay: delay, from: scale)) }
}

private struct Shake: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    for offset in [-9.0, 8, -6, 4, -2, 0] { CubicKeyframe(CGFloat(offset), duration: 0.065) }
                }
            }
        }
    }
}

private struct PopIn: ViewModifier {
    let delay: Double
    let from: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown || reduceMotion ? 1 : from)
            .opacity(shown || reduceMotion ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Motion.pop(0.42).delay(delay)) { shown = true }
            }
    }
}

/// A clock for continuous decorative motion. Uses TimelineView so it pauses with Reduce Motion,
/// when inactive, and when the scene is not in the foreground.
struct MotionClock<Content: View>: View {
    var active = true
    var interval: Double = 1.0 / 60
    @ViewBuilder let content: (_ time: TimeInterval?) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    private var foreground: Bool { scenePhase == .active }
    #else
    private var foreground: Bool { true }
    #endif

    var body: some View {
        let running = active && !reduceMotion && foreground
        TimelineView(.animation(minimumInterval: interval, paused: !running)) { timeline in
            content(running ? timeline.date.timeIntervalSinceReferenceDate : nil)
        }
    }
}

// MARK: - Buttons

/// Capsule button: press to 0.955 in 90ms, elastic release over 450ms, pointer-hover overlay.
struct TransferCapsuleButtonStyle: ButtonStyle {
    enum Emphasis { case primary, secondary, destructive }

    var emphasis: Emphasis = .primary
    var height: CGFloat = 52

    func makeBody(configuration: Configuration) -> some View {
        CapsuleButtonBody(configuration: configuration, emphasis: emphasis, height: height)
    }
}

private struct CapsuleButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let emphasis: TransferCapsuleButtonStyle.Emphasis
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(background, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.3)
            .pressable(isPressed: configuration.isPressed, hoverShape: Capsule())
    }

    private var foreground: Color {
        switch emphasis {
        case .primary: Palette.buttonForeground
        case .secondary: Palette.ink
        case .destructive: Palette.danger
        }
    }

    private var background: Color {
        switch emphasis {
        case .primary: Palette.ink
        case .secondary: Palette.fill2
        case .destructive: Palette.dangerSoft
        }
    }
}

/// Plain press feedback for cards and tiles.
struct PressableButtonStyle<S: Shape>: ButtonStyle {
    var shape: S
    var pressedScale: CGFloat = 0.955

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(shape)
            .pressable(isPressed: configuration.isPressed, hoverShape: shape, pressedScale: pressedScale)
    }
}

extension View {
    func pressable<S: Shape>(isPressed: Bool, hoverShape: S, pressedScale: CGFloat = 0.955) -> some View {
        modifier(Pressable(isPressed: isPressed, shape: hoverShape, pressedScale: pressedScale))
    }
}

private struct Pressable<S: Shape>: ViewModifier {
    let isPressed: Bool
    let shape: S
    let pressedScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                shape.fill(Palette.ink.opacity(hovering && isEnabled ? 0.06 : 0)).allowsHitTesting(false)
            }
            .scaleEffect(isPressed && !reduceMotion ? pressedScale : 1)
            .animation(reduceMotion ? nil : (isPressed ? Motion.press : Motion.release), value: isPressed)
            .onHover { inside in
                withAnimation(reduceMotion ? nil : .easeOut(duration: inside ? 0.16 : 0.28)) { hovering = inside }
            }
    }
}

// MARK: - Brand

/// The LimLink mark: black tile with a white ring (outer 78, inner 54 on a 108 canvas).
struct LimLinkMark: View {
    var size: CGFloat = 30
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let unit = size / 108
        ZStack {
            RoundedRectangle(cornerRadius: 24 * unit, style: .continuous)
                .fill(.black)
                .overlay {
                    if colorScheme == .dark {
                        RoundedRectangle(cornerRadius: 24 * unit, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), lineWidth: max(unit, 0.5))
                    }
                }
            Circle()
                .strokeBorder(.white, lineWidth: 12 * unit)
                .frame(width: 78 * unit, height: 78 * unit)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Progress ring (five states)

enum RingState: Equatable {
    case waiting, running, paused, failed, done
}

/// The shared LimLink progress ring. Waiting spins a quarter arc (1.2s per turn); determinate values
/// glide over 380ms; large backwards jumps snap; `drawIn` sweeps from empty over 900ms on appear.
/// Completion turns signal green, pops a check after 420ms and sends a ripple after 520ms.
struct ProgressRing: View {
    var value: Double
    var state: RingState
    var diameter: CGFloat
    var lineWidth: CGFloat
    var drawIn = false
    var showsCheck = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0
    @State private var checkShown = false
    @State private var rippleTrigger = 0

    var body: some View {
        ZStack {
            Circle().stroke(Palette.track, lineWidth: lineWidth)
            if state == .waiting {
                MotionClock { time in
                    let turn = time.map { $0.truncatingRemainder(dividingBy: 1.2) / 1.2 } ?? 0
                    arc(0.25, color: Palette.ink)
                        .rotationEffect(.degrees(turn * 360))
                }
            } else {
                arc(shown, color: color)
            }
            if state == .done && showsCheck {
                Image(systemName: "checkmark")
                    .font(.system(size: diameter * 0.36, weight: .bold))
                    .foregroundStyle(Palette.signal)
                    .scaleEffect(checkShown || reduceMotion ? 1 : 0.4)
                    .opacity(checkShown || reduceMotion ? 1 : 0)
            }
            if state == .done && !reduceMotion {
                Circle()
                    .stroke(Palette.signal, lineWidth: max(2, lineWidth * 0.6))
                    .keyframeAnimator(initialValue: RippleFrame(), trigger: rippleTrigger) { ring, frame in
                        ring.scaleEffect(frame.scale).opacity(frame.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(0.92, duration: 0.52)
                            CubicKeyframe(1.4, duration: 0.9)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0, duration: 0.52)
                            MoveKeyframe(0.6)
                            CubicKeyframe(0, duration: 0.9)
                        }
                    }
                    .allowsHitTesting(false)
            }
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            let target = targetValue
            if drawIn && !reduceMotion {
                shown = 0
                withAnimation(Motion.ringDraw) { shown = target }
            } else {
                shown = target
            }
            if state == .done { celebrate(animated: false) }
        }
        .onChange(of: targetValue) { old, new in
            if reduceMotion || new < old - 0.25 {
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) { shown = new }
            } else {
                withAnimation(Motion.ringGlide) { shown = new }
            }
        }
        .onChange(of: state) { _, new in
            if new == .done { celebrate(animated: true) } else { checkShown = false }
        }
        .accessibilityHidden(true)
    }

    private var targetValue: Double { state == .done ? 1 : min(max(value, 0), 1) }

    private var color: Color {
        switch state {
        case .waiting, .running: Palette.ink
        case .paused: Palette.pause
        case .failed: Palette.danger
        case .done: Palette.signal
        }
    }

    private func arc(_ amount: Double, color: Color) -> some View {
        Circle()
            .trim(from: 0, to: amount)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: color)
    }

    private func celebrate(animated: Bool) {
        guard animated, !reduceMotion else { checkShown = true; return }
        checkShown = false
        withAnimation(Motion.pop(0.42).delay(0.42)) { checkShown = true }
        rippleTrigger += 1
    }
}

private struct RippleFrame {
    var scale: CGFloat = 0.92
    var opacity: Double = 0
}

/// Signal-green halo that pulses outward (1.4s, scale 1 → 1.9) behind the current step.
struct PulseHalo: View {
    var diameter: CGFloat

    var body: some View {
        MotionClock(interval: 1.0 / 30) { time in
            let phase = time.map { $0.truncatingRemainder(dividingBy: 1.4) / 1.4 } ?? 0
            Circle()
                .fill(Palette.signal)
                .frame(width: diameter, height: diameter)
                .scaleEffect(1 + 0.9 * phase)
                .opacity(time == nil ? 0 : 0.7 * (1 - phase))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Discovery radar: concentric rings with two signal rings expanding outward
/// (3s each, 1.5s apart, scale 0.4 → 1, opacity 0.7 → 0) around the logo.
struct DiscoveryRadar: View {
    var isActive: Bool
    var size: CGFloat = 180

    var body: some View {
        ZStack {
            Circle().stroke(Palette.stroke, lineWidth: 1).frame(width: size * 0.61, height: size * 0.61)
            Circle().stroke(Palette.stroke, lineWidth: 1).frame(width: size * 0.83, height: size * 0.83)
            MotionClock(active: isActive, interval: 1.0 / 30) { time in
                ZStack {
                    ForEach([0.0, 1.5], id: \.self) { offset in
                        let phase = time.map { ($0 + offset).truncatingRemainder(dividingBy: 3) / 3 } ?? 0
                        Circle()
                            .stroke(Palette.signal, lineWidth: 1.2)
                            .frame(width: size, height: size)
                            .scaleEffect(0.4 + 0.6 * phase)
                            .opacity(time == nil ? 0 : 0.7 * (1 - phase))
                    }
                }
            }
            Circle()
                .fill(Palette.surface)
                .frame(width: 64, height: 64)
                .overlay { LimLinkMark(size: 30) }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The empty-state ring: a faint dashed circle turning once every 40 seconds.
struct DashedOrbit: View {
    var diameter: CGFloat

    var body: some View {
        MotionClock(interval: 1.0 / 20) { time in
            Circle()
                .stroke(Palette.faint.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 7]))
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(time.map { $0.truncatingRemainder(dividingBy: 40) / 40 * 360 } ?? 0))
        }
        .accessibilityHidden(true)
    }
}

/// Drop target outline: fades in while targeted; dashes flow one cycle every 0.8s.
struct DropTargetOutline: View {
    var isTargeted: Bool
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MotionClock(active: isTargeted, interval: 1.0 / 30) { time in
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Palette.signal, style: StrokeStyle(
                    lineWidth: 2, lineCap: .round, dash: [10, 10],
                    dashPhase: time.map { -CGFloat($0.truncatingRemainder(dividingBy: 0.8) / 0.8) * 20 } ?? 0
                ))
                .background(Palette.signal.opacity(0.06), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .opacity(isTargeted ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isTargeted)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
