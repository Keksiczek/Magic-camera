//
//  Concurrency.swift
//  Magic Camera
//
//  Small helper for moving non-Sendable framework objects (SceneKit/Metal)
//  across a known-safe thread hop under Swift 6 strict concurrency. The caller
//  guarantees the value is used safely (e.g. produced on a background queue and
//  consumed on the main thread without further sharing).
//

struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
