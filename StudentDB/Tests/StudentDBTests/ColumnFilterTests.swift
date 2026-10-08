import XCTest
@testable import StudentDB

/// Excel 式列筛选：模型编解码 + 过滤逻辑 + 视图持久化
final class ColumnFilterTests: XCTestCase {

    // MARK: 模型

    func testColumnFilterCodableRoundtrip() throws {
        var filter = ColumnFilter()
        filter.searchText = "张"
        filter.selectedValues = ["一班", "二班"]
        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(ColumnFilter.self, from: data)
        XCTAssertEqual(decoded, filter)
    }

    func testColumnFilterNilSelectionCodableRoundtrip() throws {
        var filter = ColumnFilter()
        filter.searchText = ""
        filter.selectedValues = nil
        let data = try JSONEncoder().encode(filter)
        XCTAssertEqual(try JSONDecoder().decode(ColumnFilter.self, from: data), filter)
        XCTAssertFalse(filter.isActive)
    }

    func testIsActive() {
        var filter = ColumnFilter()
        XCTAssertFalse(filter.isActive)
        filter.searchText = "x"
        XCTAssertTrue(filter.isActive)
        filter.searchText = ""
        filter.selectedValues = []
        XCTAssertTrue(filter.isActive, "空集合 = 全部排除，也算激活")
    }

    // MARK: 旧项目文件兼容

    func testListViewLegacyDecodeWithoutColumnFilters() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"旧视图","keyword":""}
        """
        let view = try JSONDecoder().decode(ListView.self, from: Data(json.utf8))
        XCTAssertEqual(view.columnFilters, [:])
    }

    // MARK: 过滤逻辑

    /// 列与学生数据共用同一个字段 UUID
    private let classFieldID = UUID()

    private func makeColumns() -> [StudentColumnSpec] {
        var classField = CustomField(name: "班级", type: .text)
        classField.id = classFieldID
        return [
            StudentColumnSpec.builtins(order: [], deleted: []).first { $0.field == .name }!,
            StudentColumnSpec(id: classField.id.uuidString, title: classField.name,
                              field: nil, customField: classField)
        ]
    }

    private func makeStudents() -> [Student] {
        var s1 = Student(); s1.name = "张三"
        var s2 = Student(); s2.name = "李四"
        var s3 = Student(); s3.name = "张伟"
        s3.customValues[classFieldID.uuidString] = .text("三班")
        return [s1, s2, s3]
    }

    func testApplyTextFilterMatchesName() {
        let columns = makeColumns()
        let nameSpec = columns[0]
        var filter = ColumnFilter()
        filter.searchText = "张"
        let result = StudentQuery.applyColumnFilters(makeStudents(), columns: columns,
                                                     filters: [nameSpec.id: filter])
        XCTAssertEqual(result.map { $0.name }, ["张三", "张伟"])
    }

    func testApplyCustomFieldTextFilter() {
        let columns = makeColumns()
        let classSpec = columns[1]
        var filter = ColumnFilter()
        filter.searchText = "三班"
        let result = StudentQuery.applyColumnFilters(makeStudents(), columns: columns,
                                                     filters: [classSpec.id: filter])
        XCTAssertEqual(result.map { $0.name }, ["张伟"])
    }

    func testApplyValueWhitelist() {
        let columns = makeColumns()
        let nameSpec = columns[0]
        var filter = ColumnFilter()
        filter.selectedValues = ["李四"]
        let result = StudentQuery.applyColumnFilters(makeStudents(), columns: columns,
                                                     filters: [nameSpec.id: filter])
        XCTAssertEqual(result.map { $0.name }, ["李四"])
    }

    func testApplyEmptySelectionExcludesAll() {
        let columns = makeColumns()
        let nameSpec = columns[0]
        var filter = ColumnFilter()
        filter.selectedValues = []
        let result = StudentQuery.applyColumnFilters(makeStudents(), columns: columns,
                                                     filters: [nameSpec.id: filter])
        XCTAssertTrue(result.isEmpty)
    }

    func testApplyUnknownColumnIgnored() {
        var filter = ColumnFilter()
        filter.searchText = "张"
        let result = StudentQuery.applyColumnFilters(makeStudents(), columns: makeColumns(),
                                                     filters: ["不存在的列": filter])
        XCTAssertEqual(result.count, 3, "列不存在时该筛选失效")
    }

    func testApplyMultipleFiltersIntersect() {
        let columns = makeColumns()
        var nameFilter = ColumnFilter()
        nameFilter.searchText = "张"
        var classFilter = ColumnFilter()
        classFilter.searchText = "三班"
        let result = StudentQuery.applyColumnFilters(makeStudents(), columns: columns,
                                                     filters: [columns[0].id: nameFilter,
                                                               columns[1].id: classFilter])
        XCTAssertEqual(result.map { $0.name }, ["张伟"])
    }

    func testDistinctValues() {
        let columns = makeColumns()
        let values = StudentQuery.distinctValues(column: columns[0], in: makeStudents())
        XCTAssertEqual(Set(values), Set(["张三", "李四", "张伟"]))
        XCTAssertEqual(values.count, 3)
    }

    // MARK: Store 持久化

    private var tempDir: String {
        let dir = NSTemporaryDirectory() + "StudentDBTests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    func testStoreSetAndClearColumnFilter() throws {
        let url = URL(fileURLWithPath: tempDir).appendingPathComponent("筛选测试库.studentproj")
        let store = ProjectStore()
        try store.createProject(at: url, name: "筛选测试库")
        let spec = StudentColumnSpec.builtins(order: [], deleted: []).first { $0.field == .name }!

        var filter = ColumnFilter()
        filter.searchText = "张"
        store.setColumnFilter(columnID: spec.id, filter: filter)
        XCTAssertEqual(store.currentView.columnFilters[spec.id]?.searchText, "张")

        store.setColumnFilter(columnID: spec.id, filter: nil)
        XCTAssertNil(store.currentView.columnFilters[spec.id])

        filter.selectedValues = ["张三"]
        store.setColumnFilter(columnID: spec.id, filter: filter)
        XCTAssertEqual(store.currentView.columnFilters.count, 1)

        store.clearColumnFilters()
        XCTAssertTrue(store.currentView.columnFilters.isEmpty)
    }
}
