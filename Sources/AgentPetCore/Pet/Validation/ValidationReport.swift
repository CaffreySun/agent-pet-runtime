import Foundation

public enum ValidationSeverity: String, Sendable, Equatable, Comparable {
    /// The package cannot be used.
    case error
    /// The package works but deviates from the contract.
    case warning

    private var rank: Int { self == .error ? 0 : 1 }

    public static func < (lhs: ValidationSeverity, rhs: ValidationSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct ValidationIssue: Sendable, Equatable {
    /// Which stage produced the issue, e.g. `"manifest"`, `"atlas"`.
    public let stage: String
    public let severity: ValidationSeverity
    public let message: String

    public init(stage: String, severity: ValidationSeverity, message: String) {
        self.stage = stage
        self.severity = severity
        self.message = message
    }
}

public struct ValidationReport: Sendable, Equatable {
    public private(set) var issues: [ValidationIssue]

    public init(issues: [ValidationIssue] = []) {
        self.issues = issues
    }

    public var isValid: Bool {
        !issues.contains { $0.severity == .error }
    }

    public var errors: [ValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ValidationIssue] { issues.filter { $0.severity == .warning } }

    public mutating func add(_ issue: ValidationIssue) {
        issues.append(issue)
    }

    public mutating func add(_ stage: String, _ severity: ValidationSeverity, _ message: String) {
        add(ValidationIssue(stage: stage, severity: severity, message: message))
    }

    public mutating func merge(_ other: ValidationReport) {
        issues.append(contentsOf: other.issues)
    }
}
