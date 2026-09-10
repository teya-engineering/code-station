import Foundation
import Testing
@testable import MenuBarApp

struct TerminalOutputBufferTests {
    @Test func schedulesOneFlushAndPreservesByteOrderAcrossReads() {
        let buffer = TerminalOutputBuffer(capacity: 8)
        #expect(buffer.append(Data([0x1B, 0x5B])))
        #expect(!buffer.append(Data([0x33, 0x31, 0x6D, 0xC3])))
        #expect(!buffer.append(Data([0xA9])))
        #expect(buffer.drain() == Data([0x1B, 0x5B, 0x33, 0x31, 0x6D, 0xC3, 0xA9]))
        #expect(buffer.append(Data([0x0A])))
        #expect(buffer.drain() == Data([0x0A]))
    }

    @Test func aFullBufferWaitsForTheConsumerInsteadOfRetainingMoreOutput() {
        let buffer = TerminalOutputBuffer(capacity: 4)
        defer { buffer.close() }
        #expect(buffer.append(Data([1, 2, 3, 4])))
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            #expect(buffer.append(Data([5, 6, 7, 8])))
            finished.signal()
        }
        #expect(started.wait(timeout: .now() + 5) == .success)
        #expect(finished.wait(timeout: .now() + 0.05) == .timedOut)
        #expect(buffer.drain() == Data([1, 2, 3, 4]))
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(buffer.drain() == Data([5, 6, 7, 8]))
    }

    @Test func closingATerminalReleasesAReaderWaitingForSpace() {
        let buffer = TerminalOutputBuffer(capacity: 4)
        defer { buffer.close() }
        #expect(buffer.append(Data([1, 2, 3, 4])))
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            #expect(!buffer.append(Data([5])))
            finished.signal()
        }
        #expect(started.wait(timeout: .now() + 5) == .success)
        #expect(finished.wait(timeout: .now() + 0.05) == .timedOut)
        buffer.close()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(buffer.drain().isEmpty)
        #expect(!buffer.append(Data([6])))
    }

    @Test func sustainedOutputStaysOrderedWithASlowConsumer() async {
        let buffer = TerminalOutputBuffer(capacity: 128)
        defer { buffer.close() }
        let total = 256 * 1024
        let producer = Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    for offset in stride(from: 0, to: total, by: 64) {
                        _ = buffer.append(Data((offset..<(offset + 64)).map { UInt8($0 % 251) }))
                    }
                    continuation.resume()
                }
            }
        }
        var received = Data()
        let deadline = ContinuousClock.now + .seconds(10)
        while received.count < total, ContinuousClock.now < deadline {
            let batch = buffer.drain()
            #expect(batch.count <= 128)
            received.append(batch)
            await Task.yield()
        }
        buffer.close()
        await producer.value
        #expect(received == Data((0..<total).map { UInt8($0 % 251) }))
    }
}
