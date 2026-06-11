import XCTest
@testable import HermesMobile

final class HermesPairingPayloadTests: XCTestCase {
    func testParsesJSONPayload() throws {
        let payload = HermesPairingPayload.parse(
            #"{"service":"hermes-mobile-relay","url":"http://192.168.1.2:8787","token":"abc","profile":"main"}"#
        )

        XCTAssertEqual(payload?.url, "http://192.168.1.2:8787")
        XCTAssertEqual(payload?.token, "abc")
        XCTAssertEqual(payload?.profile, "main")
    }

    func testParsesDeepLinkPayload() throws {
        let payload = HermesPairingPayload.parse(
            "hermesmobile://pair?url=http%3A%2F%2F192.168.1.2%3A8787&token=abc&profile=orchestrator"
        )

        XCTAssertEqual(payload?.url, "http://192.168.1.2:8787")
        XCTAssertEqual(payload?.token, "abc")
        XCTAssertEqual(payload?.profile, "orchestrator")
    }

    func testRejectsNonHermesPayload() throws {
        XCTAssertNil(HermesPairingPayload.parse(#"{"service":"other","url":"http://x","token":"abc","profile":"main"}"#))
    }
}
