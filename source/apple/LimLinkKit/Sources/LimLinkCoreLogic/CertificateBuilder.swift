import Foundation

enum ASN1OID {
    /// 1.2.840.10045.2.1 ecPublicKey
    static let ecPublicKey: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]
    /// 1.2.840.10045.3.1.7 prime256v1
    static let prime256v1: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]
    /// 1.2.840.10045.4.3.2 ecdsa-with-SHA256
    static let ecdsaWithSHA256: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]
    /// 2.5.4.3 commonName
    static let commonName: [UInt8] = [0x55, 0x04, 0x03]
    /// 2.5.29.19 basicConstraints
    static let basicConstraints: [UInt8] = [0x55, 0x1d, 0x13]
    /// 2.5.29.15 keyUsage
    static let keyUsage: [UInt8] = [0x55, 0x1d, 0x0f]
    /// 2.5.29.37 extKeyUsage
    static let extKeyUsage: [UInt8] = [0x55, 0x1d, 0x25]
    /// 1.3.6.1.5.5.7.3.1 serverAuth
    static let serverAuth: [UInt8] = [0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]
    /// 1.3.6.1.5.5.7.3.2 clientAuth
    static let clientAuth: [UInt8] = [0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02]
}

public struct ParsedCertificate: Equatable, Sendable {
    public var commonNames: [String]
    public var spki: [UInt8]
    public var fingerprint: Fingerprint

    public init(commonNames: [String], spki: [UInt8], fingerprint: Fingerprint) {
        self.commonNames = commonNames
        self.spki = spki
        self.fingerprint = fingerprint
    }
}

public struct CertificateDraft: Sendable {
    public var tbsCertificate: [UInt8]
    public var spki: [UInt8]
    public var commonName: String

    public func finalize(signatureDER: [UInt8]) -> [UInt8] {
        DER.sequence(
            tbsCertificate,
            signatureAlgorithmIdentifier(),
            DER.bitString(signatureDER)
        )
    }
}

/// Minimal self-signed X.509 v3 certificate: subject and issuer are exactly `CN=limlink`,
/// key is ECDSA P-256. The signature is supplied by the caller (Security.framework on Apple).
/// Validity is platform-defined (protocol 4.1); this builder uses UTC dates and does not
/// require the verifier to look at them.
public enum CertificateBuilder {
    public static func subjectPublicKeyInfo(uncompressedPoint: [UInt8]) throws -> [UInt8] {
        guard uncompressedPoint.count == 65, uncompressedPoint[0] == 0x04 else {
            throw CertificateError.invalidPublicPoint
        }
        let algorithm = DER.sequence(
            DER.oid(ASN1OID.ecPublicKey),
            DER.oid(ASN1OID.prime256v1)
        )
        return DER.sequence(algorithm, DER.bitString(uncompressedPoint))
    }

    public static func draft(
        uncompressedPoint: [UInt8],
        serialNumber: [UInt8],
        notBefore: Date,
        notAfter: Date,
        commonName: String = LimLinkProtocol.certificateCommonName
    ) throws -> CertificateDraft {
        let spki = try subjectPublicKeyInfo(uncompressedPoint: uncompressedPoint)
        let name = distinguishedName(commonName)
        let version = DER.context(0, DER.integer([2]))
        let tbs = DER.sequence(
            version,
            DER.integer(serialNumber),
            signatureAlgorithmIdentifier(),
            name,
            validity(notBefore: notBefore, notAfter: notAfter),
            name,
            spki,
            extensions()
        )
        return CertificateDraft(tbsCertificate: tbs, spki: spki, commonName: commonName)
    }

    public static func validityWindow(now: Date = Date()) -> (notBefore: Date, notAfter: Date) {
        let notBefore = now.addingTimeInterval(-LimLinkProtocol.certificateNotBeforeSkewSeconds)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let notAfter = calendar.date(byAdding: .year, value: LimLinkProtocol.certificateValidityYears, to: now) ?? now
        return (notBefore, notAfter)
    }
}

public enum X509Parser {
    public static func parseCertificate(_ der: [UInt8]) throws -> ParsedCertificate {
        let outer = try DER.readNode(der[...]).node
        guard outer.tag == 0x30 else { throw CertificateError.unexpectedStructure }
        let top = try DER.children(outer.content)
        guard let tbs = top.first, tbs.tag == 0x30 else { throw CertificateError.unexpectedStructure }
        var fields = try DER.children(tbs.content)
        if fields.first?.tag == 0xa0 {
            fields.removeFirst()
        }
        // serial, signature, issuer, validity, subject, spki
        guard fields.count >= 6 else { throw CertificateError.unexpectedStructure }
        guard fields[5].tag == 0x30 else { throw CertificateError.unexpectedStructure }
        let names = try commonNames(in: fields[4].content)
        let fingerprint = Fingerprint(spkiDER: fields[5].span)
        return ParsedCertificate(commonNames: names, spki: fields[5].span, fingerprint: fingerprint)
    }
}

private func signatureAlgorithmIdentifier() -> [UInt8] {
    DER.sequence(DER.oid(ASN1OID.ecdsaWithSHA256))
}

private func distinguishedName(_ commonName: String) -> [UInt8] {
    let attribute = DER.sequence(
        DER.oid(ASN1OID.commonName),
        DER.utf8(commonName)
    )
    return DER.sequence(DER.tlv(0x31, attribute))
}

private func validity(notBefore: Date, notAfter: Date) -> [UInt8] {
    DER.sequence(time(notBefore), time(notAfter))
}

private func time(_ date: Date) -> [UInt8] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let year = parts.year ?? 1970
    let month = parts.month ?? 1
    let day = parts.day ?? 1
    let hour = parts.hour ?? 0
    let minute = parts.minute ?? 0
    let second = parts.second ?? 0
    if (1950..<2050).contains(year) {
        let rendered = String(format: "%02d%02d%02d%02d%02d%02dZ", year % 100, month, day, hour, minute, second)
        return DER.tlv(0x17, Array(rendered.utf8))
    }
    let rendered = String(format: "%04d%02d%02d%02d%02d%02dZ", year, month, day, hour, minute, second)
    return DER.tlv(0x18, Array(rendered.utf8))
}

private func extensions() -> [UInt8] {
    let basic = extensionItem(
        oid: ASN1OID.basicConstraints,
        critical: true,
        value: DER.sequence(DER.tlv(0x01, [0x00]))
    )
    // digitalSignature is bit 0: unused bits = 7, payload = 0x80.
    let usage = extensionItem(
        oid: ASN1OID.keyUsage,
        critical: true,
        value: DER.bitString([0x80], unusedBits: 7)
    )
    let eku = extensionItem(
        oid: ASN1OID.extKeyUsage,
        critical: false,
        value: DER.sequence(DER.oid(ASN1OID.serverAuth), DER.oid(ASN1OID.clientAuth))
    )
    return DER.context(3, DER.sequence(basic, usage, eku))
}

private func extensionItem(oid: [UInt8], critical: Bool, value: [UInt8]) -> [UInt8] {
    var parts = [DER.oid(oid)]
    if critical {
        parts.append(DER.tlv(0x01, [0xff]))
    }
    parts.append(DER.octetString(value))
    return DER.sequence(parts.flatMap { $0 })
}

private func commonNames(in subjectContent: [UInt8]) throws -> [String] {
    var names: [String] = []
    let rdns = try DER.children(subjectContent)
    for rdn in rdns where rdn.tag == 0x31 {
        let attributes = try DER.children(rdn.content)
        for attribute in attributes where attribute.tag == 0x30 {
            let pieces = try DER.children(attribute.content)
            guard pieces.count >= 2, pieces[0].tag == 0x06, pieces[0].content == ASN1OID.commonName else { continue }
            let stringTag = pieces[1].tag
            guard stringTag == 0x0c || stringTag == 0x13 || stringTag == 0x16 else { continue }
            guard let text = String(bytes: pieces[1].content, encoding: .utf8) else { continue }
            names.append(text)
        }
    }
    return names
}
