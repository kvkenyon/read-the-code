import Foundation
import XCTest
@testable import RTCStore

final class StoreTests: XCTestCase {
    func testBlobStoreIsContentAddressedAndReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root)
        let bytes = Data("immutable".utf8)
        let digest = try blobs.put(bytes)
        XCTAssertEqual(try blobs.put(bytes), digest)
        XCTAssertEqual(try blobs.get(digest), bytes)
    }
}
