import XCTest
@testable import StudentDB

final class DebugDecodeTests: XCTestCase {
    func testDecodeRealFile() throws {
        let path = "/tmp/studentdb-debug/50人测试库.studentproj/students.json"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("文件不存在，跳过诊断")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let ms = try container.decode(Int64.self)
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        }
        do {
            _ = try decoder.decode(ProjectData.self, from: data)
        } catch {
            XCTFail("解码失败: \(error)")
        }
    }
}
