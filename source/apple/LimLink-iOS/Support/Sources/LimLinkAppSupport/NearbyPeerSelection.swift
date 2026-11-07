import LimLinkCoreLogic

/// Presentation filtering for the browser's already allowed nearby peers.
/// TXT advertisements can arrive before their fingerprint; those entries stay
/// hidden until the app can distinguish a peer from its own advertisement.
public enum NearbyPeerSelection {
    public static func visible(
        _ services: [DiscoveredService],
        ownFingerprint: String
    ) -> [DiscoveredService] {
        guard let own = Fingerprint(base64URL: ownFingerprint),
              own.base64URL == ownFingerprint else { return [] }

        var seen = Set<String>()
        return services.filter { service in
            guard let pin = service.fields.fingerprint,
                  let fingerprint = Fingerprint(base64URL: pin),
                  fingerprint.base64URL == pin,
                  pin != ownFingerprint else { return false }
            // Names may collide or change. The certificate fingerprint is the
            // stable identity, including duplicate advertisements/interfaces.
            return seen.insert(pin).inserted
        }
    }
}
