import XCTest
@testable import StudentDB

/// 侧栏点击选择逻辑：普通=单选；⌘=切换；⇧=从锚点范围选择
final class SidebarSelectionTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()

    private func resolve(current: Set<UUID>, anchor: UUID?, clicked: UUID,
                         command: Bool = false, shift: Bool = false) -> (Set<UUID>, UUID) {
        SidebarSelection.resolve(
            current: current, anchor: anchor, clicked: clicked,
            orderedIDs: [a, b, c, d], command: command, shift: shift
        )
    }

    func testPlainClickSelectsSingleAndMovesAnchor() {
        let (sel, anchor) = resolve(current: [a, b], anchor: a, clicked: c)
        XCTAssertEqual(sel, [c])
        XCTAssertEqual(anchor, c)
    }

    func testCommandClickTogglesIn() {
        let (sel, anchor) = resolve(current: [a], anchor: a, clicked: c, command: true)
        XCTAssertEqual(sel, [a, c])
        XCTAssertEqual(anchor, c)
    }

    func testCommandClickTogglesOut() {
        let (sel, anchor) = resolve(current: [a, c], anchor: a, clicked: c, command: true)
        XCTAssertEqual(sel, [a])
        XCTAssertEqual(anchor, c)
    }

    func testShiftClickForwardSelectsRangeKeepingAnchor() {
        let (sel, anchor) = resolve(current: [a], anchor: a, clicked: c, shift: true)
        XCTAssertEqual(sel, [a, b, c])
        XCTAssertEqual(anchor, a, "⇧ 点击不移动锚点，便于连续调整范围")
    }

    func testShiftClickBackwardSelectsRange() {
        let (sel, anchor) = resolve(current: [c], anchor: c, clicked: a, shift: true)
        XCTAssertEqual(sel, [a, b, c])
        XCTAssertEqual(anchor, c)
    }

    func testShiftClickNarrowsRangeOnSecondAttempt() {
        let (_, _) = resolve(current: [a, b, c], anchor: a, clicked: d, shift: true)
        let (sel, _) = resolve(current: [a, b, c, d], anchor: a, clicked: b, shift: true)
        XCTAssertEqual(sel, [a, b])
    }

    func testShiftWithoutAnchorFallsBackToSingle() {
        let (sel, anchor) = resolve(current: [a, b], anchor: nil, clicked: d, shift: true)
        XCTAssertEqual(sel, [d])
        XCTAssertEqual(anchor, d)
    }

    func testShiftWhenAnchorMissingFromListFallsBackToSingle() {
        let gone = UUID()
        let (sel, anchor) = resolve(current: [a], anchor: gone, clicked: d, shift: true)
        XCTAssertEqual(sel, [d])
        XCTAssertEqual(anchor, d)
    }

    func testCommandAndShiftTogetherUsesRange() {
        // ⇧ 优先：⌘⇧ 点击同样做范围选择（与 Finder 一致）
        let (sel, anchor) = resolve(current: [a], anchor: a, clicked: d, command: true, shift: true)
        XCTAssertEqual(sel, [a, b, c, d])
        XCTAssertEqual(anchor, a)
    }

    func testCommandClickDoesNotDiscardShiftAnchor() {
        let (_, anchor) = resolve(current: [a], anchor: a, clicked: d, command: true)
        XCTAssertEqual(anchor, d, "⌘ 点击移动锚点")
    }
}

/// 侧栏表树（字符串键）选择：⌘ 切换 / ⇧ 范围 / 拖拽划选
final class SidebarTreeSelectionTests: XCTestCase {
    private let keys = ["students", "t1", "t2", "t3", "t4"]

    func testPlainClickSelectsSingle() {
        let r = SidebarSelection.resolveKeys(current: ["t1", "t2"], anchor: "t1",
                                             clicked: "t3", orderedKeys: keys,
                                             command: false, shift: false)
        XCTAssertEqual(r.selection, ["t3"])
        XCTAssertEqual(r.anchor, "t3")
    }

    func testCommandToggles() {
        var r = SidebarSelection.resolveKeys(current: ["students"], anchor: "students",
                                             clicked: "t2", orderedKeys: keys,
                                             command: true, shift: false)
        XCTAssertEqual(r.selection, ["students", "t2"])
        r = SidebarSelection.resolveKeys(current: r.selection, anchor: r.anchor,
                                         clicked: "t2", orderedKeys: keys,
                                         command: true, shift: false)
        XCTAssertEqual(r.selection, ["students"], "再次 ⌘ 点击应取消该表")
    }

    func testShiftRangeForwardAndBackward() {
        let forward = SidebarSelection.resolveKeys(current: ["t1"], anchor: "t1",
                                                   clicked: "t3", orderedKeys: keys,
                                                   command: false, shift: true)
        XCTAssertEqual(forward.selection, ["t1", "t2", "t3"])
        let backward = SidebarSelection.resolveKeys(current: ["t3"], anchor: "t3",
                                                    clicked: "students", orderedKeys: keys,
                                                    command: false, shift: true)
        XCTAssertEqual(backward.selection, ["students", "t1", "t2", "t3"])
    }

    func testDragRange() {
        let dragged = SidebarSelection.resolveDragRange(anchor: "t1", to: "t4",
                                                        orderedKeys: keys, additive: false,
                                                        current: [])
        XCTAssertEqual(dragged, ["t1", "t2", "t3", "t4"])
        let upward = SidebarSelection.resolveDragRange(anchor: "t4", to: "t2",
                                                       orderedKeys: keys, additive: false,
                                                       current: [])
        XCTAssertEqual(upward, ["t2", "t3", "t4"], "反向拖拽同样整段选中")
    }

    func testDragRangeAdditive() {
        let result = SidebarSelection.resolveDragRange(anchor: "t2", to: "t3",
                                                       orderedKeys: keys, additive: true,
                                                       current: ["students"])
        XCTAssertEqual(result, ["students", "t2", "t3"])
    }

    func testDragWithoutAnchorKeepsCurrent() {
        let result = SidebarSelection.resolveDragRange(anchor: nil, to: "t2",
                                                       orderedKeys: keys, additive: false,
                                                       current: ["t1"])
        XCTAssertEqual(result, ["t1"])
    }
}
