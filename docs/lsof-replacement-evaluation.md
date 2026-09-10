# lsof 替换收益评估

> 后续已实施，生产代码结果与验证边界见 [原生端口采集实施记录](native-port-collection.md)。本文保留替换前的评估与原型数据。

评估日期：2026-09-10。项目基线：`4fd7dbf`。结论：**值得实现原生采集后端，优先级中等；先补齐数据覆盖并做双后端对照，再切换默认值，保留 lsof 回退。**

## 本机实测

环境为 macOS 26.6.2、Apple Silicon、普通用户权限，约 1,074 个进程。原生原型使用 SDK 中的 `proc_listallpids`、`PROC_PIDTBSDINFO`、`PROC_PIDLISTFDS` 和 `PROC_PIDFDSOCKETINFO`，以 C `-O2` 编译。它只用于评估，尚不是满足 `PortQuerying` 契约的生产实现。

每组预热后交替运行两个采集器，各 30 次；P95 使用 nearest-rank 算法。后台网络活动会变化，记录数是中位数。

| 场景/口径 | lsof 中位数 | 原生原型中位数 | lsof P95 | 原生 P95 |
|---|---:|---:|---:|---:|
| 日常环境，约 113 条 TCP/UDP 记录 | 50.620 ms | 1.737 ms | 52.524 ms | 1.979 ms |
| 增加 800 个回环 socket，约 913 条记录 | 53.149 ms | 3.050 ms | 58.467 ms | 3.523 ms |
| 日常环境的采集 CPU 时间 | 48.433 ms | 1.736 ms | 50.226 ms | 1.980 ms |

口径说明：lsof 耗时包括进程启动、查询和输出传输，不包括 Python 对比程序解析输出的时间。原生列是在原型进程内部测量的枚举与格式化时间，不包括启动原型进程和 stdout 传输，也没有包含 Swift `PortRecord` 构造及后续展示处理。**这展示的是采集阶段的优化空间，不能解释为整个应用快 17–29 倍。**

为提供启动口径相同的参照，原生原型作为独立进程运行时，中位数分别为 **4.272 ms / 5.898 ms**，仍明显低于 lsof 的 50.620 ms / 53.149 ms。首个未预热的原型进程启动耗时约 516 ms，而内部扫描仅 1.828 ms；此启动异常未纳入稳态统计，原因未测定，不能用本报告推断冷启动收益。

原始汇总数据：[results.json](benchmarks/lsof-native/results.json)。没有保存真实进程名、PID 或连接地址的逐条快照。

## 对整个应用的实际影响

直接将项目的 Models、Services、Localization 源文件与小型 Swift harness 一起以 `-O` 编译，测量现有 `LsofService.query` 从开始到返回的时间。每种模式 12 次，下面中位数排除首次调用，剩余 11 次。

| 当前服务模式 | 查询及解析中位数 | 完整返回中位数 | 每次后处理耗时的中位数 |
|---|---:|---:|---:|
| 元数据命中缓存 | 51.629 ms | 51.759 ms | 0.131 ms |
| 强制刷新元数据 | 50.577 ms | 52.781 ms | 2.306 ms |
| 开启服务识别，命中缓存 | 51.162 ms | 52.100 ms | 0.966 ms |
| 开启服务识别，强制刷新 | 50.526 ms | 60.084 ms | 9.342 ms |

“后处理耗时”对每次的完整耗时减查询耗时后取中位数，不等于两列中位数之差。服务数据见 [service-results.csv](benchmarks/lsof-native/service-results.csv)。

本机有 Homebrew 和 Docker CLI，但没有可用的 Docker 本地 socket。因此服务识别测试覆盖实际 Homebrew 查询，**没有覆盖运行中 Docker 的 inspect 耗时**，也没有模拟服务管理器超时。

当前 `LsofClient.swift` 的 `duration` 在元数据补全和服务识别之前就计算完成，UI 展示的耗时低于完整查询时间。建议迁移时明确区分 `collectionDuration`、`enrichmentDuration` 和 `totalDuration`。

实际收益分为：

- **减少周期性 CPU 消耗**：按本机采集 CPU 中位数差约 46.7 ms 推算，固定每 3 秒一次可减少约 1.56 个百分点的单核 CPU 时间；每 30 秒约 0.156 个百分点。这个计算只适用于本次采集成本，不是整机 CPU 或电池续航测量。
- **降低手动刷新延迟**：采集部分可减少约 49 ms，但当前约 52 ms 的缓存查询本身已经较快，体感提升有限。生产原生后端的完整时间需要另测。
- **为更频繁刷新留出空间**：如将来需要每秒刷新，减少轮询成本更有价值。当前已有前台 3–10 秒、菜单栏 5–15 秒、默认后台 30–60 秒的自适应间隔，因此替换不是紧急性能修复。
- **结束进程的体验提升有限**：当前发送信号后固定等待约 1.5 秒或 0.5 秒，再验证端口。减少几十毫秒的采集时间不会消除这个主要等待。

## 数据一致性与明确的缺口

使用“lsof → 原生 → lsof”采样，只比较前后两次 lsof 都存在的记录，尽量排除真实连接变化。匹配字段为 PID、FD、协议、IP 类型、本地与远端端点、TCP 状态；未比较用户名、可执行路径、启动时间等后处理字段。

| 检查项 | 结果 |
|---|---|
| 10 个自建 socket：IPv4/IPv6 的 TCP 监听、两端已建立连接、UDP 绑定和已连接 UDP | 两者全部匹配 |
| 本机稳定的普通 FD 记录 | 113 / 113 匹配 |
| 仅由 Mach fileport 持有的 TCP 监听 socket | lsof 查到 1 条；原型查到 0 条 |

最后一项是实测反例，结果见 [fileport-result.json](benchmarks/lsof-native/fileport-result.json)。不能把“普通 FD 的 113 / 113”当作完整覆盖证明。原生实现还需要 `PROC_PIDLISTFILEPORTS` 和 `proc_pidfileportinfo`，并为 fileport 建立不与普通 FD 冲突的稳定标识。lsof 的 Darwin 实现已有这条分支。[lsof fileport 实现](https://github.com/lsof-org/lsof/blob/master/lib/dialects/darwin/dproc.c)

第一次原型还出现了 5 条 CLOSED socket 地址不一致：不能只用 `insi_vflag` 选择 IPv4/IPv6 地址联合体，需要首先尊重 socket family。修正后上述普通 FD 对照全部匹配。这说明地址归一化、IPv4 映射地址和状态变化都应进入迁移测试。[lsof 地址处理](https://github.com/lsof-org/lsof/blob/master/lib/dialects/darwin/dsock.c)

本机原型约 373 次读取返回权限相关错误，说明直接调用原生 API 不会自动扩大数据可见范围。需要区分预期的其他用户不可见、进程正常退出、当前用户 socket 读取失败和缓冲区截断，不能全部静默忽略，也不能把所有预期权限限制都等同于“快照不可用”。[Apple proc_info 实现](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c)

## 工程成本与建议

macOS 的 lsof 本身也是 libproc 客户端，替换后继续读取相同类别的系统信息。收益来自针对产品需求简化枚举、减少通用处理及文本往返等；本测试没有分别归因这些成本，不能把约 49 ms 差值全部归因于进程启动。[lsof Darwin 采集实现](https://github.com/lsof-org/lsof/blob/master/lib/dialects/darwin/dproc.c)

| 维度 | 判断 |
|---|---|
| 原始采集性能 | 优化空间明显；补齐 fileport 等逻辑后需重新基准测试 |
| 新功能 | 收益有限；项目、命令行、启动身份已由现有原生 API 补全，Docker/Homebrew 仍需独立查询 |
| 权限与准确性 | 不会自动改善；需要显式建模不完整结果和权限边界 |
| 并发与取消 | 仍需实现 single-flight、`.fresh` 串行语义、协作式取消、缓冲区扩容与资源释放 |
| 维护成本 | 增加 socket 结构、地址族、fileport、PID/FD 复用以及 macOS 版本差异的回归责任 |
| 可删代码 | 不能直接删除整个 Process/Pipe 桥接；`LocalCommandRunner` 已复用它执行 Docker/Homebrew 命令 |
| 安全校验 | 保留现有发送信号前的 PID/启动时间核对；枚举和发信号仍非原子操作 |

推荐按以下顺序推进：

1. 在 `PortQuerying` 后新增 `DarwinPortService`，复用现有模型、元数据补全与服务识别；先保留当前默认后端。
2. 补齐普通 FD 与 fileport、IPv4/IPv6/映射地址、UDP、全部 TCP 状态，并明确快照完整性。将本次 CLOSED 地址差异与 fileport 反例固化为测试。
3. 对相同范围同时采样两种后端，比较稳定记录和字段；补测 macOS 15 与当前版本、Intel 与 Apple Silicon、受限进程、共享 socket、进程/FD 快速复用和大 FD 列表。双采样仅用于验证，避免长期抵消节能收益。
4. 达到覆盖要求后，让普通刷新默认走原生；原生明确失败或结果不完整时按策略回退 lsof。迁移初期，危险操作继续使用完整的 lsof `.fresh` 快照，并保留最终原生身份核对。成功但漏数据不会自动触发回退，因此先补齐覆盖是必要条件。
5. 用相同负载复测生产实现的完整耗时和 CPU。可将“缓存完整查询 P95 < 20 ms、可观察范围内无无法解释的稳定记录缺失”作为首轮工程目标；这些是建议验收目标，并非本次已经取得的生产指标。

## 复现

脚本与原型位于 [benchmarks/lsof-native](benchmarks/lsof-native)。以下命令在仓库根目录执行，将可执行文件和新结果写入临时目录，避免覆盖本次留档。使用普通登录用户，不能使用 sudo；运行环境若限制跨进程查询，应在具有正常用户权限的终端执行。

```sh
BENCH_DIR=$(mktemp -d /tmp/port-viewer-lsof-bench.XXXXXX)
cp docs/benchmarks/lsof-native/native.c docs/benchmarks/lsof-native/compare.py docs/benchmarks/lsof-native/fileport_fixture.py "$BENCH_DIR/"
/usr/bin/clang -O2 "$BENCH_DIR/native.c" -o "$BENCH_DIR/native"
python3 "$BENCH_DIR/compare.py"
python3 "$BENCH_DIR/fileport_fixture.py"
/usr/bin/swiftc -O -parse-as-library PortViewer/Models/*.swift PortViewer/Services/*.swift PortViewer/Localization/L10n.swift docs/benchmarks/lsof-native/ServiceBenchmark.swift -o "$BENCH_DIR/service-benchmark" -module-cache-path "$BENCH_DIR/module-cache"
"$BENCH_DIR/service-benchmark" > "$BENCH_DIR/service-results.csv"
```

负载只在回环地址创建 socket，退出时关闭；fileport 测试释放自己创建的 Mach send right。Swift harness 只读查询服务，不执行停止操作。本评估不包含生产后端替换。
