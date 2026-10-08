import Foundation
import SQLite3

/// Swift 的 SQLite3 模块没暴露 SQLITE_TRANSIENT 宏，手动定义（(-1) 转 destructor 指针）
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 把整个项目导出为一个 SQLite 数据库文件（.sqlite）：
/// 学生总表 + 每张记录表/自定义表各成一张表，可在任何数据库工具中打开查询。
/// 类型映射：文本/单选/多选/地址 → TEXT，数字 → REAL，是/否 → INTEGER(0/1)，
/// 日期/日期时间 → ISO 文本（yyyy-MM-dd[ HH:mm:ss]），关联学生 → 姓名顿号文本，附件 → 文件名逗号文本。
@MainActor
enum SQLiteExporter {

    enum ExportError: LocalizedError {
        case openFailed(String)
        case execFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let msg): return "无法创建数据库文件：\(msg)"
            case .execFailed(let msg): return "写入数据库失败：\(msg)"
            }
        }
    }

    // MARK: - 入口

    static func export(data: ProjectData, to url: URL) throws {
        try FileManager.default.removeItemIfExists(at: url)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            sqlite3_close(handle)
            throw ExportError.openFailed(msg)
        }
        defer { sqlite3_close(db) }

        try exec(db, "PRAGMA journal_mode = DELETE")   // 不留 -wal/-shm 附属文件
        try exec(db, "BEGIN")

        let nameOf: (UUID) -> String = { id in
            data.students.first { $0.id == id }?.name ?? "（未知学生）"
        }

        try writeStudentTable(db, data: data)
        for table in data.tables {
            try writeGenericTable(db, table: table, nameOf: nameOf)
        }
        try exec(db, "COMMIT")
    }

    // MARK: - 学生总表

    private static func writeStudentTable(_ db: OpaquePointer, data: ProjectData) throws {
        var columns: [(name: String, decl: String)] = [
            ("姓名", "TEXT NOT NULL"),
            ("学号", "TEXT"),
            ("是否住宿", "INTEGER"),
            ("联系电话", "TEXT"),
            ("住宿地址", "TEXT"),
            ("对应派出所", "TEXT"),
        ]
        for slot in 1...4 {
            columns.append(("监护人\(slot)姓名", "TEXT"))
            columns.append(("监护人\(slot)关系", "TEXT"))
            columns.append(("监护人\(slot)电话", "TEXT"))
        }
        let used = NSMutableSet()
        for field in data.orderedFields {
            let unique = uniqueName(field.name, used: used)
            columns.append((unique, sqlDecl(for: field.type)))
        }
        columns.append(("建档时间", "TEXT"))
        columns.append(("最近修改", "TEXT"))

        try exec(db, "CREATE TABLE \"学生总表\" (\(columns.map { "\"\($0.name)\" \($0.decl)" }.joined(separator: ", ")))")

        let stmt = try prepareInsert(db, table: "学生总表", columnCount: columns.count)
        defer { sqlite3_finalize(stmt) }
        let iso = ISO8601DateFormatter()

        for student in data.students.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            var values: [SQLValue] = [
                .text(student.name),
                .text(student.studentNumber),
                .integer(student.isBoarding ? 1 : 0),
                .text(student.phone),
                .text(student.boardingAddress),
                .text(student.policeStation),
            ]
            for slot in 1...4 {
                let g = slot <= student.guardians.count ? student.guardians[slot - 1] : nil
                values.append(.text(g?.name ?? ""))
                values.append(.text(g?.relation ?? ""))
                values.append(.text(g?.phone ?? ""))
            }
            for field in data.orderedFields {
                values.append(sqlValue(student.customValues[field.id.uuidString], type: field.type, nameOf: { _ in "" }))
            }
            values.append(.text(iso.string(from: student.createdAt)))
            values.append(.text(iso.string(from: student.updatedAt)))

            bindAndStep(stmt, values: values)
        }
    }

    // MARK: - 记录表 / 自定义表

    private static func writeGenericTable(_ db: OpaquePointer, table: DBTable,
                                          nameOf: (UUID) -> String) throws {
        let fields = table.orderedFields
        let used = NSMutableSet()
        var columns: [(name: String, decl: String)] = fields.map {
            (uniqueName($0.name, used: used), sqlDecl(for: $0.type))
        }
        columns.append(("行创建时间", "TEXT"))
        columns.append(("行最近修改", "TEXT"))

        try exec(db, "CREATE TABLE \(quoted(table.name)) (\(columns.map { "\(quoted($0.name)) \($0.decl)" }.joined(separator: ", ")))")

        let stmt = try prepareInsert(db, table: table.name, columnCount: columns.count)
        defer { sqlite3_finalize(stmt) }
        let iso = ISO8601DateFormatter()

        for row in table.rows {
            var values: [SQLValue] = fields.map { field in
                sqlValue(row.values[field.id.uuidString], type: field.type, nameOf: nameOf)
            }
            values.append(.text(iso.string(from: row.createdAt)))
            values.append(.text(iso.string(from: row.updatedAt)))
            bindAndStep(stmt, values: values)
        }
    }

    // MARK: - 值转换

    private static func sqlValue(_ value: CustomValue?, type: FieldType,
                                 nameOf: (UUID) -> String) -> SQLValue {
        guard let value else { return .null }
        switch value {
        case .text(let s): return .text(s)
        case .number(let n): return .real(n)
        case .boolean(let b): return .integer(b ? 1 : 0)
        case .date(let d):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = (type == .dateTime) ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
            return .text(f.string(from: d))
        case .link(let ids):
            return .text(ids.map { nameOf($0) }.joined(separator: "、"))
        }
    }

    private static func sqlDecl(for type: FieldType) -> String {
        switch type {
        case .number: return "REAL"
        case .boolean: return "INTEGER"
        default: return "TEXT"
        }
    }

    // MARK: - SQLite 基础

    private enum SQLValue {
        case null
        case text(String)
        case real(Double)
        case integer(Int)
    }

    private static func quoted(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func uniqueName(_ name: String, used: NSMutableSet) -> String {
        var candidate = name.isEmpty ? "未命名字段" : name
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(name)(\(suffix))"
            suffix += 1
        }
        used.add(candidate)
        return candidate
    }

    @discardableResult
    private static func exec(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer? {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(err)
            throw ExportError.execFailed(msg)
        }
        return nil
    }

    private static func prepareInsert(_ db: OpaquePointer, table: String, columnCount: Int) throws -> OpaquePointer {
        let placeholders = Array(repeating: "?", count: columnCount).joined(separator: ", ")
        var stmt: OpaquePointer?
        let sql = "INSERT INTO \(quoted(table)) VALUES (\(placeholders))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(stmt)
            throw ExportError.execFailed(msg)
        }
        return statement
    }

    private static func bindAndStep(_ stmt: OpaquePointer, values: [SQLValue]) {
        sqlite3_reset(stmt)
        for (idx, value) in values.enumerated() {
            let i = Int32(idx + 1)
            switch value {
            case .null: sqlite3_bind_null(stmt, i)
            case .text(let s): sqlite3_bind_text(stmt, i, s, -1, SQLITE_TRANSIENT)
            case .real(let d): sqlite3_bind_double(stmt, i, d)
            case .integer(let n): sqlite3_bind_int64(stmt, i, Int64(n))
            }
        }
        sqlite3_step(stmt)
    }
}

private extension FileManager {
    func removeItemIfExists(at url: URL) throws {
        if fileExists(atPath: url.path) {
            try removeItem(at: url)
        }
    }
}
