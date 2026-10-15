import CoreMedia
import Foundation

/// The immutable description that travels with a processed image.
///
/// A route must never infer timing or layout from the payload. The producer
/// fills this value once, then every route sees the same metadata.
public struct ProcessedFrameMetadata: @unchecked Sendable, Equatable {
  public let presentationTime: CMTime
  public let duration: CMTime
  public let width: Int
  public let height: Int
  public let pixelFormat: UInt32

  public init(presentationTime: CMTime, duration: CMTime, width: Int, height: Int,
              pixelFormat: UInt32) {
    self.presentationTime = presentationTime
    self.duration = duration
    self.width = width
    self.height = height
    self.pixelFormat = pixelFormat
  }
}

/// A queue-owned frame whose payload is retained until its producer and every
/// route lease release their references.
///
/// `Payload` is deliberately generic so ownership can be tested with a small
/// value or object and later instantiated with a CVPixelBuffer by the capture
/// pipeline. The class does not perform any pixel work or route scheduling.
public final class ProcessedFrame<Payload>: @unchecked Sendable {
  private let storage: FrameStorage<Payload>

  public var payload: Payload { storage.payload }
  public var metadata: ProcessedFrameMetadata { storage.metadata }

  public init(payload: Payload, metadata: ProcessedFrameMetadata,
              onReleased: (() -> Void)? = nil) {
    storage = FrameStorage(payload: payload, metadata: metadata, onReleased: onReleased)
  }

  /// Retains one independent route reference. The returned lease must be
  /// released by the consumer; deinitialization is an idempotent safety net.
  public func retainLease() -> FrameLease<Payload> {
    storage.retainReference()
    return FrameLease(storage: storage)
  }

  deinit { storage.releaseReference() }
}

/// One route's explicit ownership of a processed frame.
public final class FrameLease<Payload>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: FrameStorage<Payload>?

  fileprivate init(storage: FrameStorage<Payload>) { self.storage = storage }

  public var isReleased: Bool {
    lock.lock()
    defer { lock.unlock() }
    return storage == nil
  }

  /// The payload is unavailable after `release` returns. Consumers should
  /// read it before releasing the lease.
  public var payload: Payload? {
    lock.lock()
    defer { lock.unlock() }
    return storage?.payload
  }

  public var metadata: ProcessedFrameMetadata? {
    lock.lock()
    defer { lock.unlock() }
    return storage?.metadata
  }

  /// Releases this route's reference exactly once. Calling it repeatedly is
  /// harmless, which lets cancellation and consumer cleanup race safely.
  public func release() {
    let retained: FrameStorage<Payload>?
    lock.lock()
    retained = storage
    storage = nil
    lock.unlock()
    retained?.releaseReference()
  }

  deinit { release() }
}

public enum FrameQueueOverflowPolicy: Equatable, Sendable {
  /// Release the oldest pending lease and enqueue the new frame.
  case dropOldest
  /// Keep all pending leases and drop the incoming frame.
  case dropNewest
  /// Keep all pending leases and report backpressure to the producer.
  case reject
}

public enum FrameRouteEnqueueResult: Equatable, Sendable {
  case enqueued
  case enqueuedDroppingOldest
  case droppedNewest
  case rejected
  case cancelled
}

public struct FrameFanOutReport: Equatable, Sendable {
  public let outcomes: [String: FrameRouteEnqueueResult]
  public let routerClosed: Bool

  public init(outcomes: [String: FrameRouteEnqueueResult], routerClosed: Bool = false) {
    self.outcomes = outcomes
    self.routerClosed = routerClosed
  }

  public subscript(routeID: String) -> FrameRouteEnqueueResult? { outcomes[routeID] }
}

public enum FrameFanOutError: Error, Equatable {
  case invalidRouteID
  case invalidCapacity
  case routerClosed
  case duplicateRoute(String)
}

/// A single output route with a bounded pending queue.
public final class FrameRoute<Payload>: @unchecked Sendable {
  public let id: String
  private weak var owner: FrameFanOut<Payload>?

  fileprivate init(id: String, owner: FrameFanOut<Payload>) {
    self.id = id
    self.owner = owner
  }

  public var isCancelled: Bool { owner?.routeIsCancelled(id) ?? true }
  public var pendingCount: Int { owner?.routePendingCount(id) ?? 0 }

  /// Removes and transfers the oldest pending lease to the caller.
  public func dequeue() -> FrameLease<Payload>? { owner?.dequeue(routeID: id) }

  /// Cancels this route and synchronously releases all leases still pending in
  /// its queue. A dequeued lease remains valid for its current consumer.
  public func cancel() { owner?.cancel(routeID: id) }
}

/// Serial, synchronous fan-out coordinator. Every mutation, including route
/// cancellation and final teardown, runs on one private serial queue. This
/// makes ownership and queue bounds deterministic without coupling the
/// contract to CaptureController or CameraSink.
public final class FrameFanOut<Payload>: @unchecked Sendable {
  private final class RouteState {
    let capacity: Int
    let policy: FrameQueueOverflowPolicy
    var pending: [FrameLease<Payload>] = []

    init(capacity: Int, policy: FrameQueueOverflowPolicy) {
      self.capacity = capacity
      self.policy = policy
    }

    func drain() {
      for lease in pending { lease.release() }
      pending.removeAll(keepingCapacity: false)
    }
  }

  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<UInt8>()
  private var routes: [String: RouteState] = [:]
  private var closed = false

  public init(label: String = "org.ultrastudiolut.frame-fanout") {
    queue = DispatchQueue(label: label, qos: .userInteractive)
    queue.setSpecific(key: queueKey, value: 1)
  }

  public func addRoute(id: String, capacity: Int,
                      policy: FrameQueueOverflowPolicy) throws -> FrameRoute<Payload> {
    guard !id.isEmpty else { throw FrameFanOutError.invalidRouteID }
    guard capacity > 0 else { throw FrameFanOutError.invalidCapacity }
    return try sync {
      guard !closed else { throw FrameFanOutError.routerClosed }
      guard routes[id] == nil else { throw FrameFanOutError.duplicateRoute(id) }
      routes[id] = RouteState(capacity: capacity, policy: policy)
      return FrameRoute(id: id, owner: self)
    }
  }

  /// Publishes one frame to every active route. Each accepted route receives a
  /// separate lease; routes never share release state or queue capacity.
  @discardableResult
  public func publish(_ frame: ProcessedFrame<Payload>) -> FrameFanOutReport {
    sync {
      guard !closed else { return FrameFanOutReport(outcomes: [:], routerClosed: true) }
      var outcomes: [String: FrameRouteEnqueueResult] = [:]
      for id in routes.keys.sorted() {
        guard let route = routes[id] else { continue }
        if route.pending.count >= route.capacity {
          switch route.policy {
          case .dropOldest:
            route.pending.removeFirst().release()
            route.pending.append(frame.retainLease())
            outcomes[id] = .enqueuedDroppingOldest
          case .dropNewest:
            outcomes[id] = .droppedNewest
          case .reject:
            outcomes[id] = .rejected
          }
        } else {
          route.pending.append(frame.retainLease())
          outcomes[id] = .enqueued
        }
      }
      return FrameFanOutReport(outcomes: outcomes)
    }
  }

  fileprivate func dequeue(routeID: String) -> FrameLease<Payload>? {
    sync {
      guard let route = routes[routeID], !closed else { return nil }
      return route.pending.isEmpty ? nil : route.pending.removeFirst()
    }
  }

  fileprivate func routePendingCount(_ routeID: String) -> Int {
    sync { routes[routeID]?.pending.count ?? 0 }
  }

  fileprivate func routeIsCancelled(_ routeID: String) -> Bool {
    sync { closed || routes[routeID] == nil }
  }

  fileprivate func cancel(routeID: String) {
    sync {
      guard let route = routes.removeValue(forKey: routeID) else { return }
      route.drain()
    }
  }

  /// Stops admission and drains every route synchronously. Calling `close`
  /// more than once is harmless. Leases already dequeued remain caller-owned.
  public func close() {
    sync {
      guard !closed else { return }
      closed = true
      for route in routes.values { route.drain() }
      routes.removeAll(keepingCapacity: false)
    }
  }

  /// Releases all queued leases while keeping routes registered for a later
  /// session generation. Dequeued leases remain owned by their consumers.
  public func drain() {
    sync {
      guard !closed else { return }
      for route in routes.values { route.drain() }
    }
  }

  public var isClosed: Bool { sync { closed } }

  deinit { close() }

  private func sync<T>(_ body: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
    return try queue.sync(execute: body)
  }
}

private final class FrameStorage<Payload>: @unchecked Sendable {
  let payload: Payload
  let metadata: ProcessedFrameMetadata
  private let lock = NSLock()
  private let onReleased: (() -> Void)?
  private var references = 1

  init(payload: Payload, metadata: ProcessedFrameMetadata, onReleased: (() -> Void)?) {
    self.payload = payload
    self.metadata = metadata
    self.onReleased = onReleased
  }

  func retainReference() {
    lock.lock()
    references += 1
    lock.unlock()
  }

  func releaseReference() {
    var callback: (() -> Void)?
    lock.lock()
    if references > 0 {
      references -= 1
      if references == 0 { callback = onReleased }
    }
    lock.unlock()
    callback?()
  }
}
