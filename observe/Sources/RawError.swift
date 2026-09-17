import Foundation

/// Explicit diagnostic input. Swift errors and JSON projections cross the worker boundary as
/// Sendable values; arbitrary objects, reflection and unrestricted NSError userInfo are unsupported.
public enum RawError: Sendable {
    /// NSError domain/code and known diagnostic fields, including underlying errors. Swift does
    /// not retain throw-site stacks: supply an already captured stack when one is available.
    case error(any Error, stack: [String] = [])
    /// Deliberate application projection. Do not include credentials or other sensitive payloads.
    case value(JSONValue)
}

/// Bounds for optional raw diagnostics. Values are clamped when serialized. A fixed 1,024-node
/// budget additionally bounds total traversal. Messages are not automatically scrubbed for PII.
public struct RawErrorOptions: Sendable {
    public var stack: Bool
    /// Stack frames: 1...100. Only explicitly supplied stacks are available on iOS.
    public var maxStackFrames: Int
    /// Object nesting below the envelope: 0...10.
    public var depth: Int
    /// Entries per projected JSON object/array and underlying-error array: 1...1,000,
    /// excluding truncation markers. Fixed NSError fields and the envelope are exempt;
    /// byte, string, depth and traversal limits still apply.
    public var maxBreadth: Int
    /// UTF-16 units per string, excluding the truncation marker: 1...10,000.
    public var maxValueLength: Int
    /// Underlying-error hops per branch: 0...10, also constrained by depth.
    public var maxCauseDepth: Int
    /// Total encoded JSON bytes including the envelope: 0...65,536. Zero omits diagnostics.
    public var maxBytes: Int

    public init(
        stack: Bool = false, maxStackFrames: Int = 50, depth: Int = 3,
        maxBreadth: Int = 30, maxValueLength: Int = 1_024,
        maxCauseDepth: Int = 3, maxBytes: Int = 32_768
    ) {
        self.stack = stack
        self.maxStackFrames = maxStackFrames
        self.depth = depth
        self.maxBreadth = maxBreadth
        self.maxValueLength = maxValueLength
        self.maxCauseDepth = maxCauseDepth
        self.maxBytes = maxBytes
    }

    fileprivate var clamped: Self {
        Self(
            stack: stack, maxStackFrames: min(max(maxStackFrames, 1), 100),
            depth: min(max(depth, 0), 10), maxBreadth: min(max(maxBreadth, 1), 1_000),
            maxValueLength: min(max(maxValueLength, 1), 10_000),
            maxCauseDepth: min(max(maxCauseDepth, 0), 10), maxBytes: min(max(maxBytes, 0), 65_536))
    }
}

/// Produce a bounded `{type, value}` envelope. Oversized graphs retry at lower depth, then return
/// a truncation marker or nil. This standalone utility has no remote-config gate; tracking calls
/// invoke it only on the worker after checking policy. No error-origin stack is manufactured.
public func serializeRawError(_ value: RawError, options: RawErrorOptions = RawErrorOptions()) -> JSONValue? {
    let limits = options.clamped
    guard limits.maxBytes > 0 else { return nil }
    let typeName: String
    switch value {
    case .error(let error, _): typeName = String(reflecting: type(of: error))
    case .value: typeName = "JSONValue"
    }
    // Bound the envelope too: generic Swift type names can be arbitrarily long.
    let type = boundedRawErrorText(typeName, limit: limits.maxValueLength)
    for depth in stride(from: limits.depth, through: 0, by: -1) {
        let walker = RawErrorWalker(limits)
        guard let payload = try? walker.walk(value, depth: depth) else { continue }
        let result: JSONValue = .object(["type": .string(type), "value": payload])
        if let data = try? JSONEncoder().encode(result), data.count <= limits.maxBytes { return result }
    }
    let marker: JSONValue = .object(["type": .string(type), "truncated": true])
    guard let data = try? JSONEncoder().encode(marker), data.count <= limits.maxBytes else { return nil }
    return marker
}

private enum RawErrorBudgetExceeded: Error { case exhausted }

private final class RawErrorWalker {
    private let limits: RawErrorOptions
    private var nodes = 0
    private var textBudget: Int
    private var ancestors: Set<ObjectIdentifier> = []

    init(_ limits: RawErrorOptions) {
        self.limits = limits
        textBudget = limits.maxBytes
    }

    func walk(_ value: RawError, depth: Int) throws -> JSONValue {
        switch value {
        case .error(let error, let stack):
            var fields = try errorFields(error, depth: depth, causes: limits.maxCauseDepth)
            if limits.stack && !stack.isEmpty {
                fields["stack"] = try stackValue(stack)
                if stack.count > limits.maxStackFrames { fields["stackTruncated"] = true }
            }
            return .object(fields)
        case .value(let value): return try json(value, depth: depth)
        }
    }

    private func visit() throws {
        nodes += 1
        if nodes > 1_024 { throw RawErrorBudgetExceeded.exhausted }
    }

    private func errorFields(_ error: any Error, depth: Int, causes: Int) throws -> [String: JSONValue] {
        try visit()
        let native = error as NSError
        let identity = ObjectIdentifier(native)
        guard ancestors.insert(identity).inserted else { return ["cause": "[Circular]"] }
        defer { ancestors.remove(identity) }
        var result: [String: JSONValue] = [
            "name": try text(String(describing: type(of: error))),
            "domain": try text(native.domain),
            "code": .int(Int64(native.code)),
        ]
        // Read only established diagnostic keys. URL, file, credential and arbitrary object
        // values in userInfo are deliberately excluded. Do not invoke description or reflection.
        let info = native.userInfo
        for (key, field) in [
            (NSLocalizedDescriptionKey, "message"), (NSLocalizedFailureReasonErrorKey, "failureReason"),
            (NSLocalizedRecoverySuggestionErrorKey, "recoverySuggestion"),
            (NSDebugDescriptionErrorKey, "debugDescription"),
        ] {
            if let message = info[key] as? String { result[field] = try text(message) }
        }
        if let cause = info[NSUnderlyingErrorKey] as? any Error {
            result["cause"] = try underlying(cause, depth: depth, causes: causes)
        }
        if let errors = info[NSMultipleUnderlyingErrorsKey] as? NSArray {
            var children: [JSONValue] = []
            for index in 0..<min(errors.count, limits.maxBreadth) {
                try visit()
                if let cause = errors[index] as? any Error {
                    children.append(try underlying(cause, depth: depth, causes: causes))
                }
            }
            if errors.count > limits.maxBreadth { children.append("[Truncated]") }
            result["causes"] = .array(children)
        }
        return result
    }

    private func underlying(_ error: any Error, depth: Int, causes: Int) throws -> JSONValue {
        guard depth > 0 && causes > 0 else { return try text("[\(String(reflecting: type(of: error)))]") }
        return .object(try errorFields(error, depth: depth - 1, causes: causes - 1))
    }

    private func json(_ value: JSONValue, depth: Int) throws -> JSONValue {
        try visit()
        switch value {
        case .null, .bool, .int: return value
        case .double(let number): return number.isFinite ? value : try text(String(number))
        case .string(let string): return try text(string)
        case .array(let values):
            guard depth >= 0 else { return "[Array]" }
            var result = try values.prefix(limits.maxBreadth).map { try json($0, depth: depth - 1) }
            if values.count > limits.maxBreadth { result.append("[Truncated]") }
            return .array(result)
        case .object(let values):
            guard depth >= 0 else { return "[Object]" }
            return try object(values, depth: depth)
        }
    }

    private func object(_ values: [String: JSONValue], depth: Int) throws -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (key, child) in values.prefix(limits.maxBreadth) {
            if key == "stack" {
                guard limits.stack else { continue }
                switch child {
                case .array(let frames):
                    result["stack"] = try json(.array(Array(frames.prefix(limits.maxStackFrames))), depth: depth - 1)
                case .string(let stack):
                    let bounded = try text(stack).stringValue!
                    result["stack"] = .string(
                        bounded.split(separator: "\n", omittingEmptySubsequences: false)
                            .prefix(limits.maxStackFrames).joined(separator: "\n"))
                default: break
                }
            } else {
                let boundedKey = try text(key).stringValue!
                result[boundedKey] = try json(child, depth: depth - 1)
            }
        }
        if values.count > limits.maxBreadth { result["…"] = "[Truncated]" }
        return .object(result)
    }

    private func stackValue(_ frames: [String]) throws -> JSONValue {
        var result: [String] = []
        for frame in frames.prefix(limits.maxStackFrames) {
            try visit()
            result.append(try text(frame).stringValue!)
        }
        return try text(result.joined(separator: "\n"))
    }

    private func text(_ value: String) throws -> JSONValue {
        let result = boundedRawErrorText(value, limit: limits.maxValueLength)
        let encoded = try JSONEncoder().encode(result)
        textBudget -= encoded.count
        if textBudget < 0 { throw RawErrorBudgetExceeded.exhausted }
        return .string(result)
    }
}

private func boundedRawErrorText(_ value: String, limit: Int) -> String {
    // Scalar iteration avoids scanning an unbounded combining-character cluster and never
    // splits a surrogate pair. The walker charges escaped UTF-8 before retaining this string.
    var result = ""
    var units = 0
    for scalar in value.unicodeScalars {
        units += scalar.utf16.count
        if units > limit {
            result += "…"
            break
        }
        result.unicodeScalars.append(scalar)
    }
    return result
}
