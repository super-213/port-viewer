# Port Viewer Apple 高级毛玻璃视觉风格规范

> 文档版本：v1.0  
> 文档状态：视觉改造基线  
> 更新日期：2026-07-23  
> 适用产品：Port Viewer macOS 原生应用与菜单栏面板  
> 技术基线：SwiftUI / Swift 6 / macOS 15.0+  
> 风格代号：**Precision Frosted Utility / 精密霜璃工具感**

## 1. 文档目的

本文档用于指导 Port Viewer 后续前端视觉精修。改造不是推翻当前设计，也不是把产品改成网页式 Apple 展示页，而是在保留现有 macOS 原生工具结构、信息密度和使用习惯的前提下，解决以下问题：

- 组件边缘过轻，控件与背景之间缺少清晰但精致的轮廓；
- 大量控件只使用系统默认外观，彼此虽然“原生”，但没有形成 Port Viewer 自身的质感；
- 颜色主要直接使用 `.blue`、`.green`、`.orange` 和 `.secondary`，语义正确但层次普通；
- 毛玻璃只在少数反馈栏出现，窗口缺少连续、可感知的材质层级；
- `Picker`、搜索框、链接按钮、标签和关系节点的视觉完成度不在同一水平；
- 当前多个组件依赖单层、低透明度描边，边缘在浅色和复杂背景上容易“消失”。

最终目标是让界面看起来像一款经过长期打磨的 macOS 专业工具：安静、可信、清晰，同时具备可感知的玻璃材质、精密边缘、细腻光影和克制的品牌色。

## 2. 与现有文档的关系

本规范是对以下文档中视觉章节的深化，不改变其中的产品功能、数据语义、安全逻辑与信息架构：

- `docs/requirements.md`
- `docs/beginner-friendly-visualization-prd.md`
- `docs/architecture-refactoring-requirements.md`

发生差异时按以下规则处理：

1. 产品行为、危险操作、数据忠实性、辅助功能以原 PRD 为准；
2. 组件颜色、材质、边缘、阴影、圆角和动效以本文档为视觉基线；
3. 保留 `NavigationSplitView`、原生 `Table`、系统菜单、系统 Alert 和 macOS 快捷键；
4. “自定义组件”主要指自定义视觉包裹层与状态样式，不重写系统已经可靠处理的菜单、焦点、键盘与 VoiceOver 行为；
5. 不依赖 macOS 26 专用视觉 API，当前 macOS 15.0 部署目标必须可实现完整降级效果。

## 3. 参考风格的吸收与取舍

本文档参考 `/Volumes/HIKSEMI/tool/agent/docs/006-frontend-apple-style-redesign-requirements.md`，但只吸收适合 Port Viewer 的部分。

### 3.1 直接吸收

- 安静、清晰、克制的 macOS 生产力工具定位；
- 系统字体、SF Symbols、语义状态色和短时动效；
- 顶部工具区、侧栏、浮层和弹窗使用毛玻璃材质；
- 阅读与数据区域保持稳定、清晰，不在正文后方放复杂动态背景；
- 浅色、深色、降低透明度、增强对比度和减少动态效果同时可用；
- 通过设计 token 统一颜色、间距、圆角、边缘与阴影；
- 不使用霓虹、扫描线、网格、持续发光、夸张缩放和营销页式布局。

### 3.2 调整后吸收

| 参考方案 | Port Viewer 的调整 |
|---|---|
| 使用极细描边 | 交互组件升级为“复合边缘”，不再依赖单条低透明度细线 |
| 系统蓝作为唯一主色 | 蓝色仍是主操作色，同时加入受控的靛蓝与青色光感，避免颜色单薄 |
| 常规区域不使用阴影 | 数据正文不使用悬浮阴影，但控件、关系节点和浮层允许使用低强度双层阴影 |
| 毛玻璃只用于少数承载面 | 仍限制真实 blur 的数量，但通过玻璃父层 + 半透明子层让材质语言更连续 |
| 默认系统控件 | 保留系统交互语义，对 Picker、按钮、搜索框和分段选择器定制可见外观 |

### 3.3 明确不采用

- React/CSS 专用实现和聊天产品页面结构；
- 深黑 OLED 背景、绿色 CTA、Fira 字体与开发者终端风；
- Bento 营销卡片、横向滚动叙事、巨型标题和 3D 展示；
- 大面积高透明玻璃导致文字穿透和对比不足；
- 彩虹液态玻璃、色差边缘、持续流动背景和多层动态模糊；
- 厚重拟物纹理、金属按钮、果冻形变和明显弹跳；
- 为追求“高级感”降低表格密度、牺牲扫描效率或破坏 macOS 习惯。

## 4. 当前视觉基线与保留项

### 4.1 必须保留的产品骨架

- 左侧范围导航 + 上方工具栏 + 中央列表 + 下方详情的主窗口结构；
- `Table` 的排序、选中、列宽和大量数据扫描能力；
- 菜单栏快速搜索、概况、记录列表和主窗口入口；
- 关系图的三段固定路径、节点解释和横纵自适应布局；
- 技术详情的渐进披露；
- 系统字体、SF Symbols、系统快捷键、VoiceOver 标签和减少动态效果支持；
- 危险操作继续使用原生确认框和系统 destructive 语义。

### 4.2 当前最值得延续的视觉细节

- 端口、PID、IP 等技术值使用等宽字体，普通文本使用系统字体；
- 状态同时使用图标、文字和颜色；
- 关系节点、端口芯片和指标徽标已经具备组件化基础；
- 菜单栏面板保持紧凑，不堆叠大卡片；
- 详情区域以解释为主、参数为辅，符合产品“先解释，再操作”的定位。

### 4.3 当前需要精修的具体位置

| 当前实现特征 | 视觉问题 | 目标处理 |
|---|---|---|
| 多处直接使用 `Divider()` | 分区准确但机械、平面 | 仅结构分隔保留 hairline；关键分区增加色差、内高光或阴影过渡 |
| Badge 使用 `0.7 pt` 单层描边 | 边缘偏弱，小尺寸下容易模糊 | 改为 1 pt 外轮廓 + 0.5 pt 内高光 |
| 关系节点使用单层 separator stroke | 节点像普通白色矩形 | 增加玻璃填充、复合边缘、顶部反光和双层轻阴影 |
| FilterBar 直接排列原生 Picker | 控件与高级毛玻璃方向不一致 | 使用统一 `PremiumPicker` 外观，保留系统 `Menu` 行为 |
| 多种 `.link/.plain/.borderless/.bordered` | 同层操作看起来来自不同设计系统 | 收敛为 Accent、Glass、Quiet、Danger 四类按钮 |
| 搜索框使用单层 `.quaternary` 背景 | 静态时缺少精确轮廓 | 改为可聚焦玻璃输入框，具有内高光、外边缘和 focus ring |
| 颜色直接使用系统色 | 语义正确但缺少明暗层与品牌气质 | 使用语义 hue + tonal fill + gradient accent，不直接散落原始色值 |

## 5. 视觉 thesis

> Port Viewer 应像一块嵌入 macOS 的精密网络观察仪：背景冷静，玻璃层轻盈，数据面清晰，控件边缘像经过精确切削；颜色来自低饱和环境光和高纯度状态点，而不是大面积彩色装饰。

第一眼应感受到：

1. **原生**：窗口结构、交互方式和排版属于 macOS；
2. **精密**：轮廓稳定，控件状态明确，技术信息对齐整洁；
3. **通透**：侧栏、工具区、筛选区和浮层有真实的前后层次；
4. **有色但克制**：蓝—靛蓝形成品牌光感，绿、橙、红只服务于状态；
5. **耐看**：连续使用一小时仍保持安静，不被持续动效和强烈高光打扰。

## 6. 核心设计原则

### 6.1 原生骨架，自定义表面

优先保留系统组件的行为，用自定义 `ButtonStyle`、`Label`、`Menu` label、容器 modifier 和 token 提升视觉。只有系统组件无法满足层级表达时，才创建完整自定义控件。

### 6.2 边缘是一组光学关系，不是一根线

高级感不来自把边框简单加粗，而来自：外轮廓、内侧高光、微弱内阴影、环境阴影和背景色差共同建立边界。交互控件默认不得只依赖一条透明度低于 20% 的描边。

### 6.3 毛玻璃用于建立层级

真实 blur 主要用于窗口 chrome、侧栏、筛选栏、菜单栏面板、popover 和反馈浮层。表格正文与长文本详情使用更实的表面，保证信息稳定可读。

### 6.4 色彩同时表达气氛与语义

蓝—靛蓝只表达品牌、选择和主要操作；绿、橙、红表达真实状态。背景允许极低透明度的冷色环境光，但不能让颜色替代边界和文字。

### 6.5 细节密度服从信息密度

关系节点、主要控件和浮层可以精细；表格行、技术参数和大段正文保持安静。不能给每一行数据增加独立卡片、重阴影或多色渐变。

### 6.6 状态稳定优先

刷新、筛选、展开和选中不引起布局跳动。hover 不缩放组件，pressed 不改变布局占位，动画关闭后仍然能看懂状态变化。

## 7. 层级模型

| 层级 | 名称 | 用途 | 视觉特征 |
|---|---|---|---|
| L0 | Canvas | 窗口最底层背景 | 冷灰蓝基底 + 极弱静态环境渐变，无阴影 |
| L1 | Chrome Glass | 侧栏、工具区、筛选轨道、菜单栏面板 | Material + 轻微冷色 tint + 复合边缘 |
| L2 | Content Surface | Table、长文本详情、设置正文 | 高不透明度、低噪声、清晰文字，不叠加真实 blur |
| L3 | Raised Control | Picker、搜索框、按钮、badge、关系节点 | 明确轮廓、顶部高光、轻内阴影、短距离阴影 |
| L4 | Floating Glass | Popover、菜单型筛选、反馈条、帮助浮层 | 更强 blur、更清晰外边缘、较大环境阴影 |
| L5 | Focus / Critical | 键盘焦点、当前选择、危险操作 | 2 pt focus ring 或红色语义，不能仅用颜色 |

同一区域最多出现两层真实 Material。玻璃父容器中的子控件使用半透明填充，不再次叠加 Material，以避免模糊发灰和渲染开销。

## 8. 设计 token

### 8.1 色彩 token

下列色值是视觉目标值。实现时集中定义动态颜色，不在业务 View 中散落 Hex 或直接使用 `.blue/.green`。

#### 中性色与表面

| Token | 浅色 | 深色 | 用途 |
|---|---|---|---|
| `canvas.base` | `#EEF2F7` | `#0D1118` | 窗口背景 |
| `canvas.top` | `#F8FAFE` | `#151B26` | 顶部环境渐变 |
| `canvas.bottom` | `#E7EDF5` | `#0A0E15` | 底部环境渐变 |
| `surface.content` | `rgba(252,253,255,0.94)` | `rgba(22,28,39,0.94)` | Table 与正文详情 |
| `surface.glass` | `rgba(255,255,255,0.66)` | `rgba(31,39,54,0.70)` | 玻璃 chrome 的 tint |
| `surface.control` | `rgba(255,255,255,0.72)` | `rgba(46,56,73,0.74)` | 控件默认填充 |
| `surface.controlHover` | `rgba(255,255,255,0.88)` | `rgba(60,72,92,0.84)` | 控件 hover |
| `surface.raised` | `rgba(255,255,255,0.90)` | `rgba(40,49,66,0.90)` | 关系节点与浮层内容 |
| `text.primary` | `#172033` | `#F4F7FC` | 标题和正文 |
| `text.secondary` | `#4F5C71` | `#B8C2D1` | 说明文字 |
| `text.tertiary` | `#6D798D` | `#929EB0` | 非关键元数据 |

#### 边缘与阴影

| Token | 浅色 | 深色 | 用途 |
|---|---|---|---|
| `edge.outer` | `rgba(62,78,103,0.30)` | `rgba(220,231,248,0.25)` | 控件和卡片外轮廓 |
| `edge.outerStrong` | `rgba(45,62,89,0.42)` | `rgba(232,240,255,0.38)` | hover、重要节点 |
| `edge.innerHighlight` | `rgba(255,255,255,0.82)` | `rgba(255,255,255,0.12)` | 顶部/内侧高光 |
| `edge.separator` | `rgba(60,75,96,0.17)` | `rgba(214,226,245,0.14)` | Table 与结构分隔线 |
| `shadow.near` | `rgba(20,30,48,0.10)` | `rgba(0,0,0,0.28)` | 近距离接触阴影 |
| `shadow.ambient` | `rgba(25,40,68,0.12)` | `rgba(0,0,0,0.36)` | 悬浮环境阴影 |

#### 品牌与状态色

| Token | 浅色 | 深色 | 说明 |
|---|---|---|---|
| `accent.primary` | `#1677FF` | `#5AA7FF` | 主操作、焦点、选择 |
| `accent.indigo` | `#5C66E8` | `#858CFF` | 主渐变终点、特殊选中层 |
| `accent.cyan` | `#159FBE` | `#4CCBE1` | 极少量连接光感，不作第二主色 |
| `state.waiting` | `#239B62` | `#45D087` | 等待连接 |
| `state.connected` | `#1677E8` | `#62AAFF` | 活跃连接 |
| `state.warning` | `#C87512` | `#FFB14A` | 权限、可能暴露、注意 |
| `state.danger` | `#D64650` | `#FF6B73` | 错误与破坏性操作 |
| `state.neutral` | `#667389` | `#97A4B6` | UDP、暂停、未知或结束 |

状态色需要生成三档 tonal variant：

- `foreground`：100% hue，用于图标和短文本；
- `fill`：浅色 8–12%、深色 12–18%，用于 badge 或选中底；
- `edge`：浅色 24–32%、深色 28–38%，用于边缘；

不得直接把高纯度状态色铺满大面积容器。

### 8.2 品牌渐变

品牌渐变只用于主要按钮、当前选中指示器和极小范围环境光：

- 浅色：`#2387FF → #596DFF`；
- 深色：`#55AAFF → #777EFF`；
- 方向：左上至右下，角度约 135°；
- 同一屏幕最多出现 2 个实体渐变组件；
- 不给普通标签、每个图标或每个列表行添加渐变；
- 渐变阴影透明度不得超过 10%，不能形成霓虹 glow。

### 8.3 圆角 token

| Token | 数值 | 场景 |
|---|---:|---|
| `radius.micro` | 5 pt | 小端口芯片、分支条目 |
| `radius.small` | 7 pt | 图标按钮、小 badge |
| `radius.control` | 10 pt | Picker、按钮、输入框 |
| `radius.node` | 12 pt | 关系节点、指标轨道 |
| `radius.panel` | 16 pt | 筛选玻璃栏、帮助浮层 |
| `radius.floating` | 18 pt | 自定义 popover 与大型浮层 |

嵌套圆角遵循 `内层圆角 = 外层圆角 - inset`，不混用大量 9、10、11、12 的近似值。

### 8.4 间距 token

继续使用 4 pt 基础网格：

- `space.1 = 4`
- `space.2 = 8`
- `space.3 = 12`
- `space.4 = 16`
- `space.5 = 20`
- `space.6 = 24`

控件内部横向 padding 以 10/12 pt 为主；区域间距以 16/20 pt 为主；只有空状态和大段说明使用 24 pt。

### 8.5 排版 token

继续使用 SF Pro / 系统中文字体，不引入网页字体。

| 层级 | SwiftUI 建议 | 用途 |
|---|---|---|
| Window Title | `.title2.weight(.semibold)` | 独立大标题，少量使用 |
| Section Title | `.headline` | 活动关系、技术详情等区域标题 |
| Control Label | `.callout.weight(.medium)` | Picker、按钮、节点标题 |
| Body | `.callout` / `.body` | 解释与正文 |
| Metadata | `.caption` | 更新时间、辅助解释 |
| Technical | `.system(.callout, design: .monospaced)` | 端口、PID、IP、FD |

数字指标使用 `.monospacedDigit()`；普通按钮和标签不使用全大写；大段说明不使用 `.tertiary` 颜色。

## 9. 复合边缘系统

### 9.1 默认控件边缘配方

每个可点击玻璃控件默认由四层组成：

1. **外轮廓**：1 pt `edge.outer`；
2. **内高光**：向内 inset 1 pt 的 0.5 pt `edge.innerHighlight`，高光主要集中在顶部与左上区域；
3. **接触阴影**：`y: 1, blur: 2`，使用 `shadow.near`；
4. **环境阴影**：`y: 5, blur: 14`，低透明度 `shadow.ambient`，仅用于 raised 组件。

视觉重点组件，如关系节点、主要 Picker 和浮层，外轮廓可提高到 1.25 pt。普通交互控件不得使用低于 1 pt 的默认外轮廓。

### 9.2 不同状态的边缘变化

| 状态 | 填充 | 外轮廓 | 阴影 | 其他 |
|---|---|---|---|---|
| Rest | `surface.control` | `edge.outer` | 基础 near shadow | 保持稳定 |
| Hover | `surface.controlHover` | `edge.outerStrong` | ambient 提升约 15% | 不缩放 |
| Pressed | 比 Rest 深/暗 4% | 外轮廓不变 | near shadow 缩短，ambient 降低 | 可下移 0.5 pt，不能改变布局 |
| Selected | accent fill 10–14% | accent 45–60% | 可有 6% accent wash | 同时显示 checkmark/文字 |
| Focused | 状态本身不变 | 外加 2 pt accent focus ring | 不使用 glow | focus ring 与外轮廓间隔 1 pt |
| Disabled | 不透明度 45–55% | 仍需可见 | 无 ambient | 文字保持可读 |

### 9.3 何时仍使用细分隔线

以下场景保留 0.5–1 pt separator，不升级为复合边缘：

- Table 行与列的结构分隔；
- 大面板内部的逻辑分组；
- 菜单栏 footer 与列表之间；
- 技术详情组之间；
- 指标轨道内部的竖分隔。

分隔线表达“同一平面内的结构”，复合边缘表达“可交互或不同材质的物体”。两者不能混用。

## 10. 毛玻璃与光影

### 10.1 Canvas Atmosphere

窗口背景使用 `canvas.top → canvas.bottom` 的静态垂直渐变，并允许在右上和左下各放一层 6–10% 透明度的蓝/靛蓝径向环境光。环境光必须满足：

- 不动画；
- 不穿透 Table 正文造成色偏；
- 面积大、边缘软、色彩低饱和；
- 深色模式降低面积并提高明度，不做纯黑背景；
- “降低透明度”开启时完全移除。

### 10.2 Chrome Glass

侧栏、筛选栏、菜单栏面板和窗口反馈条使用 SwiftUI `Material` 作为底层，再叠加 `surface.glass` tint。材质边缘需要 `edge.outer` 与顶部内高光，不能只显示 blur。

### 10.3 Content Surface

Table 和详情正文使用 `surface.content`，不叠加真实 blur。数据区域通过 2–4% 的明度差与 Chrome Glass 分离，而不是依赖厚边框。

### 10.4 Floating Glass

Popover、帮助浮层和复杂选择器面板使用：

- `.regularMaterial` 或视觉等价实现；
- `surface.raised` tint；
- 1.25 pt 外轮廓 + 0.5 pt 内高光；
- 双层阴影：`0/2/5` 近阴影 + `0/16/44` 环境阴影；
- 16–18 pt 圆角；
- 出现时 160–200 ms fade + 3 pt translate，不做明显缩放。

### 10.5 材质限制

- 不在每个 Table 行、每个技术字段和每个 badge 上创建独立 blur；
- 不叠加三层以上 Material；
- 不通过极低 opacity 伪装高级感，浅色玻璃正文承载面有效不透明度不得低于约 78%；
- 不使用噪点纹理覆盖文字；如需要极弱颗粒，仅能放在 L0 背景且透明度不超过 1.5%。

## 11. 组件规范

### 11.1 PremiumPicker：重点改造组件

当前原生 Picker 的交互应保留，但默认视觉需要替换为统一的玻璃选择器。

#### 外观

- 高度：紧凑 28 pt、默认 32 pt、突出 36 pt；FilterBar 默认 32 pt；
- 圆角：10 pt；
- 水平 padding：左 10–12 pt，右 9–10 pt；
- 字号：`.callout.weight(.medium)`；
- 左侧可选 14–16 pt SF Symbol，图标使用 secondary；
- 中间显示当前值，单行截断，宽度变化不推动相邻控件；
- 右侧 chevron 使用 9–10 pt semibold，置于 20 pt 的轻微 tonal well 中；
- 默认使用复合边缘，hover 时提升外轮廓和背景明度；
- 展开时保持 accent focus ring，chevron 可旋转 180°，时长 140–160 ms；
- 不能使用浏览器式矩形下拉框，也不能把系统箭头直接裸露在纯色背景上。

#### 行为选择

- 选项不超过 8 项、内容简单：使用 SwiftUI `Menu` 或 menu-style Picker，自定义 label；
- 选项较多、需要分组、解释或搜索：使用自定义 anchored popover；
- 多选筛选：使用 popover 列表 + checkmark，关闭后生成可移除 chip；
- 危险操作：使用系统 `Menu` 的 destructive role，不放入视觉复杂的自定义下拉；
- 菜单与 popover 必须支持方向键、Return、Escape、VoiceOver 和当前值朗读。

#### 菜单内容

- 每行高度 28–32 pt；
- 当前项使用 checkmark + 10% accent fill，不只改变文字颜色；
- hover 使用 8% primary fill；
- 标题与辅助说明分两级时，面板宽度 260–330 pt；
- 不在菜单项之间画完整卡片边框；分组之间使用 1 pt separator；
- 选择后立即生效的筛选不再额外放“确定”按钮。

### 11.2 GlassSegmentedControl

仅用于 2–5 个互斥、同级且高频的选项，不替代所有 Picker。

- 外轨高度 32 pt，圆角 10 pt，使用 `surface.glass`；
- 选中块使用 `surface.raised` + 1 pt edge + 小阴影；
- 选中块可有 8% 蓝—靛 tint，不使用实心高饱和蓝；
- 切换时使用 180–220 ms ease-out 或低弹性 spring；
- hover 不移动选中块；
- 支持左右方向键，VoiceOver 朗读“第 N 项，共 M 项”；
- 开启减少动态效果时直接切换选中块。

### 11.3 按钮

按钮收敛为四类：

| 类型 | 外观 | 使用场景 |
|---|---|---|
| Accent | 蓝—靛渐变、白色文字、清晰外边缘 | 主要确认或最重要动作，单一区域最多 1 个 |
| Glass | 玻璃填充、复合边缘、primary 文字 | 筛选、普通操作、带文字按钮 |
| Quiet | 透明或 6% tonal fill，hover 后显现边缘 | toolbar 图标、关闭、帮助、刷新 |
| Danger | 红色文字 + 8–12% 红色底 + 红色边缘 | 结束进程等破坏性动作 |

统一规则：

- 高度使用 28/32/36 pt 三档；
- icon-only 按钮可视尺寸最小 28×28 pt，建议 30–32 pt；
- icon 与文字间距 6 pt；
- hover 不缩放，pressed 可轻微降低明度并收缩阴影；
- disabled 仍保留轮廓与文本，不只降低到几乎不可见；
- Toolbar 中同时出现多个 Quiet 按钮时使用 6 pt 间距，不给每个按钮增加重阴影；
- 链接样式只保留给真正的导航/解释入口，不再用于普通操作按钮。

### 11.4 搜索框与文本输入

- 默认高度 32 pt，菜单栏紧凑场景可使用 30 pt；
- 圆角 10 pt；
- 左侧搜索图标与右侧清除按钮对齐到统一 16 pt 图标尺寸；
- Rest 使用 `surface.control` + 1 pt outer edge + 0.5 pt inner highlight；
- Hover 提升背景和边缘，不出现蓝色；
- Focus 使用 2 pt accent ring，并让搜索图标从 secondary 过渡到 accent；
- Placeholder 与正文保持至少一个清晰明度级差；
- 错误不能只显示红边，需要图标或说明文本；
- 选中文本、复制和系统输入法行为保持原生。

### 11.5 筛选 chip 与状态 badge

#### 筛选 chip

- 高度 24–26 pt，圆角 8 pt；
- 使用中性玻璃填充，选中条件可使用 8% accent tint；
- 1 pt outer edge + 顶部内高光；
- xmark 具有独立 18 pt 点击区域；
- hover 只突出 xmark 区域，不整体放大；
- 文案使用“仅这台 Mac”等完整语义，不使用缩写。

#### 状态 badge

- 使用对应语义色的 foreground/fill/edge 三档 token；
- 外轮廓从当前 0.7 pt 提升到 1 pt；
- 保持图标 + 数字/文字组合，不能只有颜色圆点；
- 同一行超过 3 个 badge 时优先合并信息，不继续堆叠；
- 红色只用于真实错误和危险状态。

### 11.6 Toolbar

- 保留 macOS 原生 titlebar/toolbar 结构；
- 暂停、刷新、设置使用统一 QuietButtonStyle；
- 当前刷新中可用 symbol effect 或轻量 spinner，但不持续旋转整个按钮背景；
- 搜索继续使用系统 toolbar placement，但输入面使用统一搜索 token；
- Toolbar 不增加网页式悬浮导航卡片；
- 窗口失焦时降低 accent 饱和度与阴影强度，保持文字清晰。

### 11.7 Sidebar

- 保留 `.listStyle(.sidebar)` 和系统导航行为；
- 背景使用 Chrome Glass，右侧通过色差和 1 pt separator 分区；
- 默认行不画卡片边框；
- hover 使用 6% primary tint；
- selected 使用 10–14% accent tonal fill + 1 pt 内边缘，可加 2 pt 左侧短标记，但不能做霓虹竖线；
- 图标使用 monochrome/hierarchical SF Symbols，不给每一项随机配色；
- 数量使用 `.monospacedDigit()`，放入极轻的 tonal capsule；
- 说明文字可保留两行，但 selected 时仍需达到足够对比度。

### 11.8 OverviewBar / Metric Rail

概况栏不改成三张独立 Dashboard 卡片，而是形成一条完整的玻璃指标轨道：

- 高度 48–52 pt；
- 外层使用 `surface.glass`、12 pt 圆角和复合边缘；
- 三个指标以内部 separator 分隔；
- 图标使用状态色，数字使用 primary + monospacedDigit，标签使用 secondary；
- hover 单个指标时只改变该 cell 的 5–7% tonal fill；
- “什么是端口？”作为 Quiet/Link 入口置于轨道尾部；
- 更新时间属于元数据，不与指标竞争视觉权重。

### 11.9 FilterBar

- 将筛选区视作一条独立的 Chrome Glass rail，而不是多个系统 Picker 平铺在白底；
- 使用统一 PremiumPicker；
- 控件间距 8–10 pt，垂直 padding 8 pt；
- 第一行放高频筛选，第二行只在存在筛选条件时显示 chips；
- “更多筛选”使用 Glass button，展开后显示 Floating Glass popover；
- 较窄窗口下允许低优先级筛选进入“更多筛选”，不能压缩文字到不可读；
- active chips 出现/消失时使用 160 ms fade，不让 Table 选择状态丢失。

### 11.10 Table

Table 是数据工作区，不做玻璃卡片墙：

- 保留原生 `Table`、排序、列调整与 alternates row；
- 外层使用 `surface.content`，与 FilterBar 通过明度与材质区分；
- 表头提高到 medium weight，separator 使用 `edge.separator`；
- 奇偶行色差控制在 2–3%；
- hover 行使用 4–6% 冷蓝 tint；
- selected 行使用 12–16% accent tint，并保留系统键盘焦点表达；
- 端口芯片和状态 badge 使用复合小边缘，普通文本单元格不画边框；
- 不能给每一行加圆角卡片、阴影或玻璃 blur；
- 文字对比与扫描速度优先于环境渐变。

### 11.11 分割与详情区

- 主列表与详情之间的 split divider 应比普通 separator 更明确，但仍保持克制；
- 默认使用 1 pt edge + 2–4 pt 极弱投影表达上下层关系；
- hover 到可拖动分隔区时增强到 accent 25%，不能突然变粗；
- 详情区使用 `surface.content` 或略深 2% 的 solid surface；
- 章节主要通过 16–20 pt 间距、标题和局部 separator 分组；
- 不把“这意味着什么”“技术详情”“操作影响”全部包成独立卡片。

### 11.12 关系图与节点

关系图是当前产品最适合承载高级质感的区域。

#### 节点

- 宽度沿用约 190 pt，最小高度从 58 pt 提升到 62–66 pt；
- 圆角 12 pt；
- 使用 `surface.raised`，允许顶部 4–6% 蓝白反光；
- 默认 1.25 pt outer edge + 0.5 pt inner highlight；
- 使用 `0/1/2` near shadow + `0/7/18` ambient shadow；
- selected 使用 12% accent tint、1.5 pt accent edge 和 check/状态文字；
- hover 只提升边缘、反光和阴影，不缩放；
- 节点内部端口分支条继续使用等宽字体，但填充与边缘升级为 tonal style。

#### 连接线

- 已知关系继续使用 1.4 pt 实线；可能关系使用虚线；
- 普通线使用 `state.neutral`，当前选中路径可使用 accent.primary → accent.cyan 的低饱和渐变；
- 箭头和文字必须与线同步变化；
- 不能增加持续流动的粒子或呼吸动画；
- 数据刷新只做 160–200 ms opacity 过渡。

### 11.13 技术详情

- DisclosureGroup 保留原生展开行为；
- 展开头部使用 Glass/Quiet hover surface，让可点击性更明确；
- 每组标题使用 secondary semibold，组间使用间距或短 separator；
- 技术字段不做逐项卡片；
- 原始记录可使用 4% tonal code well，圆角 7 pt，边缘 1 pt；
- 可复制文本的选择行为不受自定义背景影响。

### 11.14 MenuBarPanel

- 保留 `.menuBarExtraStyle(.window)` 提供的系统浮层行为；
- 面板内部使用一层 Chrome Glass，不再给每个区块叠加 Material；
- 搜索框升级为紧凑 PremiumSearchField；
- 三个概况指标组成单一 metric rail，不变成三张卡片；
- 记录 hover 使用整行 tonal fill + 左右 16 pt 对齐；
- footer 普通操作使用 Quiet/Glass 文本按钮，不再全部使用 link style；
- 刷新、暂停和错误需要文字或图标形态，不能只改变颜色；
- 面板宽度继续保持 380 pt，最大列表高度继续保持约 340 pt。

### 11.15 Settings

- 保留系统 Settings Scene、Form 的滚动与键盘行为；
- Section 可以使用低强度 solid well 或玻璃 group background，但不做网页卡片堆叠；
- Picker 行使用 PremiumPicker label 或统一 menu style；
- Toggle 保留原生开关行为，周围文字与分组材质统一；
- 隐私与权限说明使用 neutral info row，不全部使用 `.secondary` 导致层级过弱；
- 设置项标题、当前值和说明形成三级对比，不能依赖系统默认 Form 自动完成所有层级。

### 11.16 Banner、反馈条与空状态

- QueryBanner 使用 10–14% semantic tint + 1 pt semantic edge，不使用整条纯色背景；
- OperationFeedbackBar 使用 Floating/Chrome Glass，顶部边缘由复合边缘替代裸 `Divider()`；
- 错误、暂停、成功均包含图标和文案；
- 空状态保留当前教学式表达，图标可置于 48 pt 低强度玻璃圆形底中；
- 空状态不使用巨大插画、营销文案或循环动画。

## 12. 交互状态与微动效

### 12.1 时间与曲线

| 场景 | 时长 | 曲线 |
|---|---:|---|
| Hover 颜色/边缘 | 80–120 ms | ease-out |
| Pressed | 80–100 ms | ease-in-out |
| Focus ring | 120–160 ms | ease-out |
| Chip/状态出现 | 140–180 ms | ease-out |
| Popover/帮助浮层 | 160–200 ms | ease-out |
| 筛选栏或节点状态切换 | 180–220 ms | ease-in-out |
| 大区域展开/折叠 | 200–240 ms | low-bounce spring 或 ease-in-out |

### 12.2 动效原则

- Hover 不使用 scale；
- Pressed 可使用最多 0.5 pt 视觉下沉，不使用明显 `scale(0.95)`；
- 选中变化优先通过填充、边缘和内高光完成；
- loading 使用系统 ProgressView、symbol effect 或轻量 spinner；
- 不使用扫描、闪烁、呼吸光、背景流动、彩色波纹或粒子；
- 同一时刻最多有 1–2 个明显状态过渡；
- `accessibilityReduceMotion` 开启后移除位移和 spring，只保留必要的极短 opacity 变化或直接切换。

## 13. 浅色、深色与系统辅助模式

### 13.1 深色模式

- 不是把浅色值简单反相；
- 背景使用带蓝相的深灰，不使用纯黑；
- 边缘主要来自低透明白色高光，阴影负责近距离层次；
- 状态色适当提高亮度、降低饱和度，避免刺眼；
- 玻璃承载正文时提高 tint 不透明度，防止背景穿透；
- Table 正文保持近实色。

### 13.2 降低透明度

读取 `accessibilityReduceTransparency`。开启后：

- Material 替换为 94–98% 不透明的 `surface.content/surface.raised`；
- 移除 Canvas 环境光；
- 外轮廓提高约 20%；
- 阴影可保留，但降低模糊半径；
- 不改变布局与控件尺寸。

### 13.3 增强对比度

- `edge.outer` 不透明度提高约 40–60%；
- secondary 正文向 primary 靠近一个明度等级；
- 选中态增加 checkmark、粗细或短标记，不能只提高蓝色；
- focus ring 保持 2 pt 以上；
- 状态 badge 的文字与图标必须达到可读对比。

### 13.4 不以颜色区分

读取 `accessibilityDifferentiateWithoutColor`。开启后：

- 等待、连接、警告、危险继续使用不同 SF Symbol；
- selected 增加 checkmark 或边缘形态；
- 实线/虚线关系旁继续保留文字说明；
- 错误输入显示说明文字，不只显示红色 focus ring。

## 14. 推荐的 SwiftUI 设计系统结构

后续实施时建议建立独立视觉层，避免继续在业务 View 中直接写颜色和描边：

```text
PortViewer/Views/DesignSystem/
├── DesignTokens.swift
├── PortViewerPalette.swift
├── FrostedSurface.swift
├── CompoundEdge.swift
├── PremiumButtonStyles.swift
├── PremiumPicker.swift
├── PremiumSearchField.swift
├── GlassSegmentedControl.swift
├── StatusBadge.swift
└── VisualAccessibility.swift
```

### 14.1 实现原则

- 颜色通过语义 token 暴露，业务层不关心 Hex；
- 复合边缘通过统一 `ViewModifier` 实现；
- Surface 同时处理 colorScheme、reduceTransparency 和 contrast；
- ButtonStyle 统一处理 hover、pressed、focus 和 disabled；
- `PremiumPicker` 优先包裹 `Menu`，保留系统菜单行为；
- 原生 `Alert`、`Table`、`NavigationSplitView` 和 Settings Scene 不重写；
- 只有 SwiftUI Material 无法满足窗口级效果时，才考虑薄封装 `NSVisualEffectView`；
- 不将视觉状态写入 ViewModel，hover、focus 和展开等保持为 View 局部状态；
- 新组件必须提供 Preview，至少覆盖浅色、深色、长中文和 disabled 状态。

### 14.2 示例边缘层次（概念代码）

```swift
RoundedRectangle(cornerRadius: radius, style: .continuous)
    .fill(surfaceStyle)
    .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(edgeOuter, lineWidth: 1)
    }
    .overlay {
        RoundedRectangle(cornerRadius: radius - 1, style: .continuous)
            .inset(by: 1)
            .strokeBorder(innerHighlight, lineWidth: 0.5)
    }
    .shadow(color: nearShadow, radius: 2, y: 1)
```

此代码只表达层级关系。实际实现需要避免重复绘制整圈高光，可使用渐变 stroke 让高光集中在顶部与左上。

## 15. 页面改造映射

### 15.1 主窗口

| 区域 | 保留 | 精修 |
|---|---|---|
| Window/NavigationSplitView | 窗口结构和侧栏宽度 | L0 冷灰蓝背景、侧栏 Chrome Glass、明确侧栏边缘 |
| Toolbar | 搜索、暂停、刷新、设置位置 | 统一 QuietButtonStyle、焦点与刷新状态 |
| OverviewBar | 指标、更新时间、帮助入口 | 合并为单条 Metric Rail，增加复合边缘与 tonal hover |
| FilterBar | 高频/更多筛选逻辑 | PremiumPicker、Glass button、玻璃 rail、统一 chip |
| Table | 原生 Table、列、排序、选择 | content surface、行状态、badge 和端口芯片 |
| Split divider | 上下分区和可调整能力 | 更明确的结构边缘与 hover 反馈 |
| Detail | 内容顺序和渐进披露 | 节点质感、章节层级、技术记录 code well |
| Feedback | 文案和恢复动作 | 语义 tonal fill + glass edge |

### 15.2 菜单栏

| 区域 | 保留 | 精修 |
|---|---|---|
| Header | 名称、更新时间、刷新 | 标题层级、Quiet refresh、状态反馈 |
| Search | 即时过滤与清除 | PremiumSearchField |
| Metrics | 三项数据 | 单一紧凑 rail + 内 separator |
| Records | 34 pt 紧凑行 | tonal hover/selected、端口芯片 |
| Footer | 主窗口、设置、退出 | Glass/Quiet 文本按钮，不全部使用 link |

### 15.3 设置

保持系统 Settings 感，只精修 section surface、Picker、文本层级和说明行，不引入侧栏卡片式管理后台布局。

## 16. 分阶段实施建议

### P0：建立统一质感

1. 建立动态颜色、圆角、间距、阴影和动效 token；
2. 实现 `CompoundEdge`、`FrostedSurface` 与四类 ButtonStyle；
3. 实现 `PremiumPicker` 和 `PremiumSearchField`；
4. 改造 FilterBar、active chips、菜单栏搜索框；
5. 将 0.7 pt badge 描边升级为复合小边缘；
6. 完成浅色、深色与降低透明度基础适配。

### P1：建立主窗口层级

1. 改造 L0 Canvas、Sidebar Chrome Glass 与 Content Surface；
2. 将 OverviewBar 改为 Metric Rail；
3. 统一 Toolbar Quiet buttons；
4. 精修 split divider、QueryBanner 和 OperationFeedbackBar；
5. 保证原生 Table 的数据密度与性能不受影响。

### P2：重点细节

1. 精修关系节点、端口分支条和连接路径；
2. 精修技术详情、空状态、帮助浮层与 MoreFiltersPopover；
3. 统一 Settings section 与 Picker；
4. 完成 hover、pressed、focus、disabled、window inactive 全状态；
5. 补齐增强对比度、不以颜色区分和视觉回归测试。

## 17. 视觉验收标准

### 17.1 第一眼验收

- 仍然能认出是当前 Port Viewer，而不是另一个产品；
- 看起来属于 macOS 原生工具，不像网页 Dashboard；
- 组件边缘在默认缩放下清晰可见，但没有黑色粗描边感；
- 侧栏、筛选区、内容区和浮层能在 1 秒内被感知为不同层级；
- 主色不再是普通单一系统蓝，同时没有霓虹或彩虹感；
- 毛玻璃明显但文字背景稳定，数据区不浑浊。

### 17.2 组件验收

- PremiumPicker 在 Rest/Hover/Pressed/Focused/Expanded/Disabled 六种状态下均可区分；
- 搜索框不聚焦时有明确轮廓，聚焦时 focus ring 清晰；
- 普通按钮、链接入口、图标按钮和危险按钮不会混淆；
- Badge 边缘不再使用低于 1 pt 的单层弱描边；
- 关系节点比普通信息区更精致，但不抢过结论文本；
- Table 行没有被改造成卡片，滚动与扫描效率不下降；
- 菜单栏面板保持紧凑，没有多层卡片与 blur 堆叠。

### 17.3 模式验收矩阵

每个核心页面与组件至少验证：

| 模式 | 必验内容 |
|---|---|
| 浅色 | 白色玻璃边缘可见、正文对比足够、环境光不过曝 |
| 深色 | 深色表面可区分、边缘不发白、状态色不刺眼 |
| 降低透明度 | 无 blur 仍有完整层级，不出现透明文字背景 |
| 增强对比度 | secondary 文字、边缘、focus ring 清晰 |
| 减少动态效果 | 无位移与 spring，操作状态仍明确 |
| 窗口失焦 | 选择仍可识别，色彩与阴影自然减弱 |
| 长中文/大字号 | Picker、按钮、badge 不重叠，关键信息不被截断 |

### 17.4 可访问性与交互验收

- 所有自定义 label 都有准确 accessibilityLabel；
- PremiumPicker、popover、segmented control 可完整使用键盘；
- Escape 关闭浮层，焦点回到触发控件；
- hover 不是获得解释或操作的唯一方式；
- 状态变化不只依赖颜色；
- focus ring 不被 clip；
- 破坏性动作继续经过系统确认，不因视觉自定义改变安全流程。

### 17.5 性能验收

- 同一区域不超过两层真实 Material；
- Table 行内不创建 Material 或高半径阴影；
- 大量记录滚动时保持流畅；
- 窗口 resize 时渐变、边缘和关系图不闪烁；
- 开启/关闭 popover 不造成主列表重算或选择丢失。

## 18. 禁止项清单

- 禁止把所有区域都包成玻璃卡片；
- 禁止使用纯黑背景、霓虹描边、彩色 glow 和扫描线；
- 禁止用一条透明度很低的 hairline 作为交互组件唯一边缘；
- 禁止通过把边框改成 2–3 pt 深灰来假装有质感；
- 禁止给每个 Table 行添加圆角、阴影和 blur；
- 禁止大面积蓝紫渐变背景；
- 禁止在同一屏使用超过三种非语义强调色；
- 禁止 hover scale 导致布局晃动；
- 禁止持续运行的装饰动画；
- 禁止用颜色作为唯一状态表达；
- 禁止移除系统焦点、键盘、菜单和 VoiceOver 行为；
- 禁止为了追求 Liquid Glass 外观提高最低系统版本；
- 禁止把 Settings、菜单栏或主窗口改造成网页式卡片后台。

## 19. 最终风格关键词

应当是：

> macOS 原生、精密、冷静、高级、通透、层次清晰、复合边缘、低饱和环境光、蓝靛品牌光感、短促反馈、数据优先。

不应当是：

> 默认系统控件拼装、轻到消失的边缘、普通单色 Dashboard、霓虹赛博、营销 Bento、厚重拟物、彩虹液态玻璃、卡片堆叠、持续动画。

---

本规范的关键不是“增加更多效果”，而是让每一层效果承担明确职责：Material 表达空间，复合边缘表达物体，阴影表达高度，颜色表达操作与状态，排版表达信息优先级。只有这五者保持一致，Port Viewer 才能在维持当前原生风格的同时获得真正稳定、耐看的高级质感。
