# 原生端口采集实施记录

2026-09-10。普通刷新已默认使用 Darwin/libproc；明确失败或不完整时回退 lsof。结束进程、停止托管服务相关的 `.fresh` 查询始终重新执行 lsof，仍保留发送信号前 PID、UID、启动时间的最终核对。

## 实现

- `PortQueryService` 管理跨后端 single-flight：普通请求共享正在运行的查询，fresh 请求串行等待后重新查询。取消不会触发回退；清理完成前禁止下一次查询启动，防止延迟取消影响新任务。
- `DarwinSocketReader` 使用 `proc_listpids`、`PROC_PIDTBSDINFO`、`PROC_PIDLISTFDS`、`PROC_PIDLISTFILEPORTS`、`proc_pidfdinfo`、`proc_pidfileportinfo`；只读取 TCP/UDP、IPv4/IPv6。
- 动态列表满载时扩容重试，每个列表不超过 16 MiB；原生采集有 5 秒协作式预算和 100,000 条网络记录上限。达到限制会报错或标为不完整并尝试 lsof。
- 扫描各进程后复核启动身份，PID 复用时丢弃该进程的结果并要求回退。后续元数据补全也不会把旧 socket 的启动身份替换成新进程身份。
- 其他用户的预期权限拒绝、进程/FD 消失分别计数；当前用户读取被拒绝、结构不匹配、无法解释的系统错误标为不完整。这里“完整”指普通用户权限下的可观察范围。
- 完整性不足时优先使用 lsof 的结果；若原生仅取得部分数据且 lsof 失败，普通刷新保留这份部分数据并显示提示。fresh 查询不接受这种降级，也不会以原生结果替代 lsof。
- 两个后端共享 `ProcessMetadataCache` 与 Docker/Homebrew 上下文。`PortSnapshot.duration` 包含采集与信息补全；diagnostics 分别记录阶段耗时、错误计数、来源与回退原因。技术详情显示实际来源与完整查询耗时。

原生 fileport 的编号是 `fp:<Mach port number>`，与普通 FD 分开。实测 lsof 的 `-F0` 输出只提供 `fp.`，没有 Mach 编号，因此双后端比对 fileport 时比较进程、协议、地址、端口、状态；切换来源后底层 fileport 行标识可能变化。危险操作的目标匹配不依赖该编号。

## 生产代码复测

macOS 26.6.2、Apple Silicon、普通用户，Swift 6 `-O`。启用实际 `ManagedServiceController`，各后端预热后交替采样 30 次。完整耗时从调用查询到收到快照；CPU 是当前基准进程及其子进程 CPU 时间之和。P95 使用 nearest-rank。

| 场景 | lsof 完整查询中位数 / P95 | 原生完整查询中位数 / P95 | 中位数减少 |
|---|---:|---:|---:|
| 常态，约 216 条记录 | 65.906 / 80.290 ms | 16.493 / 17.563 ms | 75.0% |
| 额外 800 个回环 socket，约 1,014 条记录 | 90.129 / 99.082 ms | 41.598 / 44.039 ms | 53.8% |

常态原生采集中位数 5.509 ms，补全 10.881 ms；负载下采集 9.409 ms，补全 31.591 ms。常态完整查询 CPU 中位数从 54.682 ms 降到 8.406 ms。收益主要是轮询成本下降；这不是 UI 帧率或电池续航测量。高负载下完整查询 P95 仍超过评估中建议的 20 ms，后续优化应首先剖析服务信息补全。

稳定记录对照采用“lsof → 原生 → lsof”，比较前后两次 lsof 都存在的记录，字段含 PID、FD、用户名、进程名、父 PID、协议、IP 类型、端点与 TCP 状态：常态 **214/214**，负载 **1015/1015**；两组均无稳定缺失或未解释的额外记录，60 次原生查询没有回退或部分结果。短暂连接数在采样之间会自然变化。

原始记录：[production-baseline.csv](benchmarks/lsof-native/production-baseline.csv)、[production-loaded.csv](benchmarks/lsof-native/production-loaded.csv)、[production-results.json](benchmarks/lsof-native/production-results.json)。初始 C 原型的历史评估保留在 [lsof-replacement-evaluation.md](lsof-replacement-evaluation.md)，不能把其中的原型数字当作生产完整查询速度。

## 验证与边界

- **97 项 XCTest 全部通过**，Xcode 静态分析通过。
- 实机自建 socket 对照包含 IPv4/IPv6 TCP 监听、已建立连接双方、共享 FD、未连接 TCP、绑定和已连接 UDP；另有仅由 fileport 持有的监听 socket 对照。测试只关闭自己创建的资源。
- 回归覆盖无地址标志的 CLOSED IPv4、IPv6 socket 使用 IPv4 地址、未知结构/状态、扩容上限、超时、PID 复用、权限拒绝、正常消失、fresh 路由、回退、查询共享、取消传播和取消清理隔离。
- 服务代码已通过 `x86_64-apple-macos15.0` 编译检查；**未在 Intel 或 macOS 15 实机执行**，也未进行沙盒/App Store 分发验证。
- 本机有 Homebrew；Docker CLI 存在但本地 Docker socket 不可用，所以未覆盖运行中容器的真实 inspect 耗时。两个后端都保留现有服务识别逻辑。
- 原生 API 不会扩大权限，不提供原子的全系统快照；正确返回但漏掉某种未知 socket 类型不会自动触发回退。macOS 升级时仍需运行实机对照。

## 复现

在没有并行构建或测试负载的普通用户终端执行；不使用 sudo。以下命令只向临时目录写入新结果，负载只创建回环 socket 并在退出时释放。

```sh
BENCH_DIR=$(mktemp -d /tmp/port-viewer-production.XXXXXX)
/usr/bin/swiftc -O -swift-version 6 -parse-as-library PortViewer/Models/*.swift PortViewer/Services/*.swift PortViewer/Localization/L10n.swift docs/benchmarks/lsof-native/ProductionBenchmark.swift -o "$BENCH_DIR/production-benchmark" -module-cache-path "$BENCH_DIR/module-cache"
python3 docs/benchmarks/lsof-native/production.py "$BENCH_DIR/production-benchmark" "$BENCH_DIR"
```

完整回归（本机 PATH 中有非 Apple linker，因此显式指定 clang）：

```sh
xcodebuild -project PortViewer.xcodeproj -scheme PortViewer -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/port-viewer-native-build CODE_SIGNING_ALLOWED=NO LD=/usr/bin/clang LDPLUSPLUS=/usr/bin/clang++ test analyze
```
