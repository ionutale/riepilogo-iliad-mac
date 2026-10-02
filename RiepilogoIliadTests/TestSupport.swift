import Foundation

/// Thread-safe holder for observations made inside @Sendable closures
/// (Swift 6 forbids capturing mutable local state in them).
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) { _value = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
