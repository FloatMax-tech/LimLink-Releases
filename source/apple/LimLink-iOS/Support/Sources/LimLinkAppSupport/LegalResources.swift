import Foundation

/// Public legal resources are opened only when the user follows a link.
public enum LegalResources {
    // Company pages supplied by the user and checked for public HTTPS access.
    public static let isPublicationAvailable = true
    public static let developerName = "周甫俊"
    public static let operatorName = "杭州浮点极限科技有限公司"
    public static let supportEmail = "limlink@floatmax-tech.com"
    public static let supportEmailURL = URL(string: "mailto:limlink@floatmax-tech.com")!
    public static var privacyURL: URL { URL(string: L10n.text("https://limlink.floatmax-tech.com/privacy.html"))! }
    public static var termsURL: URL { URL(string: L10n.text("https://limlink.floatmax-tech.com/terms.html"))! }
    public static var supportURL: URL { URL(string: termsURL.absoluteString + "#section-7")! }
    public static let standardEULAURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}
