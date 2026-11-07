import Foundation
import LocalAuthentication
@preconcurrency import Security

/// Long-term device identity. The private key is a nonsynchronizable Keychain item.
/// Accessibility is AfterFirstUnlock, or ThisDeviceOnly for the macOS data-protection path;
/// backup and retention behavior otherwise follows the operating system's keychain rules.
/// The certificate is self-signed `CN=limlink`, ECDSA P-256. Validity is ten years;
/// protocol 4.1 says each platform chooses the dates and verifiers ignore expiry.
public final class IdentityMaterial: @unchecked Sendable {
    public let fingerprint: Fingerprint
    public let certificateDER: Data
    public let commonName: String
    let secIdentity: sec_identity_t

    init(fingerprint: Fingerprint, certificateDER: Data, commonName: String, secIdentity: sec_identity_t) {
        self.fingerprint = fingerprint
        self.certificateDER = certificateDER
        self.commonName = commonName
        self.secIdentity = secIdentity
    }
}

public final class KeychainDeviceIdentity: @unchecked Sendable {
    private let configuration: LimLinkConfiguration
    private let lock = NSLock()

    public init(configuration: LimLinkConfiguration) {
        self.configuration = configuration
    }

    public func loadOrCreate() throws -> IdentityMaterial {
        lock.lock()
        defer { lock.unlock() }
        if let existing = try loadUnlocked() {
            return existing
        }
        return try createUnlocked()
    }

    public func reset() throws -> IdentityMaterial {
        lock.lock()
        defer { lock.unlock() }
        try deleteUnlocked()
        return try createUnlocked()
    }

    public func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        try deleteUnlocked()
    }

    /// A throwaway identity for tests. Call `delete()` on the returned store when finished.
    public static func ephemeral(deviceType: DeviceType = .mac) throws -> (material: IdentityMaterial, store: KeychainDeviceIdentity) {
        let service = "com.limlink.dev.test.\(UUID().uuidString)"
        let configuration = try LimLinkConfiguration.make(
            bundleIdentifier: LimLinkProtocol.temporaryBundleIdentifier,
            keychainService: service,
            deviceName: "limlink-test",
            deviceType: deviceType
        )
        let store = KeychainDeviceIdentity(configuration: configuration)
        let material = try store.loadOrCreate()
        return (material, store)
    }

    private var tag: Data { Data(configuration.keychainService.utf8) }

    private func loadUnlocked() throws -> IdentityMaterial? {
        guard let privateKey = try copyPrivateKey() else { return nil }
        guard let der = try copyCertificateDER() else { return nil }
        return try material(privateKey: privateKey, certificateDER: der)
    }

    private func createUnlocked() throws -> IdentityMaterial {
        let privateKey = try generatePrivateKey()
        let point = try publicPoint(of: privateKey)
        var serial = [UInt8](repeating: 0, count: 16)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        guard randomStatus == errSecSuccess else { throw TransportFailure.identityKey(randomStatus) }
        serial[0] &= 0x7f
        if serial.allSatisfy({ $0 == 0 }) { serial[15] = 1 }
        let window = CertificateBuilder.validityWindow()
        let draft = try CertificateBuilder.draft(
            uncompressedPoint: point,
            serialNumber: serial,
            notBefore: window.notBefore,
            notAfter: window.notAfter
        )
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            Data(draft.tbsCertificate) as CFData,
            &error
        ) as Data? else {
            throw TransportFailure.identityCertificate
        }
        let der = draft.finalize(signatureDER: [UInt8](signature))
        try storeCertificate(der)
        return try material(privateKey: privateKey, certificateDER: Data(der))
    }

    private func material(privateKey: SecKey, certificateDER: Data) throws -> IdentityMaterial {
        let parsed = try X509Parser.parseCertificate([UInt8](certificateDER))
        guard parsed.commonNames == [LimLinkProtocol.certificateCommonName] else {
            throw TransportFailure.identityCertificate
        }
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw TransportFailure.identityCertificate
        }
        try addCertificate(certificate)
        let identity = try copyIdentity(matching: certificateDER)
        guard let secIdentity = sec_identity_create(identity) else {
            throw TransportFailure.identityNotFound
        }
        return IdentityMaterial(
            fingerprint: parsed.fingerprint,
            certificateDER: certificateDER,
            commonName: LimLinkProtocol.certificateCommonName,
            secIdentity: secIdentity
        )
    }

    private func generatePrivateKey() throws -> SecKey {
        var last = errSecSuccess
        let attempts: [Bool] = {
            #if os(macOS)
            return [true, false]
            #else
            return [false]
            #endif
        }()
        for dataProtection in attempts {
            var error: Unmanaged<CFError>?
            let created = SecKeyCreateRandomKey(keyAttributes(dataProtection: dataProtection) as CFDictionary, &error)
            if let created { return created }
            last = (error?.takeRetainedValue()).map { OSStatus(CFErrorGetCode($0)) } ?? errSecAllocate
        }
        throw TransportFailure.identityKey(last)
    }

    private func keyAttributes(dataProtection: Bool) -> [String: Any] {
        var privateAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
            kSecAttrLabel as String: configuration.keychainService,
            kSecAttrSynchronizable as String: false,
        ]
        if dataProtection {
            privateAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        } else {
            // Legacy macOS keychains reject the ThisDeviceOnly accessibility class.
            privateAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        if let group = configuration.keychainAccessGroup {
            privateAttrs[kSecAttrAccessGroup as String] = group
        }
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: privateAttrs,
            kSecUseAuthenticationContext as String: unattendedContext(),
        ]
        #if os(macOS)
        if dataProtection {
            attributes[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        return attributes
    }

    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecUseAuthenticationContext as String: unattendedContext(),
        ]
        #if os(macOS)
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        if let group = configuration.keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    private func copyPrivateKey() throws -> SecKey? {
        try searchStores { dataProtection in
            var query = baseQuery(dataProtection: dataProtection)
            query[kSecClass as String] = kSecClassKey
            query[kSecAttrApplicationTag as String] = tag
            query[kSecAttrKeyType as String] = kSecAttrKeyTypeECSECPrimeRandom
            query[kSecReturnRef as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, secKey(item))
        }
    }

    private func unattendedContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private func secKey(_ item: CFTypeRef?) -> SecKey? {
        guard let item, CFGetTypeID(item) == SecKeyGetTypeID() else { return nil }
        return (item as! SecKey)
    }

    private func secIdentities(_ item: CFTypeRef?) -> [SecIdentity] {
        guard let item else { return [] }
        if CFGetTypeID(item) == SecIdentityGetTypeID() {
            return [item as! SecIdentity]
        }
        guard CFGetTypeID(item) == CFArrayGetTypeID() else { return [] }
        let array = item as! CFArray
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let value = CFArrayGetValueAtIndex(array, index) else { return nil }
            let element = Unmanaged<CFTypeRef>.fromOpaque(value).takeUnretainedValue()
            guard CFGetTypeID(element) == SecIdentityGetTypeID() else { return nil }
            return (element as! SecIdentity)
        }
    }

    /// Tries the data-protection keychain, then the legacy keychain on macOS.
    /// `errSecItemNotFound` means the item is absent. Other errors (for example
    /// `errSecMissingEntitlement` from an unsigned `swift test`) skip to the next store.
    private func searchStores<T>(_ body: (Bool) -> (OSStatus, T?)) throws -> T? {
        var hard: OSStatus?
        var sawNotFound = false
        for dataProtection in protectionAttempts {
            let (status, value) = body(dataProtection)
            if status == errSecSuccess, let value {
                return value
            }
            if status == errSecItemNotFound || status == errSecSuccess {
                sawNotFound = true
                continue
            }
            hard = status
        }
        if sawNotFound || hard == nil {
            return nil
        }
        throw TransportFailure.keychain(hard ?? errSecDecode)
    }

    private func publicPoint(of privateKey: SecKey) throws -> [UInt8] {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw TransportFailure.identityCertificate }
        var error: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw TransportFailure.identityCertificate
        }
        var point = [UInt8](external)
        if point.count == 64 { point.insert(0x04, at: 0) }
        guard point.count == 65, point[0] == 0x04 else { throw TransportFailure.identityCertificate }
        return point
    }

    private func storeCertificate(_ der: [UInt8]) throws {
        var last: OSStatus = errSecDecode
        for dataProtection in protectionAttempts {
            var query = baseQuery(dataProtection: dataProtection)
            query[kSecClass as String] = kSecClassGenericPassword
            query[kSecAttrService as String] = configuration.keychainService
            query[kSecAttrAccount as String] = "certificate"
            SecItemDelete(query as CFDictionary)
            query[kSecValueData as String] = Data(der)
            query[kSecAttrSynchronizable as String] = false
            if dataProtection {
                query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess || status == errSecDuplicateItem { return }
            last = status
        }
        throw TransportFailure.keychain(last)
    }

    private func copyCertificateDER() throws -> Data? {
        try searchStores { dataProtection in
            var query = baseQuery(dataProtection: dataProtection)
            query[kSecClass as String] = kSecClassGenericPassword
            query[kSecAttrService as String] = configuration.keychainService
            query[kSecAttrAccount as String] = "certificate"
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item as? Data)
        }
    }

    private func addCertificate(_ certificate: SecCertificate) throws {
        var last = errSecSuccess
        for dataProtection in protectionAttempts {
            var query = baseQuery(dataProtection: dataProtection)
            query[kSecClass as String] = kSecClassCertificate
            query[kSecValueRef as String] = certificate
            query[kSecAttrLabel as String] = configuration.keychainService
            query[kSecAttrSynchronizable as String] = false
            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess || status == errSecDuplicateItem { return }
            last = status
        }
        throw TransportFailure.keychain(last)
    }

    private func copyIdentity(matching certificateDER: Data) throws -> SecIdentity {
        if let identity = try searchStores({ dataProtection -> (OSStatus, SecIdentity?) in
            var query = baseQuery(dataProtection: dataProtection)
            query[kSecClass as String] = kSecClassIdentity
            query[kSecAttrLabel as String] = configuration.keychainService
            query[kSecReturnRef as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status != errSecSuccess {
                return (status, nil)
            }
            let identities = secIdentities(item)
            for identity in identities {
                var certificate: SecCertificate?
                guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { continue }
                if SecCertificateCopyData(certificate) as Data == certificateDER {
                    return (errSecSuccess, identity)
                }
            }
            return (errSecItemNotFound, nil)
        }) {
            return identity
        }
        throw TransportFailure.identityNotFound
    }

    private func deleteUnlocked() throws {
        for dataProtection in protectionAttempts {
            var key = baseQuery(dataProtection: dataProtection)
            key[kSecClass as String] = kSecClassKey
            key[kSecAttrApplicationTag as String] = tag
            SecItemDelete(key as CFDictionary)

            var certificate = baseQuery(dataProtection: dataProtection)
            certificate[kSecClass as String] = kSecClassCertificate
            certificate[kSecAttrLabel as String] = configuration.keychainService
            SecItemDelete(certificate as CFDictionary)

            var password = baseQuery(dataProtection: dataProtection)
            password[kSecClass as String] = kSecClassGenericPassword
            password[kSecAttrService as String] = configuration.keychainService
            password[kSecAttrAccount as String] = "certificate"
            SecItemDelete(password as CFDictionary)
        }
    }

    private var protectionAttempts: [Bool] {
        #if os(macOS)
        return [true, false]
        #else
        return [false]
        #endif
    }
}
