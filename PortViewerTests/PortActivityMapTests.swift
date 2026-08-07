import XCTest
@testable import PortViewer

final class PortActivityMapTests: XCTestCase {
    func testPortMapUsesStableBucketsAcrossFullPortRange() throws {
        let records = [0, 511, 512, 65_535].enumerated().map { offset, port in
            PortTestFixtures.record(
                processName: "process-\(offset)",
                pid: Int32(offset + 1),
                localPort: port
            )
        }
        let items = records.flatMap { ReadablePortItem.group([$0]) }

        let buckets = PortMapLayout.buckets(for: items)

        XCTAssertEqual(buckets.count, 128)
        XCTAssertEqual(buckets[0].lowerBound, 0)
        XCTAssertEqual(buckets[0].upperBound, 511)
        XCTAssertEqual(buckets[0].ports, [0, 511])
        XCTAssertEqual(buckets[1].ports, [512])
        XCTAssertEqual(buckets[127].lowerBound, 65_024)
        XCTAssertEqual(buckets[127].upperBound, 65_535)
        XCTAssertEqual(buckets[127].ports, [65_535])
    }

    func testMultiPortActivityAppearsOnceInEveryTouchedBucket() throws {
        let records = [
            PortTestFixtures.record(fileDescriptor: "4", localPort: 3_000),
            PortTestFixtures.record(fileDescriptor: "5", localPort: 8_080)
        ]
        let item = try XCTUnwrap(ReadablePortItem.group(records).first)

        let buckets = PortMapLayout.buckets(for: [item])
        let firstIndex = try XCTUnwrap(PortMapLayout.bucketIndex(for: 3_000))
        let secondIndex = try XCTUnwrap(PortMapLayout.bucketIndex(for: 8_080))

        XCTAssertEqual(buckets[firstIndex].items.map(\.id), [item.id])
        XCTAssertEqual(buckets[secondIndex].items.map(\.id), [item.id])
        XCTAssertEqual(buckets.flatMap(\.items).count, 2)
    }

    func testInvalidPortsAreNotAssignedToMap() {
        XCTAssertNil(PortMapLayout.bucketIndex(for: -1))
        XCTAssertNil(PortMapLayout.bucketIndex(for: 65_536))
    }
}
