import Foundation

/// 读写 .xlsx（Office Open XML）。
/// 读取：用系统 ditto 解压 + XMLParser 解析；写入：生成最小 xlsx 结构后用系统 zip 打包。无需第三方依赖。
enum XLSX {

    enum XLSXError: LocalizedError {
        case cannotRead(String)

        var errorDescription: String? {
            switch self {
            case .cannotRead(let reason): return reason
            }
        }
    }

    // MARK: - 读

    struct Sheet {
        var name: String
        var rows: [[String]]
    }

    /// 读取工作簿第一个工作表，返回每行每列的文本值
    static func readFirstSheet(from url: URL) throws -> Sheet {
        let sheets = try readAllSheets(from: url)
        guard let first = sheets.first else {
            throw XLSXError.cannotRead("文件里没有工作表。")
        }
        return first
    }

    static func readAllSheets(from url: URL) throws -> [Sheet] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("XLSXRead-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // 纯 Swift 解包（xlsx = ZIP 容器），不再依赖外部工具
        let entries: [String: Data]
        do {
            entries = try Dictionary(uniqueKeysWithValues:
                MiniZIP.extract(data: try Data(contentsOf: url)).map { ($0.path, $0.data) })
        } catch {
            throw XLSXError.cannotRead("无法解压该文件，请确认是有效的 .xlsx 文件。")
        }
        func entryData(_ relative: String) throws -> Data {
            guard let data = entries[relative] else {
                throw XLSXError.cannotRead("文件缺少 \(relative)，可能不是有效的 .xlsx。")
            }
            return data
        }

        var shared: [String] = []
        let sharedStringsURL = tmp.appendingPathComponent("xl/sharedStrings.xml")
        if let sharedData = entries["xl/sharedStrings.xml"] {
            let parser = SharedStringsParser(data: sharedData)
            parser.parse()
            shared = parser.strings
        }

        let workbookParser = WorkbookParser(data: try entryData("xl/workbook.xml"))
        workbookParser.parse()
        let relsParser = RelsParser(data: try entryData("xl/_rels/workbook.xml.rels"))
        relsParser.parse()

        var sheets: [Sheet] = []
        for (name, relationshipID) in workbookParser.sheets {
            guard let target = relsParser.targets[relationshipID] else { continue }
            var path = target
            if path.hasPrefix("/") {
                path.removeFirst()
            } else {
                path = "xl/" + path
            }
            guard let sheetData = entries[path] else { continue }
            let parser = SheetParser(data: sheetData, sharedStrings: shared)
            parser.parse()
            sheets.append(Sheet(name: name, rows: parser.rows))
        }
        guard !sheets.isEmpty else {
            throw XLSXError.cannotRead("文件里没有可读取的工作表。")
        }
        return sheets
    }

    // MARK: - 写

    enum Cell {
        case text(String)
        case number(Double)
    }

    /// 写出 .xlsx；每个工作表的第一行作为加粗表头
    static func write(sheets: [(name: String, rows: [[Cell]])], to url: URL) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("XLSXWrite-\(UUID().uuidString)")
        try fm.createDirectory(at: stage.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)
        try fm.createDirectory(at: stage.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: stage.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        let worksheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"
        var overrides = ""
        for index in 1...max(sheets.count, 1) {
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(index).xml\" ContentType=\"\(worksheetContentType)\"/>"
        }

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(overrides)</Types>
        """
        try Data(contentTypes.utf8).write(to: stage.appendingPathComponent("[Content_Types].xml"))

        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """
        try Data(rootRels.utf8).write(to: stage.appendingPathComponent("_rels/.rels"))

        var sheetTags = ""
        var sheetRels = ""
        for (index, sheet) in sheets.enumerated() {
            let id = index + 1
            sheetTags += "<sheet name=\"\(escape(sanitizeSheetName(sheet.name)))\" sheetId=\"\(id)\" r:id=\"rId\(id)\"/>"
            sheetRels += "<Relationship Id=\"rId\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(id).xml\"/>"
        }
        sheetRels += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"

        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheetTags)</sheets></workbook>
        """
        try Data(workbook.utf8).write(to: stage.appendingPathComponent("xl/workbook.xml"))

        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(sheetRels)</Relationships>
        """
        try Data(workbookRels.utf8).write(to: stage.appendingPathComponent("xl/_rels/workbook.xml.rels"))

        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>
        """
        try Data(styles.utf8).write(to: stage.appendingPathComponent("xl/styles.xml"))

        for (index, sheet) in sheets.enumerated() {
            let xml = sheetXML(rows: sheet.rows)
            try Data(xml.utf8).write(to: stage.appendingPathComponent("xl/worksheets/sheet\(index + 1).xml"))
        }

        // 纯 Swift 打包（store 方式，合法 ZIP）
        let entries: [MiniZIP.Entry] = try fileEntries(in: stage, prefix: "")
        let archive = MiniZIP.archive(entries: entries)
        try archive.write(to: url, options: [.atomic])
    }

    private static func sheetXML(rows: [[Cell]]) -> String {
        var body = ""
        for (rowIndex, row) in rows.enumerated() {
            let rowNumber = rowIndex + 1
            var cells = ""
            for (colIndex, cell) in row.enumerated() {
                let ref = "\(columnLetter(colIndex))\(rowNumber)"
                let style = rowIndex == 0 ? " s=\"1\"" : ""
                switch cell {
                case .text(let text):
                    if text.isEmpty { continue }
                    cells += "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(escape(text))</t></is></c>"
                case .number(let value):
                    if value.isNaN { continue }
                    cells += "<c r=\"\(ref)\"\(style)><v>\(value)</v></c>"
                }
            }
            body += "<row r=\"\(rowNumber)\">\(cells)</row>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(body)</sheetData></worksheet>
        """
    }

    // MARK: - 工具

    /// 递归收集目录内全部文件，转为 zip 条目（路径用 "/" 分隔）
    private static func fileEntries(in directory: URL, prefix: String) throws -> [MiniZIP.Entry] {
        let fm = FileManager.default
        var result: [MiniZIP.Entry] = []
        let items = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let relPath = prefix.isEmpty ? item.lastPathComponent : prefix + "/" + item.lastPathComponent
            if isDir {
                result += try fileEntries(in: item, prefix: relPath)
            } else {
                result.append(MiniZIP.Entry(path: relPath, data: try Data(contentsOf: item)))
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    static func columnLetter(_ index: Int) -> String {
        var n = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters
            n = n / 26 - 1
        } while n >= 0
        return letters
    }

    static func columnIndex(_ letters: String) -> Int? {
        guard !letters.isEmpty, letters.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        var result = 0
        for char in letters.uppercased() {
            result = result * 26 + (Int(char.asciiValue! - 65) + 1)
        }
        return result - 1
    }

    private static func sanitizeSheetName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/*?:[]")
        let cleaned = name.components(separatedBy: invalid).joined(separator: " ")
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 31 {
            return String(trimmed.prefix(31))
        }
        return trimmed.isEmpty ? "Sheet" : trimmed
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - XML 解析器

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var inItem = false
    private var inText = false

    init(data: Data) {
        super.init()
        parser = XMLParser(data: data)
        parser.delegate = self
    }

    private var parser: XMLParser!

    func parse() {
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "si":
            inItem = true
            current = ""
        case "t":
            if inItem { inText = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "t":
            inText = false
        case "si":
            strings.append(current)
            inItem = false
        default: break
        }
    }
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    var sheets: [(name: String, relationshipID: String)] = []
    private var parser: XMLParser!

    init(data: Data) {
        super.init()
        parser = XMLParser(data: data)
        parser.delegate = self
    }

    func parse() {
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if elementName == "sheet", let name = attributes["name"] {
            let rid = attributes["r:id"] ?? attributes["id"] ?? ""
            sheets.append((name, rid))
        }
    }
}

private final class RelsParser: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]
    private var parser: XMLParser!

    init(data: Data) {
        super.init()
        parser = XMLParser(data: data)
        parser.delegate = self
    }

    func parse() {
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if elementName == "Relationship", let id = attributes["Id"], let target = attributes["Target"] {
            targets[id] = target
        }
    }
}

/// 解析工作表网格；支持共享字符串、内联字符串、数字与布尔
private final class SheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    var rows: [[String]] = []
    private var parser: XMLParser!

    private var currentRow: [String] = []
    private var cellBuffer = ""
    private var inlineBuffer = ""
    private var cellType = ""
    private var cellColumn = -1
    private var inValue = false
    private var inInlineText = false

    init(data: Data, sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
        super.init()
        parser = XMLParser(data: data)
        parser.delegate = self
    }

    func parse() {
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "row":
            currentRow = []
        case "c":
            cellBuffer = ""
            inlineBuffer = ""
            cellType = attributes["t"] ?? ""
            if let ref = attributes["r"], let refLetters = ref.prefix(while: { $0.isLetter }).description as String?,
               let index = XLSX.columnIndex(refLetters) {
                cellColumn = index
            } else {
                cellColumn = currentRow.count
            }
        case "v":
            inValue = true
        case "is":
            break
        case "t":
            if cellType == "inlineStr" { inInlineText = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue { cellBuffer += string }
        if inInlineText { inlineBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "v":
            inValue = false
        case "t":
            inInlineText = false
        case "c":
            let value: String
            switch cellType {
            case "s":
                if let index = Int(cellBuffer.trimmingCharacters(in: .whitespacesAndNewlines)),
                   sharedStrings.indices.contains(index) {
                    value = sharedStrings[index]
                } else {
                    value = ""
                }
            case "inlineStr":
                value = inlineBuffer
            case "b":
                value = cellBuffer.trimmingCharacters(in: .whitespaces) == "1" ? "TRUE" : "FALSE"
            default:
                value = cellBuffer
            }
            while currentRow.count < cellColumn { currentRow.append("") }
            if cellColumn >= 0 {
                if currentRow.count == cellColumn {
                    currentRow.append(value)
                } else {
                    currentRow[cellColumn] = value
                }
            }
        case "row":
            rows.append(currentRow)
            currentRow = []
        default: break
        }
    }
}
