import XCTest
@testable import JustShoot

final class FinalStillWaiterRegistryTests: XCTestCase {
    func testDeliveryBeforeWaitReturnsBufferedBytesImmediately() async throws {
        let registry = FinalStillWaiterRegistry()
        let id = UUID()
        let data = Data([1, 2, 3])
        registry.deliver(id: id, data)
        let received = try await registry.wait(id: id, timeout: 1)
        XCTAssertEqual(received, data)
    }

    func testDeliveryReachesTheWaitingTask() async throws {
        let registry = FinalStillWaiterRegistry()
        let id = UUID()
        let task = Task { try await registry.wait(id: id, timeout: 2) }
        try await Task.sleep(for: .milliseconds(50))
        registry.deliver(id: id, Data([9]))
        let data = try await task.value
        XCTAssertEqual(data, Data([9]))
    }

    func testTimeoutThrowsInsteadOfHanging() async {
        let registry = FinalStillWaiterRegistry()
        do {
            _ = try await registry.wait(id: UUID(), timeout: 0.05)
            XCTFail("Expected a timeout error")
        } catch {}
    }

    func testCancellationBeforeRegistrationDoesNotWaitForTimeoutOrConsumeEarlyBytes() async throws {
        let registry = FinalStillWaiterRegistry()
        for buffered in [false, true] {
            let id = UUID()
            if buffered { registry.deliver(id: id, Data([3])) }
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await registry.wait(id: id, timeout: 0.3)
            }
            do {
                _ = try await task.value
                XCTFail("The cancelled waiter should never claim the final")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            if buffered {
                let bytes = try await registry.wait(id: id, timeout: 0.3)
                XCTAssertEqual(bytes, Data([3]))
            }
        }
    }

    func testCancellationFreesTheSlotForTheNextWait() async throws {
        let registry = FinalStillWaiterRegistry()
        let id = UUID()
        let task = Task { try await registry.wait(id: id, timeout: 5) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected a cancellation error")
        } catch {}
        registry.deliver(id: id, Data([4]))
        let data = try await registry.wait(id: id, timeout: 1)
        XCTAssertEqual(data, Data([4]))
    }

    func testDiscardDropsBufferedBytes() async {
        let registry = FinalStillWaiterRegistry()
        let id = UUID()
        registry.deliver(id: id, Data([5]))
        registry.discard(id: id)
        do {
            _ = try await registry.wait(id: id, timeout: 0.05)
            XCTFail("Discarded bytes must not surface")
        } catch {}
    }
}

@MainActor
final class DeferredFinalExpectationsTests: XCTestCase {
    func testConsumeReturnsEntryExactlyOnce() {
        let expectations = DeferredFinalExpectations()
        let id: Int64 = 42
        var forwarded: [Data] = []
        expectations.register(id, entry: .init(captureID: UUID()) { forwarded.append($0) }, lifetime: 60)

        let entry = expectations.consume(id)
        entry?.handler(Data([1]))
        XCTAssertNil(expectations.consume(id), "A second consume must not resurrect the expectation")
        XCTAssertEqual(forwarded, [Data([1])])

        expectations.register(id, entry: .init(captureID: UUID()) { forwarded.append($0) }, lifetime: 60)
        expectations.clear(id)
        XCTAssertNil(expectations.consume(id))
        XCTAssertEqual(forwarded, [Data([1])])
    }

    func testBoundedLifetimeClearsTheEntry() async throws {
        let expectations = DeferredFinalExpectations()
        expectations.register(7, entry: .init(captureID: UUID()) { _ in }, lifetime: 0.05)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(expectations.consume(7), "A delegate that never arrives must not leak its entry")
    }
}
