import XCTest
@testable import StudentDB

/// 一次性：把用户项目里身份证/电话类字段升级为专用类型（值原样保留，显示层负责校验标红）
@MainActor
final class TempUpgradeFields: XCTestCase {
    func testUpgrade() throws {
        let url = URL(fileURLWithPath: "/tmp/studentdb-debug/我的学生库.studentproj", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("样本项目不存在，跳过一次性升级")
        }
        let store = ProjectStore()
        try store.openProject(at: url)

        let rules: [(String, FieldType)] = [
            ("身份证", .idCard), ("身份证号", .idCard),
            ("联系电话", .phone), ("责任人手机", .phone), ("上报人手机", .phone),
            ("家长手机1", .phone), ("家长手机2", .phone),
            ("监护人联系方式", .phone), ("联系电话1", .phone), ("联系电话2", .phone),
        ]
        var changed = 0
        for table in store.data.tables {
            for field in table.fields where field.type == .text {
                if let newType = rules.first(where: { $0.0 == field.name })?.1 {
                    store.changeTableFieldType(tableID: table.id, fieldID: field.id, to: newType)
                    changed += 1
                    print("[Upgrade] \(table.name) / \(field.name) → \(newType.displayName)")
                }
            }
        }
        // 学生表自定义字段同样升级
        for field in store.data.fieldDefinitions where field.type == .text {
            if let newType = rules.first(where: { $0.0 == field.name })?.1 {
                store.changeFieldType(fieldID: field.id, to: newType)
                changed += 1
                print("[Upgrade] 学生表 / \(field.name) → \(newType.displayName)")
            }
        }
        store.flushSave()
        print("[Upgrade] 共升级 \(changed) 个字段")
    }
}
