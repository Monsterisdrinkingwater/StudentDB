import XCTest
@testable import StudentDB

/// 欢迎页「最近项目」的移除（只移除记录，不删磁盘文件）
@MainActor
final class RecentProjectsTests: XCTestCase {

    func testRemoveRecentProject() {
        let defaults = UserDefaults.standard
        let original = defaults.stringArray(forKey: AppModel.recentKey)

        let a = URL(fileURLWithPath: "/tmp/项目A.studentproj")
        let b = URL(fileURLWithPath: "/tmp/项目B.studentproj")
        let c = URL(fileURLWithPath: "/tmp/项目C.studentproj")

        let model = AppModel.shared
        model.recentProjects = [a, b, c]
        defer {
            model.recentProjects = original?.map { URL(fileURLWithPath: $0) } ?? []
            if let original {
                defaults.set(original, forKey: AppModel.recentKey)
            } else {
                defaults.removeObject(forKey: AppModel.recentKey)
            }
        }

        model.removeRecentProject(b)
        XCTAssertEqual(model.recentProjects, [a, c])
        XCTAssertEqual(defaults.stringArray(forKey: AppModel.recentKey), [a.path, c.path],
                       "移除后应立即写回 UserDefaults")

        // 再移除不存在的条目不影响其余
        model.removeRecentProject(URL(fileURLWithPath: "/tmp/不存在.studentproj"))
        XCTAssertEqual(model.recentProjects, [a, c])

        // 逐个移除到空
        model.removeRecentProject(a)
        model.removeRecentProject(c)
        XCTAssertTrue(model.recentProjects.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: AppModel.recentKey) ?? ["x"], [])
    }
}
