import Foundation

struct HermesRelayConfiguration: Codable, Equatable {
    var baseURLString: String
    var token: String
    var profile: String
    var deviceID: String

    static let empty = HermesRelayConfiguration(
        baseURLString: "",
        token: "",
        profile: "main",
        deviceID: UUID().uuidString
    )

    var baseURL: URL? {
        URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var isConfigured: Bool {
        baseURL != nil && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var sessionName: String {
        let rawProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : profile
        let device = String(deviceID.prefix(8))
        return "hermes-mobile-\(rawProfile)-\(device)"
            .replacingOccurrences(of: " ", with: "-")
    }

    init(baseURLString: String, token: String, profile: String, deviceID: String) {
        self.baseURLString = baseURLString
        self.token = token
        self.profile = profile
        self.deviceID = deviceID
    }

    init(pairingPayload: HermesPairingPayload, deviceID: String) {
        self.baseURLString = pairingPayload.url
        self.token = pairingPayload.token
        self.profile = pairingPayload.profile.isEmpty ? "main" : pairingPayload.profile
        self.deviceID = deviceID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURLString = try container.decode(String.self, forKey: .baseURLString)
        token = try container.decode(String.self, forKey: .token)
        profile = try container.decode(String.self, forKey: .profile)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID) ?? UUID().uuidString
    }
}
