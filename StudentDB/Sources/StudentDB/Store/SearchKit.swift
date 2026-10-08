import Foundation

// MARK: - 帮助函数（跨平台）
//
// 从 Views/Shared.swift 移入：Models.swift 的 StudentQuery 依赖 SearchKit，
// 而 Views/Shared.swift 其余符号（FileIconView / ResizableSheetEnabler）依赖
// AppKit，不能进 iOS 目标。实现与原文件逐字一致，macOS 行为不变。

enum SearchKit {
    /// 学生的全字段搜索文本（含监护人、自定义字段值；跳过被软删除的内置字段）
    static func searchableText(of student: Student, fields: [CustomField],
                               deletedBuiltin: Set<String> = []) -> String {
        var parts: [String] = []
        if !deletedBuiltin.contains("name") { parts.append(student.name) }
        if !deletedBuiltin.contains("studentNumber") { parts.append(student.studentNumber) }
        if !deletedBuiltin.contains("phone") { parts.append(student.phone) }
        if !deletedBuiltin.contains("boardingAddress") { parts.append(student.boardingAddress) }
        if !deletedBuiltin.contains("policeStation") { parts.append(student.policeStation) }
        parts += student.guardians.map { "\($0.name) \($0.relation) \($0.phone)" }
        for field in fields {
            if let value = student.customValues[field.id.uuidString] {
                parts.append(value.displayText)
            }
        }
        return parts.joined(separator: "\n")
    }
}
