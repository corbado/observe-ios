/// SDK identity stamped on every event batch so buggy versions can be excluded server-side.
///
/// SPM has no build-time property injection: `version` is bumped by hand as part of the
/// release process (see RELEASING.md) and must always match the repo tag being released.
public enum Sdk {
    public static let name = "observe-ios"
    public static let version = "0.1.2-dev"
}
