import Foundation

struct HermesPairingPayload: Codable, Equatable {
    var service: String
    var url: String
    var token: String
    var profile: String

    var isHermesRelay: Bool {
        service == "hermes-mobile-relay"
    }

    static func parse(_ text: String) -> HermesPairingPayload? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = trimmed.data(using: .utf8),
           let payload = try? JSONDecoder().decode(HermesPairingPayload.self, from: data),
           payload.isHermesRelay {
            return payload
        }

        guard let components = URLComponents(string: trimmed),
              components.scheme == "hermesmobile",
              components.host == "pair" else {
            return nil
        }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String {
            items.first { $0.name == name }?.value ?? ""
        }

        let payload = HermesPairingPayload(
            service: "hermes-mobile-relay",
            url: value("url"),
            token: value("token"),
            profile: value("profile").isEmpty ? "main" : value("profile")
        )
        return payload.url.isEmpty || payload.token.isEmpty ? nil : payload
    }
}
