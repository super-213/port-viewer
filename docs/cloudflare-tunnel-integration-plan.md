# Cloudflare Tunnel 联动实施计划

日期：2026-11-05。状态：本机回环 HTTP(S) 第一版已实现；验证记录与当前范围见第 11 节。

## 1. 结论与目标

**可行，建议先实现无需 Cloudflare 账号的本地只读发现。** 在本机端口记录旁显示关联域名和本机连接器状态，例如：

```text
项目 A · Vite    :5173    Cloudflare · dev.example.com · 本机隧道已连接
项目 B          :3000    Cloudflare · xxx.trycloudflare.com · 连接状态未知
```

可靠关联需要两类证据：运行中的 `cloudflared` 配置明确把域名转发到本机目标端点，以及该端点与当前监听记录匹配。不能根据常用端口、Cloudflare IP、7844 出站连接或进程名称单独推断域名。

“域名状态”拆分为三个维度：

1. **映射**：哪个域名、哪条路径规则对应哪个本机服务。
2. **本机连接器**：本机 `cloudflared` 是否已连到 Cloudflare 边缘。
3. **公网访问**：DNS、TLS、Access、源站及应用是否实际可用。第一版显示“未检测”，不把连接器就绪写成“公网可访问”。

无流量时也应能识别映射。既有 TCP 连接只能作为诊断补充，不能作为发现前提。

## 2. 当前代码与接入位置

本计划依据当前代码结构，而非仅依据历史架构文档：

| 现有文件 / 类型 | 已有能力 | 联动方案 |
|---|---|---|
| `PortViewer/Services/PortQueryService.swift` | 普通查询走 Darwin，失败回退 lsof，`.fresh` 独立走 lsof | 保持端口采集与危险操作查询职责；不在这里等待隧道 HTTP 请求 |
| `PortViewer/Models/PortRecord.swift` | PID、协议、监听地址、端口、`ProcessContext`、原始记录 ID | 使用监听记录匹配；保留原始 ID 和端口统计语义 |
| `PortViewer/Models/ProcessContext.swift` | `ProcessIdentity` 包含 PID、UID、秒及微秒启动时间 | 用完整身份绑定发现结果，防止 PID 复用造成串联 |
| `PortViewer/Services/ProcessContextResolver.swift` | 同用户 argv、工作目录、参数脱敏；不解析后续环境变量块 | 复用身份能力；仅提取必要的配置路径、metrics 地址等非敏感参数 |
| `PortViewer/Services/ManagedServiceController.swift` | Docker/Homebrew 服务归属与停止流程 | 隧道作为独立的多对多关联，不写入唯一的 `managedService` 字段 |
| `PortViewer/ViewModels/PortViewModel.swift` | 共享端口快照、`recordsRevision`、自动刷新与任务生命周期 | 注入独立隧道服务，持有隧道快照、revision 和可取消任务 |
| `PortViewer/Models/NetworkPresentation.swift` | `ReadablePortItem.group` 可把同应用的多个监听端口归成一行 | 遍历全部 `rawRecords` 关联；详情逐端口展示，不能只使用 representative |
| `PortViewer/ViewModels/MainWindowViewModel.swift` | 派生列表以 `recordsRevision` 失效缓存 | 增加隧道 revision 依赖，连接状态单独变化也能更新和搜索 |
| `PortViewer/ViewModels/MenuBarViewModel.swift` | 以端口记录缓存菜单栏列表 | 读取共享隧道状态，不重复发起发现请求 |
| `PortViewer/Views/MainWindowView.swift`、`MenuBarPanel.swift` | 应用表格、详情和菜单栏快捷记录 | 追加紧凑状态及详情区 |
| `PortViewer/PortViewerApp.swift` | 组合根显式创建并注入服务 | 创建 `CloudflareTunnelService` 并注入全局 ViewModel |

项目使用 Swift 6、macOS 15+，目前无第三方 Swift Package。优先用 Foundation 的 HTTP/JSON 能力完成第一版，避免为 YAML 解析先增加依赖。

## 3. 信息来源与支持范围

### 3.1 首选：运行中 cloudflared 的本地 HTTP 端点

官方文档说明 metrics 服务通常从 `20241–20245` 中选择空闲端口，也可能使用随机端口或显式指定地址，因此不能只扫描固定端口段。[来源：Observability](https://developers.cloudflare.com/tunnel/observability/)

本次核查的官方源码在同一 HTTP 服务上注册以下路由：

| 端点 | 用途 | 边界 |
|---|---|---|
| `/config` | 读取当前运行配置的 ingress 和版本 | 依赖 Orchestrator；不能假定所有版本都存在 |
| `/quicktunnel` | 获取 Quick Tunnel 的 hostname | 普通隧道可能返回空 hostname |
| `/ready` | 读取连接器就绪状态、连接数和 connector ID | 200 表示至少有一条边缘连接，503 表示没有；超时不是断开证据 |
| `/metrics` | 可选读取版本与诊断指标 | 按需读取，不作为域名映射的唯一依据 |

来源：[metrics 路由](https://github.com/cloudflare/cloudflared/blob/master/metrics/metrics.go)、[运行配置序列化](https://github.com/cloudflare/cloudflared/blob/master/orchestration/orchestrator.go)、[readiness 实现](https://github.com/cloudflare/cloudflared/blob/master/metrics/readiness.go)。这些是源码级能力，不能等同于有稳定兼容承诺的公开管理 API；实施阶段必须固定验证的 release/tag 或 commit，并保存对应响应 fixture。

由此推导：**对具备这些端点的版本，远程托管隧道也有机会直接读取本机已应用的配置，无需先拿 Cloudflare API Token。** 这需要真实版本实验验证，不能承诺覆盖所有安装方式。

### 3.2 场景矩阵

| 场景 | 首选发现方式 | 第一版承诺 |
|---|---|---|
| 本机 Quick Tunnel：`cloudflared tunnel --url http://localhost:3000` | `/quicktunnel` 获取随机域名，`/config` 获取目标；必要时以明确的 `--url` 补充目标 | 端点可读且目标唯一可匹配时展示域名及状态 |
| 本机本地托管命名隧道 | `/config` 获取实际运行 ingress | 不依赖磁盘 YAML 与运行配置同步 |
| 本机远程托管命名隧道，使用 `--token` / token 文件 | `/config` 获取已下发的 ingress | 不读取、解码或复用运行 token |
| 自定义 metrics 地址 / 随机端口 | 从 cloudflared 所属 TCP LISTEN 记录发现 | 不依赖固定端口 |
| root / 其他用户运行的连接器 | 仅使用当前权限能确认的进程与监听信息 | 若缺少可信身份或可访问端点，显示“权限或信息不足” |
| Docker/VM 中运行 cloudflared | 网络命名空间不同，宿主机 PID 通常不是 cloudflared | 第一版不自动归因；后续专门适配 |
| 只做私网路由，没有公开 hostname | 可识别连接器，但没有公开域名映射 | 不制造域名，不给业务端口挂虚假标签 |
| 隧道运行在另一台机器 | 本机没有连接器证据 | 第一版不支持自动发现 |
| 旧版接口缺失、禁用或结构不兼容 | 能力探测失败 | 明确“域名映射不可读取”，不把未知写成未配置 |

Quick Tunnel 的临时域名由 Cloudflare 分配，不能从 `--url` 反推。[来源：Quick Tunnels](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/)

### 3.3 后续降级方式

1. **本地配置文件**：只读取已确认的 `--config` 路径或用户指定文件。使用完整 YAML parser，保留规则顺序、hostname、path；不使用正则拼凑解析。磁盘文件只能标记“配置中声明”，不能证明已生效。仅在这一阶段评估增加 YAML 依赖。
2. **可选 Cloudflare API**：用户主动配置 account ID、tunnel ID 和只读 API Token 后，读取 `GET /accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations`。使用账号范围的 Tunnel Read 或等效 cloudflared Read 权限；密钥放 Keychain，不使用运行 token 替代 API Token。[来源：Get Tunnel configuration](https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/subresources/configurations/methods/get/)
3. API 返回的是云端期望配置，需区分“云端配置”与“本机已应用”；没有本机连接器绑定时不能宣称当前 Mac 正在转发。账号级健康状态也不能覆盖本机实例状态。
4. 第一版不读取终端输出、系统统一日志或任意日志文件；这些来源可能不可访问且容易混入其他会话或密钥。也不自动执行 `cloudflared tunnel list/info`，避免引入账号认证和额外网络访问。

### 3.4 用户环境验证记录（2026-11-05）

以下为用户在 Mac mini 终端执行并提供的结果，尚未由应用代码复现。域名使用示例替换，connector ID 不落盘。

| 请求 / 操作 | 实际结果 | 能确认的事实 |
|---|---|---|
| 直接执行 `cloudflared` | `unable to find config file` | 这次调用未找到配置，不代表后台连接器没有运行 |
| `pgrep -x cloudflared` | 返回一个 PID | 存在同名进程；PID 不是 HTTP 端口 |
| 对该 PID 执行普通权限的 TCP LISTEN `lsof` 查询 | 无输出 | 本次查询未取得监听归属，原因尚未确认 |
| `127.0.0.1:20241/ready` | `status: 200`、`readyConnections: 4`、非空 connector ID | 本地端点报告连接器就绪，存在 4 条边缘连接 |
| `127.0.0.1:20241/config` | `version: 5`，三条具体 hostname ingress 及末尾 `http_status:404` | 可直接读取运行映射，无需找到磁盘配置文件；5 是配置版本，不是 cloudflared 软件版本 |
| `127.0.0.1:20241/quicktunnel` | `hostname` 为空字符串 | 未提供临时域名；应使用 `/config` 中命名域名，不视为整个发现失败 |

已观察的目标结构为 `home-agent.example.com → 127.0.0.1:8080`、`jupyter.example.com → 127.0.0.1:9173`、`ip-please.example.com → 127.0.0.1:9001`，三条规则均无 path 限制。末尾 catch-all 不对应业务端口。

这验证了**当前用户环境中本地接口读取可行**。尚未验证：cloudflared 软件版本与启动模式、HTTP 监听者和上述 PID 的绑定、三个业务端口当前是否监听、应用自动匹配及公网端到端可用性。仅凭该响应不能断言隧道由本地文件还是云端托管。

实施时必须覆盖“进程枚举/监听归属不可见，但本机 HTTP 端点可读”的情况。第一版允许用户手动指定本机 metrics 端点进行诊断；归属未确认时展示“端点可读，进程归属未确认”，不伪造已经验证的 PID 关联，也不因一次 `lsof` 空结果就断言隧道没有运行。

## 4. 发现与关联流程

### 4.1 发现连接器和 HTTP 服务

1. 在成功取得的端口快照中找到可确认可执行文件为 `cloudflared` 的进程；名称仅用于候选筛选，结合可执行路径及 `ProcessIdentity` 验证。
2. 收集这些进程拥有的 TCP LISTEN 端点并去重。优先使用已确认的 `--metrics` 地址；端口归属证据仍需来自当前进程。
3. 对候选端点做有界的 `/ready`、`/config`、`/quicktunnel` 能力探测。失败候选不扩大为全机端口扫描；无法确定时返回不可识别原因。
4. 仅请求回环地址或明确属于本机的接口地址；通配监听转换为可连接的本机地址。禁止向 `0.0.0.0` / `::` 直接发送请求。IPv4、IPv6 分别处理。
5. 请求前后复核进程启动身份及监听归属。变化时丢弃结果，下次发现重新绑定。
6. 不展示原始 HTTP 响应；解析为白名单字段，响应中其他配置立即丢弃。

该过程提供普通桌面诊断所需的归属检查，不构成对抗同用户恶意程序的原子身份认证。

### 4.2 解析域名与目标

- 以同一连接器的运行配置为首选；若是 Quick Tunnel，则组合 `/quicktunnel` 的 hostname 与该实例唯一的服务目标。
- 保存 ingress 顺序及原始 path 正则。标记被前置规则完全遮蔽的确定性情形；无法判定重叠时写“受规则顺序限制”，不宣称所有请求都会抵达该服务。
- 同一端口允许多个 hostname，同一 hostname 允许按 path 指向多个端口；一个连接器可服务多个端口。
- `http_status:*`、`hello_world`、无 hostname 的 catch-all、Unix socket 不关联 TCP 端口。Unix socket 支持另列后续范围。
- `*.example.com` 作为通配规则显示，不当成可直接打开的 URL。path 是正则，不能直接拼接到浏览器 URL。
- Quick Tunnel 的 hostname 为空或格式错误时保留“域名未知”；不能借用另一连接器的域名。

### 4.3 匹配本机监听记录

匹配键至少包含网络命名空间、传输协议、地址族、目标地址与端口；PID/启动身份用于绑定当次目标记录。第一版网络命名空间只支持宿主机。

| 目标 | 匹配规则 |
|---|---|
| `http://127.0.0.1:3000` | 匹配 IPv4 回环或涵盖该地址的 IPv4 通配监听，端口为 3000 |
| `http://[::1]:3000` | 匹配 IPv6 回环或涵盖它的 IPv6 监听，不无条件与 IPv4 视为等价 |
| `http://localhost:3000` | 作为本机回环候选集合处理；若 IPv4/IPv6 对应不同进程则保留多个候选并标记歧义，不任选一个 |
| `http://192.168.1.10:3000` | 先确认该 IP 属于本机接口，再按地址族和监听覆盖关系匹配 |
| `http://localhost` / `https://localhost` | 按协议补全默认端口 80 / 443 |
| `tcp://`、`ssh://` 等 | 后续扩展；第一版可展示配置摘要，但不提供 HTTP 打开动作，不按未验证的协议默认值猜测端口 |
| 其他主机名、容器服务名或远程 IP | 第一版不解析为本机应用；标记不支持或非本机目标 |

端口数字相同不代表同一个监听者。多个进程共享监听或目标有歧义时保留候选和说明，不把关联伪装成唯一进程归属。目标是本机 Nginx/Caddy 时，只关联其直接监听端口，不递归猜测后面的应用。

原有“仅本机 / 同一网络可能访问”描述反映 socket 监听范围，继续保留；旁边独立补充“另有 Cloudflare 域名映射”，避免回环监听给用户造成没有公网入口的错觉。

## 5. 数据结构与并发边界

建议新增下列类型，具体 Swift 签名在实现时确定：

| 类型 | 关键内容 |
|---|---|
| `TunnelConnector` | 完整进程身份、metrics 端点、connector ID（可选）、tunnel ID（可选）、版本与能力集合 |
| `TunnelRoute` | 连接器引用、hostname、path、规则顺序、目标协议/地址/端口、配置版本与证据来源 |
| `TunnelAssociation` | route 与监听目标的对应关系、目标启动身份、匹配结果及歧义原因 |
| `TunnelHealth` | `connected`、`disconnected`、`unknown`，连接数、观测时间、错误原因；过期作为独立新鲜度字段 |
| `TunnelSnapshot` | connectors、routes、associations、采集时间、完整性及各来源诊断；成功空结果与采集失败分开 |
| `CloudflareTunnelDiscovering` | 异步发现/刷新与取消协议，注入进程读取器和 HTTP client 便于测试 |
| `CloudflareTunnelService` | actor 隔离的生产实现，负责能力探测、缓存、超时、取消及匹配 |

所有跨隔离数据满足 `Sendable`。HTTP 和文件 I/O 留在 Service；View 只读取展示状态。不要让隧道关联覆盖 Docker/Homebrew 所有权，更不能因此改变结束进程的操作对象。

数据流：

```text
PortQueryService → PortSnapshot → PortViewModel 应用端口快照
                                      ↓ 调度独立、可取消的发现任务
                          CloudflareTunnelService
                                      ↓ TunnelSnapshot
                        PortViewModel 保存隧道状态 / revision
                                      ↓
                 主窗口与菜单栏共享域名、状态和更新时间
```

- 端口查询成功后先展示端口，再调度隧道查询；HTTP 失败不改变端口快照的 `isPartial`，也不阻塞 `.fresh` 安全校验。
- 隧道结果携带启动身份及请求代次；晚到结果必须重新与当前监听者匹配。旧代次不能覆盖较新数据。
- `PortViewModel.stop()`、关闭功能及应用退出取消所有隧道任务；暂停自动刷新时同步暂停隧道轮询，手动刷新可绕过缓存。
- 使用独立 `tunnelRevision`；主窗口和菜单栏的域名搜索/排序缓存同时依赖两个 revision。纯健康状态变化无需重算端口归组、活动历史或连接数量。
- 不将健康时间戳写进 `PortRecord`，避免每次探测都触发所有端口内容变化。分组 ID 保持稳定，选中状态不因隧道重连而丢失。

## 6. 刷新与失败语义

以下为第一版建议参数，应在原型实测后调整，不视为已测性能：

- 发现候选随端口快照更新；状态探测前台最短 5 秒，后台最短 30 秒，同一连接器 single-flight。
- 运行配置和能力缓存 30 秒；新进程、metrics 端点变化、手动刷新时失效。缓存键至少含完整进程身份与端点，不能只用 PID。
- 单请求超时 1 秒、响应上限 1 MiB、全局并发最多 4、每轮总预算 3 秒。超时或超限必须实际取消请求并释放读取资源。
- 持续失败按 5/15/30/60 秒退避；无候选时不产生 HTTP 请求。大规模候选采用轮转预算，不让后面的实例长期饥饿。
- 显示观测时间。超过 `max(60 秒, 2 × 当前计划探测间隔)` 未成功刷新后，状态转为“数据已过期”，保留最后观测信息。

| 证据 / 事件 | 展示语义 |
|---|---|
| `/ready` 返回符合约定的 200 且 readyConnections > 0 | 本机隧道已连接 |
| `/ready` 返回符合约定的 503 且 readyConnections = 0 | 本机隧道未连接 |
| 超时、拒绝访问、404、结构未知、响应超限 | 状态未知，并显示原因；保留可识别的映射 |
| 完整可观察快照确认原连接器退出 | 清除当前有效关联；选中详情可保留“连接器已退出”的历史说明 |
| 部分/失败快照暂时没有该进程 | 不凭缺失判定退出；旧关联标为无法复核，随后过期 |
| 配置读取失败但连接器仍就绪 | 可显示连接器已连接，域名映射未知/旧数据，不误报没有映射 |
| 业务监听进程退出 / 被新进程占用 | 原目标关联失效；按最新目标重新计算，不继承旧进程身份 |

配置读取和就绪探测并非同一事务；记录各自观测时间，不承诺某次请求已经通过这条路由。

## 7. 界面与交互

### 主窗口

- 在现有“应用/服务”单元格增加可选的紧凑一行：`Cloudflare · dev.example.com · 已连接`；无关联时不占额外高度。
- 归组行包含多个目标时展示首个域名和 `+N`，详情按本机端口分组列出全部映射。混合健康状态时显示“部分连接 / 状态不一”，不以第一条替代全部。
- 详情增加“Cloudflare Tunnel”区域：域名、path 条件、直接目标、连接器、本地连接状态、信息来源及观测时间。技术字段默认收起。
- 提供复制域名；只有具体、有效的 HTTP(S) hostname 才提供用户点击的“打开域名”。源站 `https://` 不代表公网入口使用同一协议，公开访问动作按 Cloudflare HTTP 应用入口处理。
- 搜索支持域名，保留 `:3000` 精确端口语义。增加可选“有 Cloudflare 映射”筛选；仅有过期证据的结果必须带过期提示。
- 使用文字与图标共同表达未知、断开、过期，不仅靠颜色；新增文案同步更新中英文 `Localizable.strings` 和本地化测试。

### 菜单栏与设置

- 菜单栏记录显示首个域名及简短状态，点击沿用现有定位主窗口逻辑；完整映射在详情查看。
- 设置增加“检测本机 Cloudflare Tunnel”，建议默认开启，只执行本机只读探测；关闭后取消请求并清理当前关联。
- 第一版不提供创建、启动、停止、重启或修改隧道的动作，也不要求填写 token。可在无法读取时说明原因，避免反复弹窗。

## 8. 安全、隐私与产品边界

- 不读取环境变量、凭据 JSON、`cert.pem`、token 文件内容，不把 `--token` 当解析输入。现有脱敏 argv 也不能作为完整可信配置；新增提取仅输出非敏感白名单字段。
- HTTP client 仅访问已验证的本机端点；禁止重定向、系统 HTTP 代理转发和持久化缓存，不向其他地址发送本地配置或认证信息。
- 域名/目标 URL 校验 scheme、hostname、端口，剔除 userinfo；不记录 URL 查询中的敏感值。不请求 `/debug/*`、堆栈或完整诊断包。
- 仅在内存保存必要字段，不记录原始配置、完整命令行或响应正文；日志只保留脱敏错误类别和必要计数。
- 本轮不主动请求公网域名。后续若增加访问检查，由用户触发并单独展示 DNS/TLS/HTTP 结果；Access 登录跳转、401/403 不能直接等同于隧道断开。
- 新功能上线时更新 README 对本地数据处理的说明；未来 API 功能启用时必须说明向 Cloudflare 发出的请求及 Keychain 凭据存储。
- 结束进程、停止 Docker/Homebrew 服务仍走现有身份复核与确认流程；隧道证据不作为危险操作授权或完整性依据。

## 9. 实施阶段与产物

### 阶段 0：验证本地端点（实施前置门槛）

- 使用自建本机 HTTP 服务，分别运行 Quick Tunnel、本地托管命名隧道、远程托管 token 隧道；真实命名隧道实验需要拥有者提供测试账号与域名。
- 验证 `/config`、`/quicktunnel`、`/ready` 的结构，以及配置更新、启动未就绪、断网、重启、IPv6、定制端口时的行为。
- 至少覆盖当前稳定版和一个较旧的常用版本；保存版本/commit、脱敏 fixture、支持矩阵及失败路径。
- 验证 Foundation 对本机 HTTP 的 ATS/网络配置要求，按最小范围配置；不以全局允许任意 HTTP 解决问题。
- 产物：版本兼容记录、fixture、本地匹配原型。若端点不能覆盖某场景，明确下调支持范围并采用第 3.3 节后续方案。

### 阶段 1：服务与领域模型

- 新增 `Models/CloudflareTunnel.swift`、`Services/CloudflareTunnelDiscovering.swift`、`Services/CloudflareTunnelService.swift`；可按实际复杂度拆分纯解析/匹配文件。
- 完成可信候选发现、能力探测、HTTP 上限、运行配置解析、多对多匹配、身份复核及失败降级。
- 使用 Fake HTTP/进程读取器验证，不依赖真实账号运行单元测试。

### 阶段 2：共享状态与界面

- 在组合根注入服务；全局 ViewModel 管理隧道任务、快照、新鲜度及 revision。
- 接入主窗口、逐端口详情、菜单栏、域名搜索、筛选与功能开关；补齐本地化及可访问性文案。
- 验证端口表分组、选择恢复、统计、刷新性能和原有结束进程行为。

### 阶段 3：验收与文档

- 按下表执行测试和真实环境验收，记录支持版本与限制，更新 README。
- 本地方案验收后再评估 YAML、只读云 API、Docker/VM、多种 TCP 服务及用户触发的公网访问检测；不将这些作为第一版的隐含承诺。

## 10. 测试与完成标准

| 范围 | 必须覆盖的行为 |
|---|---|
| 解析 | Quick hostname 空值/错误值、未知字段、畸形/超大 JSON、无 ingress、多个 hostname/path、catch-all、通配域名、规则顺序 |
| 匹配 | IPv4/IPv6、localhost 歧义、默认端口、不同地址相同端口、共享监听、多端口归组、多隧道映射同一端口、远程目标及容器服务名不误匹配 |
| 健康状态 | 200/503、404、超时、连接拒绝、配置读取失败但 ready 成功、旧结果过期、无流量仍识别 |
| 归属与安全 | PID 复用、进程重启、候选端点换主、部分端口快照、响应晚到、禁用功能、重定向/代理禁用、密钥不进入模型和日志 |
| 并发 | single-flight、手动刷新、预算/并发上限、取消释放请求、失败退避、旧代次不覆盖新快照、主窗口/菜单栏共享请求 |
| UI | 只改健康状态即可更新、域名搜索缓存失效、归组详情端口不串联、状态不一、过期说明、选择不跳动、中英文本和 VoiceOver |
| 回归 | 端口数/连接数不因附加域名变化，`.fresh` 不等待 HTTP，原有危险操作身份校验保持有效 |

第一版完成必须满足：

- [ ] 已发布明确的 cloudflared 版本支持矩阵，具备真实响应 fixture。
- [ ] 无账号/无 API Token 时，支持范围内的 Quick 与命名隧道可正确关联本机 HTTP(S) 监听端口。
- [ ] 无流量可识别；一端口多域名、同应用多端口及 IPv4/IPv6 歧义不会错误归因。
- [ ] “本机已连接”“映射未知”“状态未知”“数据过期”具有独立可验证的语义，界面不把它们写成公网健康。
- [ ] 没有 cloudflared 时不产生 HTTP 轮询；有连接器时遵守预算，失败不延迟端口显示或阻塞进程操作。
- [ ] 主窗口与菜单栏共享结果；暂停、关闭功能及退出能取消任务。
- [ ] 新增行为测试与既有 XCTest 通过，Swift 6 构建及静态分析无新增并发问题。
- [ ] 实测并记录启用前后刷新耗时、CPU 与请求数量，未出现持续轮询堆积或明显能耗回退。

## 11. 第一版实施记录（2026-11-05）

### 已实现

- `CloudflareTunnel.swift`：白名单 JSON 解析、运行映射与健康状态、规则遮蔽、HTTP(S) 默认端口、IPv4/IPv6 回环匹配、多端口归组关联及过期计算。
- `CloudflareTunnelService.swift`：可注入的 HTTP/进程读取协议、actor 缓存与 single-flight、每轮最多四个连接器、三次各一秒的有界 HTTP 请求、失败退避、取消及启动身份/监听归属复核。HTTP 禁止代理、重定向、持久缓存和认证凭据存储，响应上限 1 MiB，规则上限 1,024 条。
- 自动发现只使用 cloudflared 所属的回环或通配 TCP 监听端点。无法看到监听归属时，设置允许显式指定一个回环 HTTP 诊断端点，并持续显示归属未确认。不会盲扫固定端口。
- `PortViewModel` 独立调度隧道任务，端口先显示；主窗口与菜单栏共享域名状态，刷新不会阻塞 `.fresh` 安全查询。支持域名搜索、“有 Cloudflare 映射”筛选、逐端口详情、复制/打开具体域名及中英文本。
- 设置开关取消任务并清理当前结果；手动诊断端点验证不接受远程地址、路径、userinfo 或 query。自动轮询随端口刷新进行，前台最短 5 秒、后台最短 30 秒；手动刷新绕过缓存。

### 已获得的验证证据

| 环境 / 场景 | 结果与限制 |
|---|---|
| 用户 Mac mini 的现有命名域名映射 | 用户提供的真实输出验证了 `/ready`、`/config` 和空 `/quicktunnel`；软件版本、托管模式和 PID 归属尚未确认，不能当成应用自动发现已验证 |
| 本次执行环境：macOS 27.0.1、arm64，cloudflared 2026.10.7 | 临时 Quick Tunnel 实测 `/ready` 200、非空 Quick hostname、未指定 hostname 的运行 ingress，配置版本为 -1。测试仅暴露固定测试文本；结束后隧道和源站均已关闭 |
| 应用本机 HTTP fixture | 实际设置中读取成功；主窗口搜索 `demo.example.com` 返回对应本机端口，详情正确显示域名、目标、连接状态、归属未确认及公网未检测。测试设置已恢复，临时服务已关闭 |
| 真实 URLSession HTTP 测试 | 本机 JSON 请求可用，无需开启全局任意 HTTP；验证不跟随重定向、Content-Length 与流式响应大小限制及超时 |
| Swift 编译 | arm64 和 x86_64 的 macOS 15 部署目标构建通过；并非在 macOS 15 / Intel 实机运行 |
| XCTest / 静态分析 | 最终串行执行 117 项测试全部通过，Xcode analyze 通过；新增 19 项隧道行为测试及 1 项本地化测试。此前并行执行中既有的 100ms 取消时序测试出现一次未及时取消，未改动其生产实现 |

`CloudflareTunnelTests.swift` 包含解析、匹配、服务缓存/取消、共享 ViewModel 及真实本机 HTTP 测试；命名域名 fixture 使用合成示例域名，未保存用户完整配置、connector ID 或密钥。

### 当前边界与后续项

第一版支持范围收敛为宿主机 HTTP(S) 回环源站；第 4.3 节的本机 LAN IP 匹配需增加接口归属验证后再开放。当前不提供 YAML/API 降级、远程采集、Docker/VM 命名空间映射或非 HTTP TCP 服务归因。

真实端点结构目前仅确认 2026.10.7（Quick）以及用户提供但版本未知的命名隧道；旧版本兼容矩阵、实际命名隧道的应用自动归属、macOS 15 / Intel 实机及长期 CPU/能耗基准仍待补充。不能把上述证据扩大为全部安装方式或公网端到端可用性已验证。
