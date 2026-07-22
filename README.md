<div align="center">
  <img src="portViewer.png" width="128" height="128" alt="Port Viewer 图标">
  <h1>Port Viewer</h1>
  <p>一眼看懂端口被谁占用，以及应用正在进行什么网络活动。</p>

  <p>
    <a href="https://github.com/super-213/port-viewer/actions/workflows/xcode-build-analyze.yml"><img src="https://github.com/super-213/port-viewer/actions/workflows/xcode-build-analyze.yml/badge.svg" alt="Xcode 构建状态"></a>
    <img src="https://img.shields.io/badge/macOS-15.0%2B-black?logo=apple" alt="macOS 15.0 或更高版本">
    <img src="https://img.shields.io/badge/Swift-5-F05138?logo=swift&amp;logoColor=white" alt="Swift 5">
  </p>
</div>

Port Viewer 是一款使用 SwiftUI 构建的 macOS 原生端口查看工具。它把系统 `lsof` 返回的进程、端口和连接信息转换成更容易理解的中文结论，让不熟悉命令行的用户也能快速找到端口占用者，并在明确了解影响后结束对应进程。

所有查询都在本机完成，不需要账号，也不会把进程或网络连接数据上传到远端。

## 功能亮点

- **易懂的网络状态**：将 `LISTEN`、`ESTABLISHED` 等技术状态转换为“等待连接”“连接已建立”等中文说明。
- **连接关系可视化**：说明应用、本机端口与远端地址之间的关系，并区分“仅本机访问”和“同一网络可能访问”。
- **快速搜索与筛选**：按进程名、PID 或端口搜索，支持范围、访问来源、进程归属、协议、IP 版本和 TCP 状态筛选。
- **TCP 与 UDP 一并查看**：展示监听端口、已建立连接、连接变化和其他网络活动，同时保留完整技术字段。
- **菜单栏快捷入口**：无需打开主窗口即可查看概况、搜索记录、刷新数据或定位到详情。
- **自动刷新**：前台和后台可使用不同刷新间隔，也可暂停或手动刷新。
- **谨慎释放端口**：操作前重新确认进程仍在占用目标端口；优先发送 `SIGTERM`，必要时才提示使用 `SIGKILL`，操作后再次查询验证结果。
- **系统级使用体验**：支持浅色/深色外观、键盘快捷键和 VoiceOver 友好的文字说明。

## 系统要求

- macOS 15.0 或更高版本
- Xcode 16 或更高版本（持续集成使用 Xcode 16.4）
- 系统自带的 `/usr/sbin/lsof`

项目不依赖第三方 Swift Package。

## 快速开始

克隆仓库并打开 Xcode 项目：

```bash
git clone https://github.com/super-213/port-viewer.git
cd port-viewer
open PortViewer.xcodeproj
```

在 Xcode 中选择 `PortViewer` scheme 和 `My Mac`，然后按 `⌘R` 构建并运行。

也可以从命令行完成无签名构建：

```bash
xcodebuild \
  -project PortViewer.xcodeproj \
  -scheme PortViewer \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 使用方法

1. 启动应用后，Port Viewer 会自动读取当前 TCP/UDP 端口和连接。
2. 在搜索框输入进程名、PID 或端口号；输入 `:3000` 可只精确匹配端口 `3000`。
3. 从左侧选择“等待连接”“连接活动”或“其他活动”，也可以组合更多筛选条件。
4. 选择一条记录，查看易懂结论、连接关系、访问范围和可展开的技术详情。
5. 如需释放端口，选择“结束进程”并确认影响。应用会在发送信号前后分别校验一次实时状态。

常用快捷键：

| 快捷键 | 操作 |
|---|---|
| `⌘F` | 聚焦进程/端口搜索 |
| `⌘R` | 立即刷新 |
| `Esc` | 清空当前搜索 |

## 安全与隐私

- 端口信息来自本机 `/usr/sbin/lsof`，查询与解析均在本地执行。
- 应用不会执行用户输入的 Shell 命令，也不包含远程主机或公网端口扫描。
- 当前版本不申请管理员权限，只允许结束当前登录用户拥有的进程。
- 对 `launchd`、`kernel_task` 等关键系统进程禁用强制结束。
- “同一网络可能访问”仅根据监听地址推断，不代表端口已经暴露到公网；实际访问仍受防火墙和网络环境影响。
- 受 macOS 权限限制，部分其他用户或系统进程的信息可能不可见。

## 技术架构

项目采用 **MVVM + Service + Observation + Swift Concurrency**。`PortViewerApp` 是组合根，显式创建协议化 Service、全局 `PortViewModel` 和两个页面级 ViewModel。主窗口与菜单栏共享同一份查询快照，但各自保留独立的搜索、筛选与选择状态；View 不直接执行系统命令。

```mermaid
flowchart LR
    subgraph System["macOS 系统"]
        LSOF["/usr/sbin/lsof"]
        PROC["proc_pidpath"]
        KILL["Darwin.kill"]
    end

    subgraph Services["协议化 Service 层"]
        QUERY["PortQuerying"]
        CLIENT["LsofService actor"]
        PARSER["LsofParser"]
        CONTROL["ProcessControlling"]
        CONTROLLER["ProcessService"]
    end

    subgraph State["@MainActor Observation ViewModel"]
        RAW["PortRecord / PortSnapshot"]
        STORE["PortViewModel"]
        MAIN_VM["MainWindowViewModel"]
        MENU_VM["MenuBarViewModel"]
        PRESENTATION["ReadablePortItem / 活动快照"]
    end

    subgraph UI["SwiftUI 展示层"]
        MAIN["主窗口"]
        MENU["菜单栏面板"]
        SETTINGS["设置页"]
    end

    LSOF --> CLIENT
    PROC --> CLIENT
    QUERY --> CLIENT --> PARSER --> RAW --> STORE
    STORE --> MAIN_VM --> PRESENTATION --> MAIN
    STORE --> MENU_VM --> MENU
    SETTINGS -. "UserDefaults" .-> STORE
    STORE --> CONTROL --> CONTROLLER --> KILL
```

> 图中的 `proc_pidpath` 用于补充可执行文件路径；`Darwin.kill` 仅在用户确认结束进程后调用。

### 分层职责

| 层级 | 主要文件 | 职责 |
|---|---|---|
| 应用入口 | [`PortViewerApp.swift`](PortViewer/PortViewerApp.swift) | 注册窗口、菜单栏、设置与命令，显式组装 Service 和 ViewModel，并管理应用级启动/停止 |
| 展示层 | [`MainWindowView.swift`](PortViewer/Views/MainWindowView.swift)、[`MenuBarPanel.swift`](PortViewer/Views/MenuBarPanel.swift)、[`SettingsView.swift`](PortViewer/Views/SettingsView.swift) | 布局、绑定、焦点和局部展开状态；用户事件转发给 ViewModel |
| 全局 ViewModel | [`PortViewModel.swift`](PortViewer/ViewModels/PortViewModel.swift) | 共享快照、刷新循环、查询状态、连接变化以及结束进程安全用例 |
| 页面 ViewModel | [`MainWindowViewModel.swift`](PortViewer/ViewModels/MainWindowViewModel.swift)、[`MenuBarViewModel.swift`](PortViewer/ViewModels/MenuBarViewModel.swift) | 主窗口筛选/排序/选择恢复和菜单栏搜索/展示上限；缓存重复分组结果 |
| 展示模型 | [`NetworkPresentation.swift`](PortViewer/Models/NetworkPresentation.swift) | 将原始网络记录归组，生成中文状态、访问范围、连接结论和活动变化 |
| 数据模型 | [`PortRecord.swift`](PortViewer/Models/PortRecord.swift) | 定义原始端口记录、查询快照、端点格式和搜索匹配规则 |
| 查询服务 | [`PortQuerying.swift`](PortViewer/Services/PortQuerying.swift)、[`LsofClient.swift`](PortViewer/Services/LsofClient.swift)、[`LsofParser.swift`](PortViewer/Services/LsofParser.swift) | single-flight 查询、强制新查询、异步 Pipe 读取、超时/取消清理、解析和进程路径补充 |
| 进程服务 | [`ProcessControlling.swift`](PortViewer/Services/ProcessControlling.swift)、[`ProcessController.swift`](PortViewer/Services/ProcessController.swift) | 检查 PID、发送信号、稳定映射系统错误并保护关键系统进程 |

### 查询与刷新数据流

1. `PortViewModel.start()` 触发首次查询，并持有可取消的自动刷新循环。
2. `LsofService` 以 actor 隔离 single-flight 状态，再通过 utility 优先级任务执行 `/usr/sbin/lsof -nP -iTCP -iUDP -F0pcuLRftnPT`。
3. `LsofParser` 解析 NUL 分隔字段，生成稳定标识的 `PortRecord`；随后使用 `proc_pidpath` 尽可能补充可执行文件路径。
4. 查询结果以完整 `PortSnapshot` 返回，并在 `@MainActor @Observable` 的 `PortViewModel` 中一次性应用。
5. `MainWindowViewModel` 只在原始记录变化时重新生成 `ReadablePortItem`，再在内存快照上搜索、筛选和排序。
6. Observation 只让读取了相应状态的 SwiftUI 视图失效；Task、Service 引用与缓存通过 `@ObservationIgnored` 排除。

刷新机制的关键约束：

- 主窗口可见时默认每 3 秒刷新，后台默认每 5 秒刷新，可在设置页调整。
- 单次查询最多等待 5 秒；Process 与 Pipe 被包装为可取消异步会话，完成、超时和取消都等待子进程退出及两个 Pipe 到达 EOF。
- 普通查询复用正在执行的 single-flight；危险操作的 `.fresh` 查询会等待当前查询释放资源后再启动，不会并行运行第二个 `lsof`。
- 自动刷新不会堆积；查询期间收到的手动刷新会合并为下一次查询。
- 单个等待者取消不会取消共享查询；应用退出会由全局 ViewModel 明确取消当前查询。
- 完整查询失败时保留上一份快照和最后成功时间；部分结果会明确标记，不会被当作完整结果用于危险操作。
- 每次快照会与上次结果比较，短暂展示监听端口中新出现、结束或变化的连接活动。

### 核心数据模型

| 类型 | 作用 |
|---|---|
| `PortRecord` | 一条未经简化的 TCP/UDP 记录，包含进程、PID、用户、文件描述符、协议、地址、端口和状态 |
| `PortSnapshot` | 一次查询的原子结果，附带采集时间、耗时和“结果是否不完整”标记 |
| `QueryPresentationState` | 区分加载、正常、空数据、暂停、部分结果、失败和 `lsof` 不可用等界面状态 |
| `ReadablePortItem` | 面向用户的归组记录，保存全部原始记录，并提供中文结论、状态与访问范围 |
| `PortActivitySnapshot` | 记录监听端口对应的连接标识和远端端点，用于计算两次刷新之间的变化 |
| `TerminationPrompt` | 保存普通/强制结束阶段、目标记录、其他连接、共同占用者和关键进程标记 |

### 结束进程时序

结束端口占用者不是直接执行 `kill`。应用会重新查询实时状态、校验进程归属并让用户确认，之后再验证操作结果。

```mermaid
sequenceDiagram
    actor User as 用户
    participant View as 详情界面
    participant Store as PortViewModel
    participant Query as LsofService
    participant Process as ProcessService

    User->>View: 选择“结束进程”
    View->>Store: prepareToTerminate(当前记录)
    Store->>Query: query(policy: .fresh)
    Query-->>Store: 最新 PortSnapshot
    Store->>Store: 校验用户、PID、端口与共同占用者
    Store-->>View: 展示影响和确认信息
    User->>Store: 确认结束
    Store->>Process: 发送 SIGTERM
    Store->>Query: 等待后 query(policy: .fresh)
    Query-->>Store: 验证后的快照
    alt 原进程不再占用
        Store-->>View: 显示已释放或被其他进程重新占用
    else 原进程仍占用
        Store-->>View: 提示是否升级为 SIGKILL
    end
```

关键系统进程禁止强制结束；其他用户拥有的进程不会被操作；如果操作前查询不完整，则不会发送任何信号。

## 项目结构

```text
port-viewer/
├── .github/workflows/
│   └── xcode-build-analyze.yml     # GitHub Actions 构建与静态分析
├── PortViewer/
│   ├── Models/
│   │   ├── PortRecord.swift        # 原始端口模型与搜索
│   │   └── NetworkPresentation.swift # 易懂化模型与连接变化
│   ├── Services/
│   │   ├── PortQuerying.swift      # 查询协议与复用/强制新查询策略
│   │   ├── LsofClient.swift        # LsofService、single-flight 与异步进程桥接
│   │   ├── LsofParser.swift        # lsof 机器输出解析
│   │   ├── ProcessControlling.swift # 进程控制协议
│   │   └── ProcessController.swift # ProcessService 与关键进程保护
│   ├── ViewModels/
│   │   ├── PortViewModel.swift     # 全局快照、刷新和安全业务流程
│   │   ├── MainWindowViewModel.swift # 主窗口筛选、排序和选择
│   │   └── MenuBarViewModel.swift  # 菜单栏搜索和展示状态
│   ├── Views/
│   │   ├── MainWindowView.swift    # 主窗口与连接关系详情
│   │   ├── MenuBarPanel.swift      # 菜单栏面板
│   │   └── SettingsView.swift      # 刷新和菜单栏设置
│   ├── Assets.xcassets/
│   └── PortViewerApp.swift         # 应用入口
├── PortViewerTests/                # 单元测试与真实 lsof 集成测试
├── docs/                           # 产品需求文档
└── PortViewer.xcodeproj/
```

## 测试与持续集成

运行全部单元测试和本机 `lsof` 集成测试：

```bash
xcodebuild \
  -project PortViewer.xcodeproj \
  -scheme PortViewer \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

| 测试文件 | 覆盖范围 |
|---|---|
| [`LsofParserTests.swift`](PortViewerTests/LsofParserTests.swift) | 进程/文件字段、IPv4/IPv6 端点和异常字段解析 |
| [`PortSearchTests.swift`](PortViewerTests/PortSearchTests.swift) | 端口、PID、进程名搜索和精确匹配排序 |
| [`NetworkPresentationTests.swift`](PortViewerTests/NetworkPresentationTests.swift) | 中文状态、访问范围、记录归组、连接活动变化和数据表述边界 |
| [`PortViewModelTests.swift`](PortViewerTests/PortViewModelTests.swift) | 刷新状态、请求合并、活动变化和结束进程安全链路 |
| [`PageViewModelTests.swift`](PortViewerTests/PageViewModelTests.swift) | 搜索筛选排序、选择恢复/替代占用者和菜单栏独立状态 |
| [`LsofServiceTests.swift`](PortViewerTests/LsofServiceTests.swift) | single-flight、强制新查询、等待者取消、输出语义、超时与资源清理 |
| [`LsofClientIntegrationTests.swift`](PortViewerTests/LsofClientIntegrationTests.swift) | 使用 `LsofService` 在真实 macOS 环境执行 `lsof` 并校验快照 |

GitHub Actions 会在推送或向 `main` 分支提交 Pull Request 时，使用 Xcode 16.4 执行 clean、build 和 analyze。工作流定义见 [`xcode-build-analyze.yml`](.github/workflows/xcode-build-analyze.yml)。

## 开发扩展指引

- **新增 `lsof` 字段**：依次更新 `LsofParser`、`PortRecord`、需要的展示模型，并在 `LsofParserTests` 增加输入样本。
- **新增状态或易懂文案**：集中修改 `NetworkPresentation.swift`，同时补充 `NetworkPresentationTests`，避免技术状态与用户结论散落在视图中。
- **新增筛选项**：优先放入 `MainWindowViewModel` 并在现有快照上实现，不要让界面输入直接触发新的系统查询。
- **替换系统能力**：让新实现遵循 `PortQuerying` 或 `ProcessControlling`，并在应用组合根注入；ViewModel 不隐式创建生产 Service。
- **修改进程结束策略**：保持“强制新查询—确认—发送信号—强制新查询验证”的安全链路，并继续通过 `ProcessProtectionPolicy` 保护关键进程。

## 相关文档

- [产品需求文档](docs/requirements.md)
- [易懂化与图形化改版需求](docs/beginner-friendly-visualization-prd.md)
- [MVVM + Observation + Swift Concurrency 架构重构需求](docs/architecture-refactoring-requirements.md)

## 参与开发

欢迎提交 Issue 或 Pull Request。修改行为逻辑时，请同步补充或更新 `PortViewerTests` 中的测试，并确保本地构建和测试通过。
