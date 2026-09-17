import AuthenticationServices
import Foundation
import Testing

@testable import CorbadoObserve

@Suite struct RawErrorTests {
    @Test func preservesPlatformDomainCodeAndCausesWithoutArbitraryUserInfo() throws {
        let cause = NSError(domain: NSOSStatusErrorDomain, code: -34018)
        let error = NSError(
            domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.failed.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "Provider failed", NSUnderlyingErrorKey: cause,
                NSDebugDescriptionErrorKey: "Missing entitlement", "credential": "secret",
                NSURLErrorKey: URL(string: "https://example.invalid/token")!, "binary": Data([1, 2, 3]),
            ])
        let result = try #require(serializeRawError(.error(error))?.objectValue?["value"]?.objectValue)
        #expect(result["domain"] == .string(ASAuthorizationError.errorDomain))
        #expect(result["code"] == .int(1004))
        #expect(result["message"] == "Provider failed")
        #expect(result["debugDescription"] == "Missing entitlement")
        #expect(result["cause"]?.objectValue?["code"] == .int(-34018))
        #expect(result["cause"]?.objectValue?["domain"] == .string(NSOSStatusErrorDomain))
        #expect(result["credential"] == nil)
        #expect(result["binary"] == nil)
        #expect(result[NSURLErrorKey] == nil)
        #expect(NormalizedError.from(error).code == "\(ASAuthorizationError.errorDomain):1004")
    }

    @Test func swiftErrorsBridgeWithoutReflectingAssociatedValues() throws {
        enum SecretError: Error { case rejected(token: String) }
        let raw = try #require(serializeRawError(.error(SecretError.rejected(token: "do-not-send"))))
        let text = try #require(String(data: JSONEncoder().encode(raw), encoding: .utf8))
        #expect(!text.contains("do-not-send"))
        #expect(raw.objectValue?["value"]?.objectValue?["domain"] != nil)
    }

    @Test func stacksRequireOptInAndAreNeverSynthesized() throws {
        let error = NSError(domain: "test", code: 1)
        let input = RawError.error(error, stack: ["frame1", "frame2", "frame3"])
        #expect(serializeRawError(input)?.objectValue?["value"]?.objectValue?["stack"] == nil)
        let enabled = try #require(
            serializeRawError(input, options: RawErrorOptions(stack: true, maxStackFrames: 2))?
                .objectValue?["value"]?.objectValue)
        #expect(enabled["stack"] == "frame1\nframe2")
        #expect(enabled["stackTruncated"] == true)
        #expect(
            serializeRawError(.error(error), options: RawErrorOptions(stack: true))?
                .objectValue?["value"]?.objectValue?["stack"] == nil)
        let projection: JSONValue = ["nested": ["stack": "private", "reason": "visible"]]
        let raw = try #require(serializeRawError(.value(projection)))
        #expect(raw.objectValue?["value"]?.objectValue?["nested"]?.objectValue?["stack"] == nil)
    }

    @Test func boundsCauseDepthAndMultipleUnderlyingErrors() throws {
        let inner = NSError(domain: "inner", code: 2)
        let outer = NSError(
            domain: "outer", code: 1,
            userInfo: [NSUnderlyingErrorKey: inner, NSMultipleUnderlyingErrorsKey: [inner, inner, inner]])
        let bounded = try #require(
            serializeRawError(.error(outer), options: RawErrorOptions(maxBreadth: 1, maxCauseDepth: 0))?
                .objectValue?["value"]?.objectValue)
        #expect(bounded["cause"]?.stringValue != nil)
        if case .array(let causes) = bounded["causes"] {
            #expect(causes.count == 2)
            #expect(causes.last == "[Truncated]")
        } else {
            Issue.record("Missing bounded causes")
        }
    }

    @Test func cyclicNSErrorTerminates() throws {
        let raw = try #require(serializeRawError(.error(CyclicError(domain: "cyclic", code: 1))))
        let encoded = try #require(String(data: JSONEncoder().encode(raw), encoding: .utf8))
        #expect(encoded.contains("[Circular]"))
    }

    @Test func pathologicalGraphsAndByteLimitsStayBounded() throws {
        var value: JSONValue = .string(String(repeating: "😀\"\\", count: 20_000))
        for _ in 0..<12 { value = .array(Array(repeating: value, count: 40)) }
        for bytes in [0, 1, 50, 256, 4_096, 65_536] {
            if let result = serializeRawError(
                .value(value), options: RawErrorOptions(depth: 10, maxBreadth: 1_000, maxBytes: bytes))
            {
                #expect(try JSONEncoder().encode(result).count <= bytes)
            }
        }
        #expect(serializeRawError(.value(value), options: RawErrorOptions(maxBytes: 0)) == nil)
        let nonfinite = serializeRawError(.value(.double(.infinity)))
        #expect(nonfinite?.objectValue?["value"] == "inf")
    }

    @Test func unicodeAndHostileLimitsDoNotTrap() throws {
        let text = "😀" + String(repeating: "\u{0301}", count: 50_000)
        let result = try #require(
            serializeRawError(.value(.string(text)), options: RawErrorOptions(maxValueLength: 3)))
        #expect(result.objectValue?["value"] == .string("😀\u{0301}…"))
        let tiny = serializeRawError(
            .value(["x": "value"]),
            options: RawErrorOptions(
                maxStackFrames: .min, depth: .min, maxBreadth: .min, maxValueLength: .min,
                maxCauseDepth: .min, maxBytes: .max))
        #expect(tiny != nil)
    }

    @Test(arguments: ["false", "null", "1", "0", "\"true\"", "[]", "{}"])
    func configOnlyAcceptsJSONBoolean(value: String) throws {
        let config = try #require(SdkConfig.parse("{\"rawErrors\":\(value)}"))
        #expect(!config.rawErrors)
        #expect(!SdkConfig.default.rawErrors)
        #expect(SdkConfig.parse("{\"rawErrors\":true}")?.rawErrors == true)
    }
}

private final class CyclicError: NSError, @unchecked Sendable {
    override var userInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
}
