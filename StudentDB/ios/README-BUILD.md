# StudentDBiOS —— iOS 应用构建说明

本目录是 iOS 端应用骨架（`StudentDBiOS` target 的源码）。**此阶段只有源码与说明，
Xcode 工程文件（.xcodeproj）由集成工程师生成**，本文档说明工程怎么搭、数据层怎么引入、
以及目前数据层尚存的 iOS 适配缺口。

---

## 1. 本目录文件清单

| 文件 | 作用 |
|---|---|
| `StudentDBiOSApp.swift` | iOS 端 `@main` 入口（`.onOpenURL` 打开 `.studentproj`、退后台 `flushSave()`） |
| `RootView.swift` | 根视图：按 `appModel.isLocked` / `appModel.store` 分流到锁屏 / 项目列表 / 主界面 |
| `ProjectListView.swift` | 项目列表（扫描 Documents、Documents/Inbox、iCloud 容器；新建项目；`fileImporter` 浏览文件）+ `MainTabView` 占位 |
| `iOSPlatformServices.swift` | `PlatformServices` 协议的 iOS 实现（QuickLook / 直接删除 / 触感反馈；面板类方法返回 nil，由界面层 `fileImporter` 承担） |
| `Info.plist` | 显示名「学生信息管理系统」、`UILaunchScreen`、`UIFileSharingEnabled`、`LSSupportsOpeningDocumentsInPlace`、`.studentproj` 的 UTI 声明 |

---

## 2. 数据层如何引入（共享 SwiftPM 源码）

`StudentDB/Package.swift` 第 6-9 行已声明双平台支持（`.macOS(.v15)`、`.iOS(.v17)`），
无需改 Package.swift。但**不要**把 iOS App 依赖到这个 SwiftPM 包上：
包里唯一的 target 是 `executableTarget`（Package.swift 第 11-14 行），其入口
`Sources/StudentDB/App/StudentDBApp.swift` 是 macOS 专用（`@main` + AppKit +
`@NSApplicationDelegateAdaptor`），iOS 引包会同时出现两个 `@main` 并链接不到 AppKit。

**正确做法：Xcode 工程的 App target 直接把共享源码文件作为成员文件编译**，成员如下：

必须加入 Compile Sources：

```
ios/StudentDBiOS/*.swift                                    （本骨架全部 4 个 Swift 文件）
Sources/StudentDB/Models/*.swift                            （Models.swift、StudentTableSpec.swift、Table.swift）
Sources/StudentDB/Store/*.swift                             （全部，含 AppModel、ProjectStore、PlatformServices 等）
Sources/StudentDB/Views/LockScreenView.swift                （仅此一个视图是纯 SwiftUI，iOS 可用）
```

**不要**加入（macOS 专用）：

```
Sources/StudentDB/App/StudentDBApp.swift                    （macOS @main + AppKit + AppDelegate）
Sources/StudentDB/Views/ 其余全部文件                        （使用 NSOpenPanel/NSSound/nsImage 等 AppKit API，
                                                             见 Views/StudentTableView.swift:2、
                                                             Views/Shared.swift:167、Views/RecordViews.swift:439 等）
```

---

## 3. 数据层当前的 iOS 编译/运行缺口（本骨架未越权修改，需数据层 owner 处理）

骨架按「数据层已跨平台」的口径编写，但核对共享源码后确认以下位置仍是 macOS 专用，
在 iOS 目标下会编译失败或运行崩溃。均为小改动，列出精确位置：

1. **`Sources/StudentDB/Store/ProjectStore.swift:2`** —— 顶层 `import AppKit`。
   iOS 没有 AppKit 模块，直接编译失败。该文件实际只在 `init` 的 `#if os(macOS)` 分支里
   用到 `MacPlatformServices`（ProjectStore.swift:34-41），把 import 用
   `#if os(macOS) ... #endif` 包住即可。
2. **`Sources/StudentDB/Store/AppModel.swift:2`** —— 同上，顶层 `import AppKit` 需包平台条件。
3. **`Sources/StudentDB/Store/AppModel.swift:96` 与 `:115`** ——
   `runExcelExport` / `runCSVExport` 里直接使用 `NSSavePanel`，未包 `#if os(macOS)`。
   iOS 侧应走 `UIDocumentPickerViewController`（导出）/ `fileExporter`，或暂时包条件编译。
4. **`Sources/StudentDB/Store/AppModel.swift:134`** —— `promptImportFile()` 里直接调用
   `MacPlatformServices()`，而该类型只在 `#if os(macOS)` 下存在
   （Store/PlatformServices.swift:31-99），iOS 下编译失败。iOS 分支应返回 nil
   （界面层用 `fileImporter` 承担）。
5. **`Sources/StudentDB/Store/AppModel.swift:49` 与 `:64`** —— `openProject` /
   `createProject` 里 `ProjectStore()` 未注入 platform。iOS 上会命中
   `ProjectStore.init` 里的 `precondition(platform != nil, "iOS 上必须注入 PlatformServices 实现")`
   （ProjectStore.swift:38）直接崩溃。需改为注入 `IOSPlatformServices()`：
   ```swift
   #if os(iOS)
   let newStore = ProjectStore(platform: IOSPlatformServices())
   #else
   let newStore = ProjectStore()
   #endif
   ```
   （`IOSPlatformServices` 定义在 `ios/StudentDBiOS/iOSPlatformServices.swift`，与共享层同 target，internal 可见。）
6. **`SearchKit` 位置跨层** —— 数据层 `Models.swift:629` 调用 `SearchKit.searchableText`，
   但 `SearchKit` 定义在 macOS 专用视图文件 `Views/Shared.swift:175-193` 里
   （同文件的 `FileIconView`/`ResizableSheetEnabler` 依赖 AppKit，不能进 iOS 目标）。
   `SearchKit` 本身是纯 Foundation 逻辑，把它搬到跨平台位置（如 `Store/SearchKit.swift`）即可。

### 验证结果（2026-10-01）

在 /tmp 沙箱副本上按上述 6 条打了临时补丁后，用 iOS 17 模拟器 SDK 对
「ios/StudentDBiOS/*.swift + Models/*.swift + Store/*.swift + Views/LockScreenView.swift」
整体 `swiftc -typecheck` **通过（0 error）**；骨架的 4 个文件无 error 无 warning，
仅剩共享层原有的几条无关 warning（StudentTableSpec.swift:246、MiniZIP.swift:160、
ProjectStore.swift:275、StudentImporter.swift:43）。**仓库内共享源文件未做任何改动**，
补丁只存在于沙箱，正式修复需由数据层 owner 按上表执行。

> Store 目录其余文件（AppLock、MiniZIP、XLSX、ExcelExporter、CSVExporter、
> SQLiteExporter、TableImporter）已核对：钥匙串用的是跨平台 `kSecClassGenericPassword`
> （AppLock.swift:62），Models 与其余 Store 文件无 AppKit/UIKit 引用，iOS 可直接编译。

---

## 4. Xcode 工程生成步骤（集成工程师执行）

1. **新建工程**：Xcode → File → New → Project → iOS → App；
   Product Name `StudentDBiOS`；Interface SwiftUI；Language Swift；
   位置放在 `StudentDB/ios/` 下（工程文件与 `StudentDBiOS/` 源码目录平级或按团队惯例）。
2. **删除模板文件**：模板生成的 `StudentDBiOSApp.swift`、`ContentView.swift`、
   以及 `Info.plist`（若为 GENERATE_INFOPLIST_FILE 模式则改为指向本目录的
   `Info.plist`：Target → Build Settings → Info.plist File = `ios/StudentDBiOS/Info.plist`，
   或改用 GENERATE_INFOPLIST_FILE 并把键值并入 target 设置——二选一，不要双份）。
3. **加入源码成员**：按第 2 节清单把共享源码与本骨架文件加入 target
   （用文件夹引用或 Xcode 分组均可；不要创建 copy）。
4. **部署目标**：iOS 17.0（与 Package.swift 第 8 行 `.iOS(.v17)` 对齐；共享代码用了
   `.onChange(of:)` 双参数闭包等 iOS 17 API）。
5. **Bundle Identifier**：建议 `com.monsterisdrinkingwater.studentdb.ios`。
   UTI 已固定为 `com.monsterisdrinkingwater.studentdb.project`（与 AppModel.swift:20 的
   `AppModel.projectUTI` 一致），不随 Bundle ID 变化。
6. **能力（可选）**：
   - iCloud：Signing & Capabilities → iCloud → Documents（勾选容器）。
     未配置时项目列表自动只显示本机 Documents 与 Inbox（`ubiquityContainerDocuments()`
     返回 nil，列表页会显示提示）。
   - `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` 已在 Info.plist：
     用户可在访达（或「文件」App）里看到 Documents 目录，其他 App 可用
     「用本应用打开」投递 `.studentproj`（走 `onOpenURL`）或拷贝进 Inbox。
7. **验证清单**：
   - 新建项目 → RootView 切到主界面占位 → 「关闭项目」回列表；
   - 「浏览文件…」用 fileImporter 选 `.studentproj` 打开；
   - 从「文件」App 点 `.studentproj` 用本应用打开（onOpenURL）；
   - 设置启动密码后重启 App 出现锁屏（共享 LockScreenView）；
   - App 退后台再杀掉，重开项目数据不丢（scenePhase → flushSave）。

---

## 5. 与 macOS 端的口径差异备注

- macOS 的 UTI 在 build.sh 里写作 `${BUNDLE_ID}.project`（build.sh 第 76、84 行），
  iOS 端固定为 `com.monsterisdrinkingwater.studentdb.project`。两平台 UTI 标识符不同没有影响：
  代码侧统一用「扩展名 + conformsTo .package」推导类型
  （`AppModel.projectType`，AppModel.swift:139-143）。
- macOS 的「打开/新建项目」走 NSOpenPanel/NSSavePanel（AppModel.swift:145-174，
  已包 `#if os(macOS)`）；iOS 走 `fileImporter` 与「新建项目」sheet，不走协议方法。
