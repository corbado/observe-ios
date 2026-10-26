import AuthenticationServices
import Foundation
import Testing

@testable import CorbadoObserve

/// Typed-path coverage: `AuthenticationServices` results serialize `userID` as `userHandle`.
extension TrackerIntegrationTests {
    private func ceremonyUserHandle(_ options: ObserveOptions) async throws -> JSONValue? {
        let (tracker, transport) = await makeTracker(options: options)
        tracker.passkeyLoginOperation().begin(specType: .knownIdentifier)
            .ceremonyFinished(assertion: FakeAssertion(userID: Data("user@example.com".utf8)))
        let events = await drain(tracker, transport, eventCount: 3)
        let finished = try #require(events.first { $0.name == "subflow_step_finished" })
        let raw = try #require(finished.data.objectValue?["stepData"]?.objectValue?["assertionResponse"]?.stringValue)
        let root = try #require(try WireJson.decoder.decode(JSONValue.self, from: Data(raw.utf8)).objectValue)
        let response = try #require(root["response"]?.objectValue)
        #expect(response["signature"] == nil)
        #expect(response["authenticatorData"] != nil)
        return response["userHandle"]
    }

    @Test func typedAssertionOmitsUserHandleByDefault() async throws {
        let options = ObserveOptions(projectId: "pro-test", apiBaseUrl: "https://example.invalid")
        #expect(try await ceremonyUserHandle(options) == nil)
    }

    @Test func typedAssertionSendsProjectedUserHandle() async throws {
        let received = Locked<String?>(nil)
        let options = ObserveOptions(
            projectId: "pro-test", apiBaseUrl: "https://example.invalid",
            identifierProjectors: WebAuthnIdentifierProjectors { value in
                received.value = value
                return .value("hashed")
            })
        #expect(try await ceremonyUserHandle(options) == .string("hashed"))
        #expect(received.value == WebAuthnSanitizer.base64Url(Data("user@example.com".utf8)))
    }
}

final class FakeAssertion: NSObject, ASAuthorizationPublicKeyCredentialAssertion, @unchecked Sendable {
    let rawAuthenticatorData: Data! = Data([1])
    let userID: Data!
    let signature: Data! = Data("SECRET".utf8)
    let rawClientDataJSON = Data([2])
    let credentialID = Data([3])

    init(userID: Data) {
        self.userID = userID
    }

    static var supportsSecureCoding: Bool { true }
    func encode(with coder: NSCoder) {}
    init?(coder: NSCoder) { nil }
    func copy(with zone: NSZone? = nil) -> Any { self }
}
