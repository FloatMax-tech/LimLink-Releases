import Foundation

/// LimLink 设计变量（规范第 11 节）。组件只读这里，不写死尺寸和字号。
struct LimLinkTheme: Equatable {
    /// 浅色用 primary（黑），深色用系统强调色。
    var accentUsesPrimaryInLightMode: Bool
    /// 规范 `size.control.height`。Mac 方案 U15 建议改成 28–32，仍待用户定，所以保持 46。
    var controlHeight: CGFloat
    var cardRadius: CGFloat
    var spaceXS: CGFloat
    var spaceS: CGFloat
    var spaceM: CGFloat
    var spaceL: CGFloat
    var spaceXL: CGFloat
    var spaceXXL: CGFloat
    /// Mac 主窗口用 240，和规范里 iPad 常规宽度、Mac 方案 3.7 一致。
    var dialDiameter: CGFloat
    var dialDiameterSmall: CGFloat
    var dialLineWidth: CGFloat
    var dialLineWidthSmall: CGFloat
    /// 约等于浅色 `systemFill`（规范 6.11：浅色约灰 20%）。macOS 没有同名系统填充色。
    var dialTrackOpacity: CGFloat
    var dialIndeterminateArc: CGFloat
    var dialIndeterminatePeriod: TimeInterval
    var dialProgressDuration: TimeInterval
    /// 12 点钟方向，SwiftUI 里再旋转 -90°。
    var dialStartAngleDegrees: Double
    var dialClockwise: Bool
    var brandFont: BrandFontToken

    static let limLink = LimLinkTheme(
        accentUsesPrimaryInLightMode: true,
        controlHeight: 46,
        cardRadius: 20,
        spaceXS: 4,
        spaceS: 6,
        spaceM: 8,
        spaceL: 12,
        spaceXL: 16,
        spaceXXL: 20,
        dialDiameter: 240,
        dialDiameterSmall: 44,
        dialLineWidth: 14,
        dialLineWidthSmall: 5,
        dialTrackOpacity: 0.20,
        dialIndeterminateArc: 0.25,
        dialIndeterminatePeriod: 1,
        dialProgressDuration: 0.3,
        dialStartAngleDegrees: -90,
        dialClockwise: true,
        brandFont: .resourceHanRoundedSubsetNotBundled
    )

    func largeDial() -> DialDrawMetrics {
        DialDrawMetrics(diameter: dialDiameter, lineWidth: dialLineWidth)
    }

    func smallDial() -> DialDrawMetrics {
        DialDrawMetrics(diameter: dialDiameterSmall, lineWidth: dialLineWidthSmall)
    }
}

struct DialDrawMetrics: Equatable {
    var diameter: CGFloat
    var lineWidth: CGFloat

    /// 规范 6.11：直径 − 2 × 环宽 − 2 × 12。
    var centerTextWidth: CGFloat {
        diameter - (2 * lineWidth) - 24
    }
}

/// `font.brand.*`。子集字体文件这一步不打包，解析不到就回系统字体。
struct BrandFontToken: Equatable {
    var enabled: Bool
    /// `font.brand.design`
    var design: String
    /// `Font.custom` 用的 PostScript 名。空字符串表示还没注册。
    var postScriptName: String
    var appliesToTitle: Bool
    var appliesToLargeTitle: Bool
    var appliesToInviteCodeDigits: Bool

    static let resourceHanRoundedSubsetNotBundled = BrandFontToken(
        enabled: true,
        design: "Resource Han Rounded CN",
        postScriptName: "",
        appliesToTitle: true,
        appliesToLargeTitle: true,
        appliesToInviteCodeDigits: true
    )
}

enum BrandFontResolution: Equatable {
    case custom(postScriptName: String)
    case system
}

enum BrandFontResolver {
    static func resolve(token: BrandFontToken, isRegistered: (String) -> Bool) -> BrandFontResolution {
        guard token.enabled else { return .system }
        let name = token.postScriptName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, isRegistered(name) else { return .system }
        return .custom(postScriptName: name)
    }
}
