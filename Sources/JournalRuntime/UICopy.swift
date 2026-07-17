public enum UICopy {
    public static let JOURNAL_CHILD_BREAKER_TRIPPED = "journal stopped after repeated exits"
    public static let JOURNAL_MATERIALIZE_FAILED = "journal runtime couldn't be prepared"
    public static let JOURNAL_SPAWN_BLOCKED_PORTS = "journal ports are still in use"
    public static let JOURNAL_SPAWN_PORT_CHECK_FAILED = "couldn't verify journal ports are free"
    public static let JOURNAL_SPAWN_BLOCKED_LEGACY_SERVICE = "journal service needs attention before starting"
    public static let JOURNAL_SPAWN_SERVICE_CHECK_FAILED = "couldn't verify journal service ownership"
    public static let JOURNAL_READINESS_TIMEOUT = "journal didn't become ready in time"
    public static let JOURNAL_SETUP_NEEDED_BEFORE_UPGRADE = "journal setup needed before upgrade can continue"
    public static let INSTALLER_READINESS_GATE_FAILED = "couldn't get the journal ready for this Mac"

    public static func installerVerifyIntegrityWarning(library: String) -> String {
        "couldn't get \(library) ready; continuing"
    }
}
