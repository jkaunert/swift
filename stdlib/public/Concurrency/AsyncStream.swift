//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Swift

/// An asynchronous sequence generated from a closure that calls a continuation
/// to produce new elements.
///
/// `AsyncStream` conforms to `AsyncSequence`, providing a convenient way to
/// create an asynchronous sequence without manually implementing an
/// asynchronous iterator. In particular, an asynchronous stream is well-suited
/// to adapt callback- or delegation-based APIs to participate with
/// `async`/`await`.
///
/// You initialize an `AsyncStream` with a closure that receives an
/// `AsyncStream.Continuation`. Produce elements in this closure, then provide
/// them to the stream by calling the continuation's `yield(_:)` method. When
/// there are no further elements to produce, call the continuation's
/// `finish()` method. This causes the sequence iterator to produce a `nil`,
/// which terminates the sequence. The continuation conforms to `Sendable`, which permits
/// calling it from concurrent contexts external to the iteration of the
/// `AsyncStream`.
///
/// An arbitrary source of elements can produce elements faster than they are
/// consumed by a caller iterating over them. Because of this, `AsyncStream`
/// defines a buffering behavior, allowing the stream to buffer a specific
/// number of oldest or newest elements. By default, the buffer limit is
/// unbounded, that is, `Int.max`.
///
/// ### Adapting Existing Code to Use Streams
///
/// To adapt existing callback code to use `async` / `await`, use the callbacks
/// to provide values to the stream, by using the continuation's `yield(_:)`
/// method.
///
/// Consider a hypothetical `QuakeMonitor` type that provides callers with
/// `Quake` instances every time it detects an earthquake. To receive callbacks,
/// callers set a custom closure as the value of the monitor's
/// `quakeHandler` property, which the monitor calls back as necessary.
///
///     class QuakeMonitor {
///         var quakeHandler: ((Quake) -> Void)?
///
///         func startMonitoring() {…}
///         func stopMonitoring() {…}
///     }
///
/// To adapt this to use `async`-`await`, extend the `QuakeMonitor` to add a
/// `quakes` property, of type `AsyncStream<Quake>`. In the getter for this
/// property, return an `AsyncStream`, whose `build` closure -- called at
/// runtime to create the stream -- does the following:
///
/// 1. Creates a `QuakeMonitor` instance.
/// 2. Sets the monitor's `quakeHandler` property to a closure that receives
/// each `Quake` instance and forwards it to the stream by calling the
/// continuation's `yield(_:)` method.
/// 3. Sets the continuation's `onTermination` property to a closure that
/// calls `stopMonitoring()` on the monitor.
/// 4. Finally, calls `startMonitoring` on the `QuakeMonitor`.
///
///     extension QuakeMonitor {
///
///         static var quakes: AsyncStream<Quake> {
///             AsyncStream { continuation in
///                 let monitor = QuakeMonitor()
///                 monitor.quakeHandler = { quake in
///                     continuation.yield(quake)
///                 }
///                 continuation.onTermination = { @Sendable _ in
///                     monitor.stopMonitoring()
///                 }
///                 monitor.startMonitoring()
///             }
///         }
///     }
///
/// Because the stream is an `AsyncSequence`, the call point can use the
/// `for`-`await`-`in` syntax to process each `Quake` instance as the stream
/// produces it:
///
///     for await quake in QuakeMonitor.quakes {
///         print ("Quake: \(quake.date)")
///     }
///     print ("Stream finished.")
///
@available(SwiftStdlib 5.5, *)
public struct AsyncStream<Element> {
    
  /// A mechanism to interface between synchronous code and an asynchronous
  /// stream.
  ///
  /// The closure you provide to the `AsyncStream` in
  /// `init(_:bufferingPolicy:_:)` receives an instance of this type when
  /// invoked. Use this continuation to provide elements to the stream by
  /// calling one of the `yield` methods, then terminate the stream normally by
  /// calling the `finish()` method.
  public struct Continuation: Sendable {
    /// A type that indicates how the stream terminated.
    ///
    /// The `onTermination` closure receives an instance of this type.
    public enum Termination {
      
      /// The stream finished as a result of calling the continuation's
      ///  `finish` method.
      case finished
      
      /// The stream finished as a result of cancellation.
      case cancelled
    }
    
    /// A type that indicates the result of yielding a value to a client, by
    /// way of the continuation.
    ///
    /// The various `yield` methods of `AsyncStream.Continuation` return this
    /// type to indicate the success or failure of yielding an element to the
    /// continuation.
    public enum YieldResult {
      
      /// The stream successfully enqueued the element.
      ///
      /// This value reprsents the successful enqueueing of an element, whether
      /// the stream buffers the element or delivers it immediately to a pending
      /// call to `next()`. The associated value `remaining` is a hint that
      /// indicates the number of remaining slots in the buffer at the time of
      /// the `yield` call.
      ///
      /// - Note: From a thread safety viewpoint, `remaining` is a lower bound
      /// on the number of remaining slots. This is because a subsequent call
      /// that uses the `remaining` value could race on the consumption of
      /// values from the stream.
      case enqueued(remaining: Int)
      
      /// The stream didn't enqueue the element due to a full buffer.
      ///
      /// The associated element for this case is the element that the stream
      /// dropped.
      case dropped(Element)
      
      /// The stream didn't enqueue the element because the stream was in a
      /// terminal state.
      ///
      /// This indicates the stream terminated prior to calling `yield`, either
      /// because the stream finished normally or through cancellation.
      case terminated
    }
    
    /// A strategy that handles exhaustion of a buffer’s capacity.
    public enum BufferingPolicy {
      /// Continue to add to the buffer, without imposing a limit on the number
      /// of buffered elements.
      case unbounded
      
      /// When the buffer is full, discard the newly received element.
      ///
      /// This strategy enforces keeping at most the specified number of oldest
      /// values.
      case bufferingOldest(Int)
      
      /// When the buffer is full, discard the oldest element in the buffer.
      ///
      /// This strategy enforces keeping at most the specified number of newest
      /// values.
      case bufferingNewest(Int)
    }

    let storage: _Storage

    /// Resume the task awaiting the next iteration point by having it return
    /// nomally from its suspension point with a given element.
    ///
    /// - Parameter value: The value to yield from the continuation.
    /// - Returns: A `YieldResult` indicating the success or failure of the
    ///   yield operation.
    ///
    /// If nothing is awaiting the next value, this method attempts to buffer the
    /// result's element.
    ///
    /// This can be called more than once and returns to the caller immediately
    /// without blocking for any awaiting consumption from the iteration.
    @discardableResult
    public func yield(_ value: __owned Element) -> YieldResult {
      storage.yield(value)
    }

    /// Resume the task awaiting the next iteration point by having it return
    /// nil, which signifies the end of the iteration.
    ///
    /// Calling this function more than once has no effect. Once you call
    /// finish, the stream enters a terminal state and produces no further
    /// elements.
    public func finish() {
      storage.finish()
    }

    /// A callback to invoke when canceling iteration of an asynchronous
    /// stream.
    ///
    /// If an `onTermination` callback is set, using task cancellation to
    /// terminate iteration of a `AsyncStream` results in a call to this
    /// callback.
    ///
    /// Canceling an active iteration invokes the `onTermination` callback
    /// first, then resumes by yielding `nil`. This means that you can perform
    /// needed cleanup in the cancellation handler. After reaching a terminal
    /// state as a result of cancellation, the `AsyncStream` sets the callback
    /// to `nil`.
    public var onTermination: (@Sendable (Termination) -> Void)? {
      get {
        return storage.getOnTermination()
      }
      nonmutating set {
        storage.setOnTermination(newValue)
      }
    }
  }

  let produce: () async -> Element?

  /// Constructs an asynchronous stream for an element type, using the
  /// specified buffering policy and element-producing closure.
  ///
  /// - Parameter elementType: The type of element the `AsyncStream`
  ///   produces.
  /// - Parameter bufferingPolicy: A `Continuation.BufferingPolicy` value to
  ///   set the stream's buffering behavior. By default, the stream buffers an
  ///   unlimited number of elements. You can also set the policy to buffer a
  ///   specified number of oldest or newest elements.
  /// - Parameter build: A custom closure that yields values to the
  ///   `AsyncStream`. This closure receives a `AsyncStream.Continuation`
  ///   instance that it uses to provide elements to the stream and terminate the
  ///   stream when finished.
  ///
  /// The `AsyncStream.Continuation` received by the `build` closure is appopriate
  /// for use in concurrent contexts. It is thread safe to send and finish; all
  /// calls are to the continuation are serialized, however calling this from
  /// multiple concurrent contexts could result in out-of-order delivery.
  ///
  /// The following example shows an `AsyncStream` created with this
  /// initializer that produces random numbers on a one-second interval. When
  /// a private `keepRunning` variable becomes `false`, the inner `while` loop
  /// exits and the stream finishes.
  ///
  ///     let stream = AsyncStream<Int>(Int.self,
  ///                                   bufferingPolicy: .bufferingNewest(5)) { continuation in
  ///             Task.detached {
  ///                 while keepRunning {
  ///                     await Task.sleep(1 * 1_000_000_000)
  ///                     continuation.yield(Int.random(in: 1...10))
  ///                 }
  ///                 continuation.finish()
  ///             }
  ///         }
  ///
  ///     // call point:
  ///     for await random in stream {
  ///         print ("\(random)")
  ///     }
  ///
  public init(
    _ elementType: Element.Type = Element.self,
    bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded,
    _ build: (Continuation) -> Void
  ) {
    let storage: _Storage = .create(limit: limit)
    self.init(unfolding: storage.next)
    build(Continuation(storage: storage))
  }

  /// Constructs an asynchronous stream from a given element-producing
  /// closure, with an optional closure to handle cancellation.
  ///
  /// - Parameters:
  ///   - produce: A closure that asynchronously produces elements for the
  ///     stream.
  ///   - onCancel: A closure to execute when cancelling the stream's task.
  ///
  /// Use this convenience initializer when you have an asychronous function
  /// that can produce elements for the stream, and don't want to invoke
  /// a continuation manually. This initializer "unfolds" your closure into
  /// a full-blown asynchronous stream. The created stream handles conformance
  /// to the `AsyncSequence` protocol automatically, including termination
  /// (whether by cancellation or by returning `nil` from the closure to finish
  /// iteration).
  ///
  /// The following example shows an `AsyncStream` created with this
  /// initializer that produces random numbers on a one-second interval. This
  /// example uses Swift's multiple trailing closure syntax, which omits
  /// the `unfolding` parameter label.
  ///
  ///     let stream = AsyncStream<Int> {
  ///             await Task.sleep(1 * 1_000_000_000)
  ///             return Int.random(in: 1...10)
  ///         }
  ///         onCancel: { @Sendable () in print ("Canceled.") }
  ///     )
  ///
  ///     // call point:
  ///     for await random in stream {
  ///         print ("\(random)")
  ///     }
  ///
  ///
  public init(
    unfolding produce: @escaping () async -> Element?, 
    onCancel: (@Sendable () -> Void)? = nil
  ) {
    let storage: _AsyncStreamCriticalStorage<Optional<() async -> Element?>>
      = .create(produce)
    self.produce = {
      return await Task.withCancellationHandler {
        storage.value = nil
        onCancel?()
      } operation: {
        guard let result = await storage.value?() else {
          storage.value = nil
          return nil
        }
        return result
      }
    }
  }
}

@available(SwiftStdlib 5.5, *)
extension AsyncStream: AsyncSequence {
  /// The asynchronous iterator for iterating an asynchronous stream.
  ///
  /// This type specifically doesn't conform to `Sendable`. Do not use it from multiple
  /// concurrent contexts. It is a programmer error to invoke `next()` from a
  /// concurrent context that contends with another such call, and this will
  /// result in a call to `fatalError()`.
  public struct Iterator: AsyncIteratorProtocol {
    let produce: () async -> Element?

    /// The next value from the asynchronous stream.
    ///
    /// When `next()` returns `nil`, this signifies the end of the
    /// `AsyncStream`.
    ///
    /// It is a programmer error to invoke `next()` from a
    /// concurrent context that contends with another such call, and this will
    /// result in a call to `fatalError()`.
    ///
    /// If you cancel the task this iterator is running in while `next()` is
    /// awaiting a value, the `AsyncStream` terminates. In this case, `next()`
    /// might return `nil` immediately, or might return `nil` on subsequent calls.
    public mutating func next() async -> Element? {
      await produce()
    }
  }

  /// Creates the asynchronous iterator that produces elements of this
  /// asynchronous sequence.
  public func makeAsyncIterator() -> Iterator {
    return Iterator(produce: produce)
  }
}

@available(SwiftStdlib 5.5, *)
extension AsyncStream.Continuation {
  /// Resume the task awaiting the next iteration point by having it return
  /// nomally from its suspension point with a given result's success value.
  ///
  /// - Parameter result: A result to yield from the continuation.
  /// - Returns: A `YieldResult` indicating the success or failure of the
  ///   yield operation.
  ///
  /// If nothing is awaiting the next value, the method attempts to buffer the
  /// result's element.
  ///
  /// If you call this method repeatedly, each call returns immediately, without
  /// blocking for any awaiting consumption from the iteration.
  @discardableResult
  public func yield(
    with result: Result<Element, Never>
  ) -> YieldResult {
    switch result {
      case .success(let val):
        return storage.yield(val)
    }
  }

  /// Resume the task awaiting the next iteration point by having it return
  /// nomally from its suspension point.
  ///
  /// - Returns: A `YieldResult` indicating the success or failure of the
  ///   yield operation.
  ///
  /// Use this method with `AsyncStream` instances whose `Element` type is
  /// `Void`. In this case, the `yield()` call simply unblocks the awaiting
  /// iteration; there is no value to return.
  ///
  /// If you call this method repeatedly, each call returns immediately, without
  /// blocking for any awaiting consumption from the iteration.
  @discardableResult
  public func yield() -> YieldResult where Element == Void {
    return storage.yield(())
  }
}
