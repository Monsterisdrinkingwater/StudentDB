import Foundation

// MARK: - 学分计算（规则 / 记录 / 学期 / 汇总）
//
// 数据模型与纯逻辑，不依赖 UI（面板见 Views/CreditPanelView.swift，存取见
// Store/ProjectStoreCredit.swift）。分值用 Double：负数=扣分，0.5=半分；
// 学生引用一律存 Student.id（UUID），不按姓名；总分不落库，一律按记录累计。

/// 学分规则：内置预设或用户自建的加减分项。
/// 记录只存规则 id 与套用时刻的名称/分值快照，规则改名或删除不影响历史留痕。
struct CreditRule: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String = ""
    /// 分值：负数 = 扣分，支持 0.5 半分
    var points: Double = 0
    /// 分组：扣分 / 参赛 / 获奖（CreditRule.categories）
    var category: String = CreditRule.categoryDeduct
    /// 组内显示顺序
    var sortOrder: Int = 0

    static let categoryDeduct = "扣分"
    static let categoryContest = "参赛"
    static let categoryAward = "获奖"
    static let categoryWeekly = "每周奖励"
    /// 《学生手册》五育综合素质评价各模块（加分项）
    static let categoryDeYu = "德育（手册）"
    static let categoryZhiYu = "智育（手册）"
    static let categoryTiYu = "体育（手册）"
    static let categoryMeiYu = "美育（手册）"
    static let categoryLaoYu = "劳育（手册）"
    /// 面板按键区的固定分组顺序
    static let categories = [categoryDeduct, categoryWeekly, categoryContest, categoryAward,
                             categoryDeYu, categoryZhiYu, categoryTiYu, categoryMeiYu, categoryLaoYu]

    init() {}

    /// 内置预设（固定 UUID，重复打开-保存结果稳定；惯例同 Table.recordTable 的固定字段 id）
    static let defaults: [CreditRule] = makeDefaults()

    private static func makeDefaults() -> [CreditRule] {
        func fixed(_ n: Int) -> UUID {
            UUID(uuidString: String(format: "C0FFEE00-C8ED-1700-0000-%012X", n))!
        }
        var rules: [CreditRule] = []
        func add(_ n: Int, _ name: String, _ points: Double, _ category: String, _ order: Int) {
            var rule = CreditRule()
            rule.id = fixed(n)
            rule.name = name
            rule.points = points
            rule.category = category
            rule.sortOrder = order
            rules.append(rule)
        }
        // 扣分 —— 校纪校格子项（依据《学生手册》综合素质评价表 + 学生违纪处理管理规定）
        add(1, "违反校纪校规", -2, categoryDeduct, 1)
        add(2, "劳动有问题", -1, categoryDeduct, 2)
        add(3, "劳动返工", -0.5, categoryDeduct, 3)
        // 常规抽查（手册"遵纪守法"模块，按抽查层级×色级）
        add(21, "常规抽查（系级）（橙色等级）", -2, categoryDeduct, 4)
        add(22, "常规抽查（系级）（红色等级）", -4, categoryDeduct, 5)
        add(23, "常规抽查（校级）（橙色等级）", -2, categoryDeduct, 6)
        add(24, "常规抽查（校级）（红色等级）", -4, categoryDeduct, 7)
        // 处分层级（手册"遵纪守法"模块，通报批评到留校察看）
        add(25, "处分（通报批评）", -10, categoryDeduct, 8)
        add(26, "处分（警告）", -20, categoryDeduct, 9)
        add(27, "处分（严重警告）", -30, categoryDeduct, 10)
        add(28, "处分（记过）", -40, categoryDeduct, 11)
        add(29, "处分（留校察看）", -50, categoryDeduct, 12)
        // 参赛（愿意主动参加也是加分；层级每升一级每档 +1）
        add(4, "参加校级比赛", 2, categoryContest, 1)
        add(5, "参加江阴市级比赛", 3, categoryContest, 2)
        add(6, "参加无锡市级比赛", 4, categoryContest, 3)
        add(7, "参加省级比赛", 5, categoryContest, 4)
        // 获奖（三等 / 二等 / 一等奖 = 3/4/5 起步，按层级递增）
        add(8, "校级比赛三等奖", 6, categoryAward, 1)
        add(9, "校级比赛二等奖", 9, categoryAward, 2)
        add(10, "校级比赛一等奖", 12, categoryAward, 3)
        add(11, "江阴市级比赛三等奖", 10, categoryAward, 4)
        add(12, "江阴市级比赛二等奖", 13, categoryAward, 5)
        add(13, "江阴市级比赛一等奖", 16, categoryAward, 6)
        add(14, "无锡市级比赛三等奖", 14, categoryAward, 7)
        add(15, "无锡市级比赛二等奖", 17, categoryAward, 8)
        add(16, "无锡市级比赛一等奖", 20, categoryAward, 9)
        add(17, "省级比赛三等奖", 24, categoryAward, 10)
        add(18, "省级比赛二等奖", 27, categoryAward, 11)
        add(19, "省级比赛一等奖", 30, categoryAward, 12)
        add(100, "通过民主评议", 5.0, categoryDeYu, 1)
        add(101, "参与“学习强国”学习", 5.0, categoryDeYu, 2)
        add(102, "参与爱国主义教育实践活动（班级层面）", 1.0, categoryDeYu, 3)
        add(103, "参与爱国主义教育实践活动（系级层面）", 1.5, categoryDeYu, 4)
        add(104, "参与党课、团课、讲座（班级层面）", 1.0, categoryDeYu, 5)
        add(105, "参与党课、团课、讲座（系级层面）", 2.0, categoryDeYu, 6)
        add(106, "参与党课、团课、讲座（校级层面及以上层面）", 3.0, categoryDeYu, 7)
        add(107, "青年志愿者活动（参与人）", 1.0, categoryDeYu, 8)
        add(108, "青年志愿者活动（组织者）", 1.5, categoryDeYu, 9)
        add(109, "好人好事", 2.0, categoryDeYu, 10)
        add(110, "参加德育活动及比赛（班级层面）", 1.0, categoryDeYu, 11)
        add(111, "参加德育活动及比赛（系级层面）", 2.0, categoryDeYu, 12)
        add(112, "参加德育活动及比赛（校级层面）", 2, categoryDeYu, 13)
        add(113, "参加德育活动及比赛（县级及以上层面）", 4.0, categoryDeYu, 14)
        add(114, "德育活动及比赛获奖（系级一等奖）", 8, categoryDeYu, 15)
        add(115, "德育活动及比赛获奖（系级二等奖）", 5, categoryDeYu, 16)
        add(116, "德育活动及比赛获奖（系级三等奖）", 2, categoryDeYu, 17)
        add(117, "德育活动及比赛获奖（校级一等奖）", 12, categoryDeYu, 18)
        add(118, "德育活动及比赛获奖（校级二等奖）", 9, categoryDeYu, 19)
        add(119, "德育活动及比赛获奖（校级三等奖）", 6, categoryDeYu, 20)
        add(120, "德育活动及比赛获奖（县级一等奖）", 16, categoryDeYu, 21)
        add(121, "德育活动及比赛获奖（县级二等奖）", 13, categoryDeYu, 22)
        add(122, "德育活动及比赛获奖（县级三等奖）", 10, categoryDeYu, 23)
        add(123, "德育活动及比赛获奖（市级一等奖）", 20, categoryDeYu, 24)
        add(124, "德育活动及比赛获奖（市级二等奖）", 17, categoryDeYu, 25)
        add(125, "德育活动及比赛获奖（市级三等奖）", 14, categoryDeYu, 26)
        add(126, "德育活动及比赛获奖（省级一等奖）", 30, categoryDeYu, 27)
        add(127, "德育活动及比赛获奖（省级二等奖）", 27, categoryDeYu, 28)
        add(128, "德育活动及比赛获奖（省级三等奖）", 24, categoryDeYu, 29)
        add(129, "德育活动及比赛获奖（国家级一等奖）", 34, categoryDeYu, 30)
        add(130, "德育活动及比赛获奖（国家级二等奖）", 31, categoryDeYu, 31)
        add(131, "德育活动及比赛获奖（国家级三等奖）", 28, categoryDeYu, 32)
        add(132, "担任班长、团支书", 6.0, categoryDeYu, 33)
        add(133, "担任副班长、团副支书", 5.0, categoryDeYu, 34)
        add(134, "担任校系级团学组织主要负责人", 8.0, categoryDeYu, 35)
        add(135, "担任校系级团学组织分支机构负责人", 6.0, categoryDeYu, 36)
        add(136, "担任校系级团学组织干事", 4.0, categoryDeYu, 37)
        add(137, "通过遵纪守法民主评议", 5.0, categoryDeYu, 38)
        add(138, "举报他人违纪", 2.0, categoryDeYu, 39)
        add(139, "通过低碳环保民主评议", 5.0, categoryDeYu, 40)
        add(144, "班级常规（优秀）", 3.0, categoryDeYu, 41)
        add(145, "班级常规（良好）", 2.0, categoryDeYu, 42)
        add(146, "班级常规（合格）", 1.0, categoryDeYu, 43)
        add(147, "先进集体成员（县级）", 5.0, categoryDeYu, 44)
        add(148, "先进集体成员（市级）", 7.0, categoryDeYu, 45)
        add(149, "先进集体成员（省级）", 9.0, categoryDeYu, 46)
        add(150, "先进集体成员（国家级）", 11.0, categoryDeYu, 47)
        add(156, "其他附加项目", 1.0, categoryDeYu, 48)
        add(157, "阅读（阅读并撰写读书笔记，+2.0分/本）", 2.0, categoryZhiYu, 1)
        add(158, "参加征文比赛（班级层面）", 1.0, categoryZhiYu, 2)
        add(159, "参加征文比赛（系级层面）", 2.0, categoryZhiYu, 3)
        add(160, "参加征文比赛（校级层面）", 2, categoryZhiYu, 4)
        add(161, "参加征文比赛（县级及以上层面）", 4.0, categoryZhiYu, 5)
        add(162, "征文比赛获奖（系级一等奖）", 8, categoryZhiYu, 6)
        add(163, "征文比赛获奖（系级二等奖）", 5, categoryZhiYu, 7)
        add(164, "征文比赛获奖（系级三等奖）", 2, categoryZhiYu, 8)
        add(165, "征文比赛获奖（校级一等奖）", 12, categoryZhiYu, 9)
        add(166, "征文比赛获奖（校级二等奖）", 9, categoryZhiYu, 10)
        add(167, "征文比赛获奖（校级三等奖）", 6, categoryZhiYu, 11)
        add(168, "征文比赛获奖（县级一等奖）", 16, categoryZhiYu, 12)
        add(169, "征文比赛获奖（县级二等奖）", 13, categoryZhiYu, 13)
        add(170, "征文比赛获奖（县级三等奖）", 10, categoryZhiYu, 14)
        add(171, "征文比赛获奖（市级一等奖）", 20, categoryZhiYu, 15)
        add(172, "征文比赛获奖（市级二等奖）", 17, categoryZhiYu, 16)
        add(173, "征文比赛获奖（市级三等奖）", 14, categoryZhiYu, 17)
        add(174, "征文比赛获奖（省级一等奖）", 30, categoryZhiYu, 18)
        add(175, "征文比赛获奖（省级二等奖）", 27, categoryZhiYu, 19)
        add(176, "征文比赛获奖（省级三等奖）", 24, categoryZhiYu, 20)
        add(177, "征文比赛获奖（国家级一等奖）", 34, categoryZhiYu, 21)
        add(178, "征文比赛获奖（国家级二等奖）", 31, categoryZhiYu, 22)
        add(179, "征文比赛获奖（国家级三等奖）", 28, categoryZhiYu, 23)
        add(180, "参加技能竞赛（校级层面）", 2.0, categoryZhiYu, 24)
        add(181, "参加技能竞赛（县市级层面）", 4.0, categoryZhiYu, 25)
        add(182, "参加技能竞赛（省级层面）", 6.0, categoryZhiYu, 26)
        add(183, "参加技能竞赛（国家级层面）", 8.0, categoryZhiYu, 27)
        add(184, "技能竞赛获奖（校级一等奖）", 12, categoryZhiYu, 28)
        add(185, "技能竞赛获奖（校级二等奖）", 9, categoryZhiYu, 29)
        add(186, "技能竞赛获奖（校级三等奖）", 6, categoryZhiYu, 30)
        add(187, "技能竞赛获奖（县市级一等奖）", 22.0, categoryZhiYu, 31)
        add(188, "技能竞赛获奖（县市级二等奖）", 18.0, categoryZhiYu, 32)
        add(189, "技能竞赛获奖（县市级三等奖）", 14.0, categoryZhiYu, 33)
        add(190, "技能竞赛获奖（省级一等奖）", 30, categoryZhiYu, 34)
        add(191, "技能竞赛获奖（省级二等奖）", 27, categoryZhiYu, 35)
        add(192, "技能竞赛获奖（省级三等奖）", 24, categoryZhiYu, 36)
        add(193, "技能竞赛获奖（国家级一等奖）", 34, categoryZhiYu, 37)
        add(194, "技能竞赛获奖（国家级二等奖）", 31, categoryZhiYu, 38)
        add(195, "技能竞赛获奖（国家级三等奖）", 28, categoryZhiYu, 39)
        add(196, "考工考证（通过：+4.0分/证）", 4.0, categoryZhiYu, 40)
        add(197, "参与发明专利", 16.0, categoryZhiYu, 41)
        add(198, "智育附加项目", 1.0, categoryZhiYu, 42)
        add(199, "参与体育俱乐部", 6.0, categoryTiYu, 1)
        add(200, "参与体质测试（优秀）", 5.0, categoryTiYu, 2)
        add(201, "参与体质测试（良好）", 4.0, categoryTiYu, 3)
        add(202, "参与体质测试（及格）", 2.0, categoryTiYu, 4)
        add(203, "参与体育比赛（系级层面）", 1.0, categoryTiYu, 5)
        add(204, "参与体育比赛（校级层面）", 2.0, categoryTiYu, 6)
        add(205, "参与体育比赛（县市级以上层面）", 4.0, categoryTiYu, 7)
        add(206, "体育比赛获奖（系级一等奖）", 8, categoryTiYu, 8)
        add(207, "体育比赛获奖（系级二等奖）", 5, categoryTiYu, 9)
        add(208, "体育比赛获奖（系级三等奖）", 2, categoryTiYu, 10)
        add(209, "体育比赛获奖（校级一等奖）", 12, categoryTiYu, 11)
        add(210, "体育比赛获奖（校级二等奖）", 9, categoryTiYu, 12)
        add(211, "体育比赛获奖（校级三等奖）", 6, categoryTiYu, 13)
        add(212, "体育比赛获奖（县级一等奖）", 16, categoryTiYu, 14)
        add(213, "体育比赛获奖（县级二等奖）", 13, categoryTiYu, 15)
        add(214, "体育比赛获奖（县级三等奖）", 10, categoryTiYu, 16)
        add(215, "体育比赛获奖（市级一等奖）", 20, categoryTiYu, 17)
        add(216, "体育比赛获奖（市级二等奖）", 17, categoryTiYu, 18)
        add(217, "体育比赛获奖（市级三等奖）", 14, categoryTiYu, 19)
        add(218, "体育比赛获奖（省级一等奖）", 30, categoryTiYu, 20)
        add(219, "体育比赛获奖（省级二等奖）", 27, categoryTiYu, 21)
        add(220, "体育比赛获奖（省级三等奖）", 24, categoryTiYu, 22)
        add(221, "体育比赛获奖（国家级一等奖）", 34, categoryTiYu, 23)
        add(222, "体育比赛获奖（国家级二等奖）", 31, categoryTiYu, 24)
        add(223, "体育比赛获奖（国家级三等奖）", 28, categoryTiYu, 25)
        add(224, "通过安全健康常识民主评议", 5.0, categoryTiYu, 26)
        add(225, "参与运动打卡", 3.0, categoryTiYu, 27)
        add(226, "参与应急救护培训", 3.0, categoryTiYu, 28)
        add(227, "通过应急救护考证", 10.0, categoryTiYu, 29)
        add(228, "体育附加项目", 1.0, categoryTiYu, 30)
        add(229, "参与艺术类必修课", 6.0, categoryMeiYu, 1)
        add(230, "参与艺术类选修课（系级）", 4.0, categoryMeiYu, 2)
        add(231, "参与艺术类选修课（校级）", 6.0, categoryMeiYu, 3)
        add(232, "参与环境布置、黑板报等", 2.0, categoryMeiYu, 4)
        add(233, "艺术作品展示", 2.0, categoryMeiYu, 5)
        add(234, "参与艺术类社团（系级）", 4.0, categoryMeiYu, 6)
        add(235, "参与艺术类社团（校级）（高水平艺术团）", 15.0, categoryMeiYu, 7)
        add(236, "参与艺术类表演（校内）", 2.0, categoryMeiYu, 8)
        add(237, "参与艺术类表演（校外）", 4.0, categoryMeiYu, 9)
        add(238, "参与艺术类竞赛（系级、校级层面）", 2.0, categoryMeiYu, 10)
        add(239, "参与艺术类竞赛（县市级以上层面）", 4.0, categoryMeiYu, 11)
        add(240, "艺术类竞赛获奖（系级一等奖）", 8, categoryMeiYu, 12)
        add(241, "艺术类竞赛获奖（系级二等奖）", 5, categoryMeiYu, 13)
        add(242, "艺术类竞赛获奖（系级三等奖）", 2, categoryMeiYu, 14)
        add(243, "艺术类竞赛获奖（校级一等奖）", 12, categoryMeiYu, 15)
        add(244, "艺术类竞赛获奖（校级二等奖）", 9, categoryMeiYu, 16)
        add(245, "艺术类竞赛获奖（校级三等奖）", 6, categoryMeiYu, 17)
        add(246, "艺术类竞赛获奖（县级一等奖）", 16, categoryMeiYu, 18)
        add(247, "艺术类竞赛获奖（县级二等奖）", 13, categoryMeiYu, 19)
        add(248, "艺术类竞赛获奖（县级三等奖）", 10, categoryMeiYu, 20)
        add(249, "艺术类竞赛获奖（市级一等奖）", 20, categoryMeiYu, 21)
        add(250, "艺术类竞赛获奖（市级二等奖）", 17, categoryMeiYu, 22)
        add(251, "艺术类竞赛获奖（市级三等奖）", 14, categoryMeiYu, 23)
        add(252, "艺术类竞赛获奖（省级一等奖）", 30, categoryMeiYu, 24)
        add(253, "艺术类竞赛获奖（省级二等奖）", 27, categoryMeiYu, 25)
        add(254, "艺术类竞赛获奖（省级三等奖）", 24, categoryMeiYu, 26)
        add(255, "艺术类竞赛获奖（国家级一等奖）", 34, categoryMeiYu, 27)
        add(256, "艺术类竞赛获奖（国家级二等奖）", 31, categoryMeiYu, 28)
        add(257, "艺术类竞赛获奖（国家级三等奖）", 28, categoryMeiYu, 29)
        add(258, "参与艺术类演出、展览、讲座等", 2.0, categoryMeiYu, 30)
        add(259, "美育附加项目", 1.0, categoryMeiYu, 31)
        add(260, "参与劳动", 2.0, categoryLaoYu, 1)
        add(261, "参与班级常规劳动", 2.0, categoryLaoYu, 2)
        add(262, "参与志愿者服务及公益劳动（班级层面）", 2.0, categoryLaoYu, 3)
        add(263, "参与志愿者服务及公益劳动（系级层面）", 3.0, categoryLaoYu, 4)
        add(264, "参与研学实践活动（班级层面）", 2.0, categoryLaoYu, 5)
        add(265, "参与研学实践活动（系级层面）", 3.0, categoryLaoYu, 6)
        add(266, "参与研学实践活动（校级及以上层面）", 4.0, categoryLaoYu, 7)
        add(267, "参与劳动教育课程", 6.0, categoryLaoYu, 8)
        add(268, "参与劳动专题教育", 2.0, categoryLaoYu, 9)
        add(269, "获评劳动积极分子", 6.0, categoryLaoYu, 10)
        add(270, "参与劳动礼仪周", 6.0, categoryLaoYu, 11)
        add(271, "参与勤工俭学", 10.0, categoryLaoYu, 12)
        add(272, "劳育附加项目", 1.0, categoryLaoYu, 13)
        add(273, "文化课成绩（及格 +2/门，不及格 -2/门）", 2.0, categoryZhiYu, 43)
        add(274, "专业课成绩（及格 +2/门，不及格 -2/门）", 2.0, categoryZhiYu, 44)
        add(275, "毕业设计/实训实践（及格 +2/门，不及格 -2/门）", 2.0, categoryZhiYu, 45)
        // 每周奖励（结算入口自动套用；面板按键也可手动补记）
        add(20, "校纪校规与打扫卫生一周无扣分", 1, categoryWeekly, 1)
        return rules
    }
}

/// 一条学分记录（留痕）：日期时间、学生、规则名/分值快照、备注、学期。
/// 一条记录可一次套给多名学生（语义同 CustomValue.link 的多人列表）。
struct CreditRecord: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    /// 记录时间（留痕用；补录时为补录时刻）
    var createdAt: Date = Date()
    /// 关联学生（Student.id）
    var studentIDs: [UUID] = []
    /// 套用的规则 id；nil = 自定义分值记录
    var ruleID: UUID? = nil
    /// 规则名快照（自定义记录为填写名称，空串显示“自定义”）
    var ruleName: String = ""
    /// 分值快照
    var points: Double = 0
    var note: String = ""
    /// 学期 key（如 "2026-2027-1"），创建时快照面板所选学期（补录 = 切到上学期再录）
    var semesterKey: String = ""

    /// 学生显示名（按记录中的 id 顺序；引用缺失时显示占位，不按姓名关联）
    func studentNames(in students: [Student]) -> String {
        guard !studentIDs.isEmpty else { return "—" }
        let byID = Dictionary(uniqueKeysWithValues: students.map { ($0.id, $0) })
        return studentIDs.map { byID[$0]?.name ?? "（已删除）" }.joined(separator: "、")
    }
}

// MARK: - 学期（推断与显示）

/// 学期 key 形如 "2026-2027-1"（学年起始年-学年结束年-第几学期）。
/// 无实例命名空间，便于单测（惯例同 StudentQuery / TableQuery）。
enum CreditSemester {

    /// 推断用的日历：公历（学年概念只在公历下定义），时区跟随系统
    static func inferenceCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar
    }

    /// 默认推断：8–12 月为「当年-次年」学年第一学期；
    /// 1 月属上一学年第一学期；2–7 月为上一学年第二学期。
    static func infer(from date: Date) -> String {
        infer(from: date, calendar: inferenceCalendar())
    }

    static func infer(from date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month], from: date)
        guard let year = comps.year, let month = comps.month else { return "" }
        switch month {
        case 8...12:
            return key(startYear: year, semester: 1)
        case 1:
            return key(startYear: year - 1, semester: 1)
        default: // 2...7
            return key(startYear: year - 1, semester: 2)
        }
    }

    static func key(startYear: Int, semester: Int) -> String {
        "\(startYear)-\(startYear + 1)-\(semester)"
    }

    /// 显示名："2026-2027-1" → "2026-2027 学年第一学期"；无法解析时原样返回
    static func displayName(for key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let semester = Int(parts[2]),
              semester == 1 || semester == 2 else { return key }
        return "\(parts[0])-\(parts[1]) 学年\(semester == 1 ? "第一学期" : "第二学期")"
    }

    /// 上一学期："2026-2027-2" ← "2026-2027-1"；"2025-2026-2" ← "2026-2027-1"
    static func previous(of semesterKey: String) -> String? {
        let parts = semesterKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts[2] == 2 ? key(startYear: parts[0], semester: 1)
                             : key(startYear: parts[0] - 1, semester: 2)
    }

    /// 近 count 个学期（当前推断学期在前，依次回退；切换器用）
    static func recentSemesters(from date: Date, count: Int = 4) -> [String] {
        recentSemesters(from: date, count: count, calendar: inferenceCalendar())
    }

    static func recentSemesters(from date: Date, count: Int, calendar: Calendar) -> [String] {
        var result: [String] = []
        var current = infer(from: date, calendar: calendar)
        guard !current.isEmpty else { return [] }
        for _ in 0..<max(count, 0) {
            result.append(current)
            guard let previous = previous(of: current) else { break }
            current = previous
        }
        return result
    }
}

// MARK: - 每周无扣分奖励（纯逻辑）

/// 「校纪校规与打扫卫生一周无扣分 +1」的结算判定。
/// 口径：目标周（周一 00:00 起 7 天）内，没有任何扣分记录（任何负分规则——
/// 含校纪校规全部子项与自定义扣分）的学生获得 +1；当周已结算过的学生自动排除（幂等）。
enum CreditWeeklyBonus {

    /// 内置规则 #20（校纪校规与打扫卫生一周无扣分）的固定 id
    static var bonusRuleID: UUID { CreditRule.defaults.first { $0.category == CreditRule.categoryWeekly }!.id }

    /// 含 date 的那一周（周一 00:00 起 7 天）的区间
    static func weekInterval(containing date: Date, calendar: Calendar = weekCalendar()) -> DateInterval {
        let dayStart = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: dayStart)
        let daysFromMonday = (weekday - 2 + 7) % 7   // weekday: 1=周日 2=周一
        let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: dayStart) ?? dayStart
        return DateInterval(start: monday, duration: 7 * 24 * 3600)
    }

    /// 周一为一周起点的工作日历
    static func weekCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }

    /// 周显示名："10月5日 – 10月11日"
    static func weekLabel(for interval: DateInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let endDay = interval.start.addingTimeInterval(6 * 24 * 3600)
        return "\(formatter.string(from: interval.start)) – \(formatter.string(from: endDay))"
    }

    /// 目标周内符合「无扣分」且未结算过的学生 id（保持传入顺序）。
    /// 判定按分值而非规则 ID：该周内任何负分记录（内置规则、自定义扣分、改名/删除过的规则）
    /// 都取消资格——按 ID 匹配会漏掉自定义扣分与规则变动后的记录。
    static func qualifyingStudents(allStudentIDs: [UUID], records: [CreditRecord],
                                  week: DateInterval,
                                  bonusRuleID: UUID = CreditWeeklyBonus.bonusRuleID) -> [UUID] {
        var deducted: Set<UUID> = []
        var settled: Set<UUID> = []
        for record in records where week.contains(record.createdAt) {
            if record.points < 0 {
                deducted.formUnion(record.studentIDs)
            }
            if record.ruleID == bonusRuleID {
                settled.formUnion(record.studentIDs)
            }
        }
        return allStudentIDs.filter { !deducted.contains($0) && !settled.contains($0) }
    }
}

// MARK: - 汇总（纯逻辑，总分不落库）

/// 每生小计与学期合计：一律由记录按 semesterKey 过滤后累计（惯例同 StudentQuery 无实例命名空间）
enum CreditSummary {

    /// 每生本学期小计（一记多名学生时每个学生各得一次该分值）
    static func studentTotals(records: [CreditRecord], semesterKey: String) -> [UUID: Double] {
        var totals: [UUID: Double] = [:]
        for record in records where record.semesterKey == semesterKey {
            for studentID in record.studentIDs {
                totals[studentID, default: 0] += record.points
            }
        }
        return totals
    }

    /// 学期合计 = 各生小计之和（一记多生按生数累计，与每生小计口径一致）
    static func semesterTotal(records: [CreditRecord], semesterKey: String) -> Double {
        records
            .filter { $0.semesterKey == semesterKey }
            .reduce(0) { $0 + $1.points * Double(max($1.studentIDs.count, 1)) }
    }

    /// 分值显示：整数不带小数位，半分显示 0.5（去尾零格式同 CustomValue 数值分支）
    static func pointsText(_ points: Double) -> String {
        if points == points.rounded() && abs(points) < 1e15 { return String(Int(points)) }
        var text = String(format: "%.2f", points)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// 带符号显示："+2" / "+0.5"；零与负数自带符号（"0" / "-2"）
    static func signedPointsText(_ points: Double) -> String {
        points > 0 ? "+" + pointsText(points) : pointsText(points)
    }
}
