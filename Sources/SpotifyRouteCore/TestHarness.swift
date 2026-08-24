import Foundation

/// Minimal assertion harness. XCTest and swift-testing both ship with Xcode and are
/// unavailable in a Command Line Tools-only toolchain, which this project targets.
public struct TestFailure: Error {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public final class TestRunner {
    private var passed = 0
    private var failures: [(String, String)] = []
    private let suiteName: String

    public init(_ suiteName: String) { self.suiteName = suiteName }

    public func test(_ label: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("  ok    \(label)")
        } catch let failure as TestFailure {
            failures.append((label, failure.message))
            print("  FAIL  \(label) — \(failure.message)")
        } catch {
            failures.append((label, "\(error)"))
            print("  FAIL  \(label) — threw \(error)")
        }
    }

    /// Returns the number of failures so a caller can aggregate several suites.
    public func summarise() -> Int {
        print("\(suiteName): \(passed) passed, \(failures.count) failed\n")
        return failures.count
    }
}

public func expect(_ condition: Bool,
                   _ message: String = "expectation failed",
                   line: UInt = #line) throws {
    if !condition { throw TestFailure("\(message) (line \(line))") }
}

public func expectEqual<T: Equatable>(_ actual: T,
                                      _ expected: T,
                                      _ message: String = "",
                                      line: UInt = #line) throws {
    if actual != expected {
        let prefix = message.isEmpty ? "" : message + ": "
        throw TestFailure("\(prefix)expected \(expected), got \(actual) (line \(line))")
    }
}

public func expectNil<T>(_ value: T?, _ message: String = "", line: UInt = #line) throws {
    if let value { throw TestFailure("\(message) expected nil, got \(value) (line \(line))") }
}
