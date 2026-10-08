import Foundation

// MARK: - 字段类型切换的值转换

/// 把旧值转换到新字段类型（nil = 该值无法转换，清除）。
/// nameOf：学生姓名查询（关联学生→文本用）；matchIDs：按姓名/学号匹配学生（文本→关联学生用）。
func convertCustomValue(_ old: CustomValue, to newType: FieldType,
                        nameOf: (UUID) -> String?,
                        matchIDs: (String) -> [UUID]) -> CustomValue? {
    switch newType {
    case .text, .address, .phone, .idCard:
        if case .link(let ids) = old {
            return .text(ids.compactMap { nameOf($0) }.joined(separator: "、"))
        }
        return .text(old.displayText)
    case .number:
        switch old {
        case .number:
            return old
        case .text(let s):
            return Double(s.replacingOccurrences(of: ",", with: "")).map { .number($0) }
        default:
            return nil
        }
    case .date, .dateTime:
        switch old {
        case .date:
            return old
        case .text(let s):
            return TableImporter.parseDateText(s).map { .date($0) }
        default:
            return nil
        }
    case .boolean:
        switch old {
        case .boolean:
            return old
        case .text(let s):
            return TableImporter.parseBoolText(s).map { .boolean($0) }
        default:
            return nil
        }
    case .choice, .multiChoice:
        if case .link(let ids) = old {
            let text = ids.compactMap { nameOf($0) }.joined(separator: "、")
            return text.isEmpty ? nil : .text(text)
        }
        if case .text(let s) = old {
            return s.isEmpty ? nil : old
        }
        return .text(old.displayText)
    case .linkStudents:
        if case .link = old {
            return old
        }
        if case .text(let s) = old, !s.isEmpty {
            let ids = matchIDs(s)
            return ids.isEmpty ? nil : .link(ids)
        }
        return nil
    case .attachment:
        // 附件类型单元格不存值（文件按 行/字段 目录管理）
        return nil
    }
}

// MARK: - 通用数据表（记录表 / 自定义表）
//
// ProjectStore 的多表扩展：表的增删改、行增删改、表内字段管理、行/字段附件。
// 学生表保持强类型（Student），不在 tables 里；删除学生时各表关联字段同步清理。

extension ProjectStore {

    // MARK: 表管理

    var currentTable: DBTable? {
        data.table(id: data.currentTableID)
    }

    /// 切换当前数据表（nil = 学生表）；筛选是会话内状态，切表统一清空（回来显示全部）
    func switchTable(id: UUID?) {
        mutateData { $0.currentTableID = id }
        resetViewFilters()
        scheduleSave()
    }

    func updateTable(_ table: DBTable) {
        mutateData { data in
            guard let idx = data.tables.firstIndex(where: { $0.id == table.id }) else { return }
            data.tables[idx] = table
        }
        scheduleSave()
    }

    @discardableResult
    func addTable(name: String, kind: TableKind, fields: [CustomField]) -> DBTable {
        var table = DBTable(name: name, kind: kind, fields: fields)
        table.createdAt = Date()
        table.fieldOrder = fields.map { $0.id }
        table.name = name
        mutateData { data in
            data.tables.append(table)
            data.currentTableID = table.id
        }
        scheduleSave()
        return table
    }

    func renameTable(id: UUID, name: String) {
        guard !name.isEmpty else { return }
        mutateData { data in
            guard let idx = data.tables.firstIndex(where: { $0.id == id }) else { return }
            data.tables[idx].name = name
        }
        scheduleSave()
    }

    /// 删除表：附件目录移入废纸篓；删的是当前表则切回学生表
    func deleteTable(id: UUID) {
        guard data.tables.contains(where: { $0.id == id }) else { return }
        if let root = attachmentsRoot {
            trashItem(at: root.appendingPathComponent(id.uuidString, isDirectory: true))
        }
        mutateData { data in
            if let idx = data.tables.firstIndex(where: { $0.id == id }) {
                data.tables.remove(at: idx)
            }
            if data.currentTableID == id {
                data.currentTableID = nil
            }
        }
        scheduleSave()
    }

    // MARK: 表内字段管理

    func tableField(tableID: UUID, fieldID: UUID) -> CustomField? {
        data.table(id: tableID)?.fields.first { $0.id == fieldID }
    }

    @discardableResult
    func addTableField(tableID: UUID, name: String, type: FieldType) -> CustomField? {
        guard !name.isEmpty else { return nil }
        var field = CustomField(name: name, type: type)
        field.createdAt = Date()
        
        mutateData { data in
            guard let idx = data.tables.firstIndex(where: { $0.id == tableID }) else { return }
            data.tables[idx].fields.append(field)
            data.tables[idx].fieldOrder.append(field.id)
        }
        scheduleSave()
        return field
    }

    func updateTableField(tableID: UUID, field: CustomField) {
        mutateData { data in
            guard let idx = data.tables.firstIndex(where: { $0.id == tableID }) else { return }
            guard let fIdx = data.tables[idx].fields.firstIndex(where: { $0.id == field.id }) else { return }
            data.tables[idx].fields[fIdx] = field
        }
        scheduleSave()
    }

    /// 变更表内字段类型：行值同步转换到新类型（转换失败的清除；单选/多选把现有取值并入选项；
    /// 文本转关联学生按姓名/学号匹配；关联学生转文本导出为姓名）
    func changeTableFieldType(tableID: UUID, fieldID: UUID, to newType: FieldType) {
        mutateData { data in
            guard let tIdx = data.tables.firstIndex(where: { $0.id == tableID }),
                  let fIdx = data.tables[tIdx].fields.firstIndex(where: { $0.id == fieldID }) else { return }
            guard !data.tables[tIdx].fields[fIdx].type.sameKind(as: newType) else { return }
            data.tables[tIdx].fields[fIdx].type = newType

            let nameOf: (UUID) -> String? = { id in
                data.students.first(where: { $0.id == id })?.name
            }
            let matchIDs: (String) -> [UUID] = { text in
                var ids: [UUID] = []
                for part in TableImporter.splitMulti(text) {
                    let lower = part.lowercased()
                    if let s = data.students.first(where: {
                        $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lower
                            || $0.studentNumber.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lower
                    }), !ids.contains(s.id) {
                        ids.append(s.id)
                    }
                }
                return ids
            }

            let key = fieldID.uuidString
            var distinctTexts: [String] = []
            for rIdx in data.tables[tIdx].rows.indices {
                guard let old = data.tables[tIdx].rows[rIdx].values.removeValue(forKey: key) else { continue }
                let converted = convertCustomValue(old, to: newType, nameOf: nameOf, matchIDs: matchIDs)
                if let converted {
                    data.tables[tIdx].rows[rIdx].values[key] = converted
                    if case .text(let t) = converted, !t.isEmpty { distinctTexts.append(t) }
                }
                data.tables[tIdx].rows[rIdx].updatedAt = Date()
            }

            // 单选/多选：现有取值并入选项（多选拆顿号）
            switch newType {
            case .choice(let options):
                var merged = options
                for t in distinctTexts where !t.isEmpty && !merged.contains(t) { merged.append(t) }
                data.tables[tIdx].fields[fIdx].type = .choice(options: merged)
            case .multiChoice(let options):
                var merged = options
                for t in distinctTexts {
                    for part in TableImporter.splitMulti(t) where !merged.contains(part) { merged.append(part) }
                }
                data.tables[tIdx].fields[fIdx].type = .multiChoice(options: merged)
            default:
                break
            }
        }
        scheduleSave()
    }

    /// 删除表字段（真删除：行值一并清除），引用它的视图配置同步清理
    func deleteTableField(tableID: UUID, fieldID: UUID) {
        mutateData { data in
            guard let idx = data.tables.firstIndex(where: { $0.id == tableID }) else { return }
            let key = fieldID.uuidString
            data.tables[idx].fields.removeAll { $0.id == fieldID }
            data.tables[idx].fieldOrder.removeAll { $0 == fieldID }
            data.tables[idx].columnLayout.removeAll { $0 == key }
            data.tables[idx].views = data.tables[idx].views.map { view in
                var v = view
                v.hiddenColumnIDs.remove(key)
                v.columnFilters.removeValue(forKey: key)
                if v.sortFieldID == fieldID { v.sortFieldID = nil }
                return v
            }
            for r in data.tables[idx].rows.indices {
                data.tables[idx].rows[r].values.removeValue(forKey: key)
                data.tables[idx].rows[r].updatedAt = Date()
            }
        }
        scheduleSave()
    }

    /// 表头菜单移动字段
    @MainActor
    func moveTableFieldByMenu(tableID: UUID, fieldID: UUID, offset: Int) {
        moveTableField(tableID: tableID, fieldID: fieldID, offset: offset)
    }

    /// 移动表内字段位置（offset: -1 上移 / +1 下移）
    func moveTableField(tableID: UUID, fieldID: UUID, offset: Int) {
        mutateData { data in
            guard let idx = data.tables.firstIndex(where: { $0.id == tableID }) else { return }
            guard let oIdx = data.tables[idx].fieldOrder.firstIndex(of: fieldID) else { return }
            let target = oIdx + offset
            guard data.tables[idx].fieldOrder.indices.contains(target) else { return }
            data.tables[idx].fieldOrder.swapAt(oIdx, target)
        }
        scheduleSave()
    }

    /// 表内下拉/多选字段选项自动追加（导入遇到新词条时）
    func appendTableChoiceOptions(tableID: UUID, fieldID: UUID, options: [String]) {
        mutateData { data in
            guard let idx = data.tables.firstIndex(where: { $0.id == tableID }) else { return }
            guard let fIdx = data.tables[idx].fields.firstIndex(where: { $0.id == fieldID }) else { return }
            var field = data.tables[idx].fields[fIdx]
            var current: [String]
            switch field.type {
            case .choice(let list): current = list
            case .multiChoice(let list): current = list
            default: return
            }
            var added = false
            for option in options where !option.isEmpty && !current.contains(option) {
                current.append(option)
                added = true
            }
            guard added else { return }
            switch field.type {
            case .choice: field.type = .choice(options: current)
            case .multiChoice: field.type = .multiChoice(options: current)
            default: return
            }
            data.tables[idx].fields[fIdx] = field
        }
        scheduleSave()
    }

    /// 记忆通用表列宽（拖拽/自适应后保存）
    func setTableColumnWidth(tableID: UUID, columnID: String, width: CGFloat) {
        mutateData { data in
            guard let idx = data.tables.firstIndex(where: { $0.id == tableID }) else { return }
            data.tables[idx].columnWidths[columnID] = width
        }
        scheduleSave()
    }

    /// 学生表列宽记忆
    func setStudentColumnWidth(columnID: String, width: CGFloat) {
        mutateData { $0.columnWidths[columnID] = width }
        scheduleSave()
    }

    /// 统一列布局（表格拖列 / 详情页拖行共用）
    func setTableRowLayout(tableID: UUID, _ ids: [String]) {
        mutateData { data in
            guard let idx = data.tables.firstIndex(where: { $0.id == tableID }) else { return }
            data.tables[idx].columnLayout = ids
        }
        scheduleSave()
    }

    // MARK: 行（增删改）

    @discardableResult
    func addRow(tableID: UUID, values: [String: CustomValue] = [:]) -> DBRow? {
        guard data.table(id: tableID) != nil else { return nil }
        let row = DBRow(values: values)
        mutateData { data in
            guard let idx = data.tables.firstIndex(where: { $0.id == tableID }) else { return }
            data.tables[idx].rows.append(row)
        }
        scheduleSave()
        return row
    }

    func updateRow(tableID: UUID, row: DBRow) {
        var updated = row
        updated.updatedAt = Date()
        mutateData { data in
            guard let idx = data.tables.firstIndex(where: { $0.id == tableID }) else { return }
            guard let rIdx = data.tables[idx].rows.firstIndex(where: { $0.id == row.id }) else { return }
            data.tables[idx].rows[rIdx] = updated
        }
        scheduleSave()
    }

    /// 批量删除行（附件目录移入废纸篓）
    func deleteRows(tableID: UUID, ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for rowID in ids {
            if let dir = rowFilesDirectory(tableID: tableID, rowID: rowID) {
                trashItem(at: dir)
            }
        }
        mutateData { data in
            guard let idx = data.tables.firstIndex(where: { $0.id == tableID }) else { return }
            data.tables[idx].rows.removeAll { ids.contains($0.id) }
        }
        scheduleSave()
    }

    /// 学生被删除时，从所有表的关联字段里移除该学生（保持引用一致性）
    func removeStudentLinks(studentID: UUID) {
        var changed = false
        mutateData { data in
            // 学分记录的引用清理在同一事务内完成（防悬挂 UUID，见 ProjectStoreCredit）
            if Self.removeStudentCreditLinks(studentID: studentID, in: &data) {
                changed = true
            }
            for idx in data.tables.indices {
                let linkFieldIDs = data.tables[idx].fields
                    .filter { $0.type == .linkStudents }
                    .map { $0.id.uuidString }
                guard !linkFieldIDs.isEmpty else { continue }
                for r in data.tables[idx].rows.indices {
                    for key in linkFieldIDs {
                        if case .link(let ids)? = data.tables[idx].rows[r].values[key] {
                            let next = ids.filter { $0 != studentID }
                            if next != ids {
                                data.tables[idx].rows[r].values[key] = .link(next)
                                data.tables[idx].rows[r].updatedAt = Date()
                                changed = true
                            }
                        }
                    }
                }
            }
        }
        if changed { scheduleSave() }
    }

    /// 引用某学生的全部行（跨所有记录表/自定义表）
    func rowsLinking(toStudent studentID: UUID) -> [(tableID: UUID, tableName: String, row: DBRow)] {
        var result: [(UUID, String, DBRow)] = []
        for table in data.tables {
            guard let linkField = table.linkField else { continue }
            for row in table.rows {
                let ids = row.values[linkField.id.uuidString]?.linkedStudentIDs ?? []
                if ids.contains(studentID) {
                    result.append((table.id, table.name, row))
                }
            }
        }
        return result
    }

    /// 某行关联的学生 id（解析名字用）
    func studentIDsLinking(toRow tableID: UUID, rowID: UUID) -> [UUID] {
        guard let table = data.table(id: tableID),
              let linkField = table.linkField,
              let row = table.row(id: rowID) else { return [] }
        return row.values[linkField.id.uuidString]?.linkedStudentIDs ?? []
    }

    // MARK: 行/字段附件（存项目包内，随项目走）

    /// 通用表行附件根目录：attachments/<表ID>/<行ID>/
    func rowFilesDirectory(tableID: UUID, rowID: UUID) -> URL? {
        guard let root = attachmentsRoot else { return nil }
        let base = root
            .appendingPathComponent(tableID.uuidString, isDirectory: true)
            .appendingPathComponent(rowID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 附件字段文件目录：…/<行ID>/<字段ID>/
    func fieldFilesDirectory(tableID: UUID, rowID: UUID, fieldID: UUID) -> URL? {
        guard let rowDir = rowFilesDirectory(tableID: tableID, rowID: rowID) else { return nil }
        let dir = rowDir.appendingPathComponent(fieldID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 把外部文件复制进表行（fieldID 为空 → 行级附件区）。附件变化计入行的最近修改。
    @discardableResult
    func importAttachment(at sourceURL: URL, tableID: UUID, rowID: UUID, fieldID: UUID? = nil) throws -> URL {
        let dir: URL?
        if let fieldID {
            dir = fieldFilesDirectory(tableID: tableID, rowID: rowID, fieldID: fieldID)
        } else {
            dir = rowFilesDirectory(tableID: tableID, rowID: rowID)
        }
        guard let destDir = dir else {
            throw ProjectError.cannotOpen("项目未打开。")
        }
        let dest = try copyFileToDirectory(at: sourceURL, directory: destDir)
        mutateData { data in
            if let idx = data.tables.firstIndex(where: { $0.id == tableID }),
               let rIdx = data.tables[idx].rows.firstIndex(where: { $0.id == rowID }) {
                data.tables[idx].rows[rIdx].updatedAt = Date()
            }
        }
        scheduleSave()
        return dest
    }

    /// 行附件数量（轻量，供列表展示）
    func nameRowFileCount(tableID: UUID, rowID: UUID) -> Int {
        guard let dir = rowFilesDirectory(tableID: tableID, rowID: rowID) else { return 0 }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        return names.filter { !$0.hasPrefix(".") }.count
    }

    func attachmentFileURLs(tableID: UUID, rowID: UUID, fieldID: UUID? = nil) -> [URL] {
        if let fieldID {
            return filesIn(directory: fieldFilesDirectory(tableID: tableID, rowID: rowID, fieldID: fieldID))
        }
        return filesIn(directory: rowFilesDirectory(tableID: tableID, rowID: rowID))
    }

    // MARK: - 记录迁移（旧项目一次性）

    /// 旧版 Student.records → 每类记录一张 `.record` 表；附件目录随迁。
    /// 由 openProject 在解码成功后调用，recordMigrationDone 标记防止重复迁移。
    /// 旧表创建时间回填：无记录的表用项目更新时间近似（一次性，随保存写回）
    private func backfillTableDates() {
        var changed = false
        mutateData { data in
            for idx in data.tables.indices where data.tables[idx].createdAt == nil {
                data.tables[idx].createdAt = data.updatedAt
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    @MainActor
    func migrateRecordsIfNeeded() {
        backfillTableDates()
        guard !data.recordMigrationDone else { return }

        // 没有旧数据（新项目 / 空项目）：直接打标记，保证 tables 至少有默认记录表
        let hasLegacyRecords = data.students.contains { !$0.records.isEmpty }
        guard hasLegacyRecords else {
            if data.tables.isEmpty {
                mutateData { data in
                    data.tables = DBTable.defaultRecordTables()
                }
            }
            mutateData { $0.recordMigrationDone = true }
            scheduleSave()
            return
        }

        // 强制备份后再动数据
        try? backupNow()

        // 类型清单 = recordTypes + 学生历史记录中出现过的其它类型
        var typeNames = data.recordTypes
        for s in data.students {
            for r in s.records where !typeNames.contains(r.type) {
                typeNames.append(r.type)
            }
        }
        if typeNames.isEmpty { typeNames = ProjectData.defaultRecordTypes }

        // 每个类型一张 .record 表（同名表复用），登记各表字段
        var tableInfos: [String: (id: UUID, fields: [CustomField])] = [:]
        mutateData { data in
            for name in typeNames {
                if let existing = data.tables.first(where: { $0.kind == .record && $0.name == name }) {
                    tableInfos[name] = (existing.id, existing.fields)
                } else {
                    let table = DBTable.recordTable(name: name, recordTypes: typeNames)
                    data.tables.append(table)
                    tableInfos[name] = (table.id, table.fields)
                }
            }
        }

        let fm = FileManager.default
        var migratedRows: [UUID: [DBRow]] = [:]

        for student in data.students {
            for record in student.records {
                guard let info = tableInfos[record.type] else { continue }
                var values: [String: CustomValue] = [:]
                for field in info.fields {
                    switch field.name {
                    case "日期": values[field.id.uuidString] = .date(record.date)
                    case "类型": values[field.id.uuidString] = .text(record.type)
                    case "学生": values[field.id.uuidString] = .link([student.id])
                    case "内容": values[field.id.uuidString] = .text(record.content)
                    default: break
                    }
                }
                var row = DBRow(values: values)
                row.createdAt = record.createdAt
                row.updatedAt = record.createdAt
                migratedRows[info.id, default: []].append(row)

                // 附件目录搬移：attachments/<学生>/records/<记录ID> → attachments/<表ID>/<行ID>/
                if let oldDir = recordFilesDirectory(studentID: student.id, recordID: record.id),
                   fm.fileExists(atPath: oldDir.path),
                   let destDir = rowFilesDirectory(tableID: info.id, rowID: row.id) {
                    try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    for file in (try? fm.contentsOfDirectory(atPath: oldDir.path)) ?? [] {
                        let source = oldDir.appendingPathComponent(file)
                        let dest = destDir.appendingPathComponent(file)
                        if !fm.fileExists(atPath: dest.path) {
                            try? fm.moveItem(at: source, to: dest)
                        }
                    }
                    if (try? fm.contentsOfDirectory(atPath: oldDir.path))?.isEmpty == true {
                        try? fm.removeItem(at: oldDir)
                    }
                }
            }
        }

        mutateData { data in
            for (tableID, rows) in migratedRows {
                if let idx = data.tables.firstIndex(where: { $0.id == tableID }) {
                    data.tables[idx].rows.append(contentsOf: rows)
                }
            }
            for idx in data.students.indices {
                data.students[idx].records = []
            }
            data.recordMigrationDone = true
        }
        try? saveNow()
    }
}
