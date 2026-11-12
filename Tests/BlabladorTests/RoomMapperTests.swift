import simd
import XCTest
@testable import BlabladorCore

final class RoomMapperTests: XCTestCase {
    func testParsesBinaryPLY() throws {
        var ply = Data("ply\nformat binary_little_endian 1.0\nelement vertex 2\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n".utf8)
        for (point, color) in [([Float(1), 2, 3], [UInt8(255), 0, 0]), ([Float(-1), -2, -3], [UInt8(0), 0, 255])] {
            for value in point { withUnsafeBytes(of: value.bitPattern.littleEndian) { ply.append(contentsOf: $0) } }
            ply.append(contentsOf: color)
        }
        let cloud = try RoomMapper.PointCloud(ply: ply)
        XCTAssertEqual(cloud.positions, [SIMD3(1, 2, 3), SIMD3(-1, -2, -3)])
        XCTAssertEqual(cloud.colors[0], SIMD3(1, 0, 0))
        let prepared = cloud.prepared(limit: 10)
        XCTAssertEqual(prepared.positions[0], SIMD3(1, -2, -3))
        XCTAssertEqual(prepared.radius, simd_length(SIMD3<Float>(1, 2, 3)), accuracy: 0.001)
        XCTAssertThrowsError(try RoomMapper.PointCloud(ply: Data("hello".utf8)))
    }

    func testCommandsAndQueue() {
        XCTAssertEqual(RoomMapper.stepCommand(session: "a", cameraHeight: 120), "step session=a camera_height_cm=120.0")
        XCTAssertTrue(RoomMapper.isValidSession(RoomMapper.newSessionName()))
        XCTAssertFalse(RoomMapper.isValidSession("a b"))
        let queue = RoomMapper.Queue(["gpu_busy": true, "waiting": 1, "waited_s": 3.4, "ahead_on_arrival": 2])
        XCTAssertTrue(queue.text.hasPrefix("The GPU is busy: 2 request(s)"))
        XCTAssertEqual(queue.waitedNote, " Waited 3 s for 2 request(s) from others.")
        XCTAssertEqual(RoomMapper.Queue(["other_sessions_active": 1]).text, "1 other person is mapping right now. Sending may take a little longer.")
    }
}
