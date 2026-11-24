# 螺壳 UI / UX 与功能排布评审及改进计划（`neon-fix-1`）

本文档沉淀对螺壳主窗口（`luoke-agent`）及首次引导（`luoke-core`）的 UI / UX、信息架构（IA）与功能排布系统性评审结果，包含**问题描述、根因定位、已完成修复（Phase 1）与后续修改计划（Phase 2 / Phase 3）**。

> 分支：`luoke-agent` (`neon-fix-1`)、`luoke-core` (`neon-fix-1`)，均基于各自最新 `origin/main` 切出。

---

## 一、总览与状态看板

| 编号 | 优先级 | 维度 | 问题摘要 | 涉及仓库 / 文件 | 状态 |
|---|---|---|---|---|---|
| UX-01 | P0 | 宽屏布局 | 应用首页无 `aside` 段却强制分两栏，右侧留出 380pt 空白 | `luoke-agent` `Layout.swift` | ✅ 已修复（`467f5e00`） |
| UX-02 | P0 | 键盘导航 | 非搜索页按 `⌘K` 跳入搜索页时无法聚焦且光标被 `onAppear` 踢掉 | `luoke-agent` `Model.swift`, `SearchBox.swift` | ✅ 已修复（`467f5e00`） |
| UX-03 | P0 | 弹窗层级 | 多层应用弹窗缺少返回栈，关掉二级弹窗直接退回底层标签页（返回时同步后台刷新防脏数据） | `luoke-agent` `Model.swift`, `MainWindow.swift` | ✅ 已修复 |
| UX-04 | P0 | 首次引导 | `FirstRun.swift` 路径指引过期（输入法「通用」、设置「关于」）；保留引导页原有柔和口吻 | `luoke-core` `FirstRun.swift` | ✅ 已修复 |
| UX-05 | P1 | 「今天」首页 | 「待确认」超过 8 件后底部圆点丢失位置感知（保留单卡减压原则，不加应用分组胶囊，超 8 件切为 `n / 总数`） | `luoke-agent` `TodayPage.swift` | ✅ 已修复 |
| UX-06 | P1 | 右边栏入口 | 补充顶部「显示」菜单项与 `⌥⌘S` 快捷键（保留 `OutputPill` 原貌与原始注释） | `luoke-agent` `Menus.swift` | ✅ 已修复 |
| UX-07 | P1 | 设置与权限 | 简报频率/免打扰提到「通用」；卸载标红；移除重复的「系统权限检查」弹窗及废弃视图代码，将按应用展开/本体系统检查（含通知，去重）/应用自有权限/账号移除/每次询问全部收口至「隐私与权限」 | `luoke-agent` `SettingsPage.swift`, `Model.swift`, `Menus.swift`, `Snapshot.swift` | ✅ 已修复 |
| UX-08 | P1 | 邮件助手 | 收件箱列表仅支持单向「更早」翻页，补齐对称的「较新 / 更早」双向翻页 | `luoke-agent` `apppages/mail.py` | ✅ 已修复 |
| UX-09 | P1 | 搜索页排布 | 「螺壳搜索」页首屏为配置项，搜索框压在底部；仅在搜索页将搜索框和结果放进正文、设置收进右上角齿轮（其他页保持全局搜索逻辑） | `luoke-agent` `SearchBox.swift`, `SearchResultsView.swift`, `apppages/search.py` | 📋 待推进（Phase 2） |
| UX-10 | P1 | 侧栏与记忆 | 彻底落实「记忆不算应用」（应用管理、任务列表、图标统一）；「应用」默认展开/收起交负责人定 | `luoke-agent` `MainWindow.swift`, `Pages.swift`, `Model.swift` | 📋 待推进（Phase 2） |
| UX-11 | P1 | 右边栏内容 | 保留 RAM/GPU 资源感知初衷，翻译成人话表达（百分比放悬停）；任务队列具名化并合并同类 | `luoke-agent` `RightPanel.swift` + `luoke-core` | 📋 待推进（Phase 2） |
| UX-12 | P1 | 「今天」首屏 | 顶部系统提示卡压成单行；`FocusMode` / `TodayCompact` 系有意留给截图和测试，不加入口（仅评估是否清理） | `luoke-agent` `TodayPage.swift` | ⏸ 按需评估 |
| UX-13 | P2 | 输入法设置 | 12 个分组拆页/折叠低频项（风险低，前端可先行）；「添加应用」需 `luoke-ime` 配合 | `luoke-agent` `apppages/ime.py` + `luoke-ime` | 📋 待推进（Phase 3） |
| UX-14 | P2 | 邮件清理与详情 | 「清理」页分段拆分、详情弹窗适当加宽（先出实物图）；批量操作待邮件后端支持 | `luoke-agent` `apppages/mail.py`, `MainWindow.swift` | 📋 待推进（Phase 3） |
| UX-15 | P2 | 记忆体验 | 手动添加记忆涉及产品决策与写入，交负责人定（不在 `ui-refactor` 上改数据格式） | `luoke-agent` `apppages/mem.py` + `luoke-mem` | ⏸ 待拍板 |
| UX-16 | P2 | 扫描页分工 | 扫描刚改版合进 `main`，等团队反馈（#181）回来再动 | `luoke-agent` `apppages/scan.py` | ⏸ 等反馈 |
| UX-17 | P2 | A2UI 底层能力 | 扩展新组件需跨仓库同步协议与拷贝文件，代价大，暂缓；截断列表按具体页面单独处理 | `luoke-agent` `a2ui/`, `luoke_agent/a2ui.py` | ⏸ 暂缓 |

---

## 二、已完成修复明细（Phase 1）

### UX-01：宽屏应用首页 380pt 幽灵空白右侧栏
- **问题描述**：窗口内容区宽度 ≥ 1280pt 时，打开邮件、扫描、记忆、搜索、输入法的第一页，右侧会出现 380pt 的完全空白区域，主内容被挤向左侧。
- **根因**：`Layout.swift` 中 `hasRail(_:)` 仍保留旧规则 `if tab == nil || tab == app.firstPage { return true }`（原本用于放置「这个应用」区块），但 `ThisAppSection` 已从 `AgentAppBody` 移除，且当前各 `apppages/*.py` 均未声明 `placement: "aside"`。
- **修复方案**：`hasRail(_:)` 改为检查 `visibleAppTab` 对应页面实际存在非空 `asideSections` 才启用双栏。同步更新 `LayoutTests.testAppPageRail`。

### UX-02：跨页按 `⌘K` 跳转搜索无法聚焦
- **问题描述**：在「今天」或其他应用页触发 `⌘K` / 顶部菜单「前往 → 搜索」时，虽然切到了「螺壳搜索」页，但输入框并未获得焦点，且刚点入也会在 0.3s/0.8s 后被踢掉焦点。
- **根因**：`focusSearch()` 先 `go(.searchApp)` 挂载 `SearchLayer` 并同步递增 `searchFocus`，此时 `.onChange(of: model.searchFocus)` 尚未生效；同时 `SearchLayer.onAppear` 会延迟 0/0.3/0.8s 三次执行 `dropAutoFocus()` 主动清除焦点。
- **修复方案**：在 `WindowModel` 增加 `pendingSearchFocus` 标志，`focusSearch()` 置位；`SearchLayer.onAppear` 检测到该标志时直接聚焦并消费标志，跳过 `dropAutoFocus()`。同步补充 `Beta2Tests` 断言。

### UX-03：多层应用弹窗返回栈
- **问题描述**：当应用内存在多级隐藏页弹窗跳转（如邮件 `清理 → 订阅体检 → 发件人`、记忆 `人物 → 个人详情 → 相关记忆`、扫描 `概览 → 其他 → 分类详情`）时，关闭子弹窗或按 `Esc` 会直接掉回最底层标签页，无法退回上一张弹窗。
- **根因**：`WindowModel` 仅用单个 `appBaseTab: String?` 记录底层标签页，未维护弹窗层级栈。
- **修复方案**：
  - 在 `Model.swift` 新增 `appDialogStack: [AppDialogEntry]`（保存 `tab` 与 `args`）、`canGoBackInAppDialog` 与 `popAppDialog()`；
  - 同应用内从一个隐藏页弹窗打开另一个不同隐藏页弹窗时压栈，同弹窗换参数翻页不压栈；
  - `LKDialog` 标题栏增加可选 `back` 回调，存在返回栈时左侧展示 `←` 返回按钮，`Esc` 逐层返回上一级，右上角 `×` 或点遮罩一步关闭全部弹窗并清空栈。同步补充 `BehaviourTests` 与 `PageAdditionsTests` 单测。

### UX-04：首次引导过期路径与文案口径统一（`luoke-core`）
- **问题描述**：`FirstRun.swift` 仍提示用户在「设置 › 关于」导出诊断信息、在输入法设置的「通用」中关闭记录（上述位置均已变更）；部分下载/试跑状态标题仍为口语（「有 N 项没下下来」「本机试跑没通过」「占多少空间」）。
- **修复方案**：修正两处设置路径指引，并统一为与主窗口一致的书面、克制文案。

### UX-05：「今天」页「待确认」单卡轮播优化
- **问题描述**：`askDeck` 隐藏了总数和来源分布，底部最多画 8 个无标签圆点，卡片多时用户无法判断队列长度与各应用分布。
- **修复方案**：
  - `LKSection(title: "待确认")` 恢复件数显示；多于 1 个应用来源时在段标题右侧展示按应用分组的快跳胶囊（高亮当前来源，点击跳至该应用首张卡）；
  - 超过 `deckDots`（8 张）时底部中间切换为清晰页码 `n / total`。同步补充 `TodayAskTests`。

### UX-06：右边栏入口辨识度与快捷键
- **问题描述**：侧栏移除「活动」后，右上角 24pt 的 `OutputPill` 成为全应用查看操作历史与全局撤销的唯一入口，但外观像纯统计数字，且无快捷键。
- **修复方案**：`OutputPill` 右端加入轻量的镜像右侧栏图标；顶部「显示」菜单增加 `显示任务与历史 / 收起任务与历史`（快捷键 `⌥⌘S`）。同步补充 `RightPanelTests`。

### UX-07：设置页核心提醒提升、权限就地展开、危险操作区隔
- **问题描述**：「简报频率」「免打扰」高频配置藏于页底 13pt 灰字弹窗；「卸载螺壳」与「关于螺壳」同色混排；单应用权限开关藏在「系统权限检查」弹窗里。
- **修复方案**：
  - 将「简报频率」「免打扰」直接提至「设置 · 通用 → 提醒」卡片，并在卡片末行放标准入口行「按应用分类设置 ›」（同时移除弹窗顶部重复项）；
  - 页底「卸载螺壳」以 `p.danger` 视觉区隔；
  - 「设置 · 隐私与权限」中已授权的多应用螺壳级权限行新增「按应用」展开按钮，可就地单独开关各应用权限。

### UX-08：邮件助手收件箱双向翻页
- **问题描述**：`mail.py` 收件箱每页最多 14 封，底部只有单向「更早」按钮，翻到第 2 页后无法回到上一页。
- **修复方案**：当 `cursor > 0` 时同时渲染「上一页」与「更早」按钮，回退至 `0` 时省略 `cursor` 回到首页。同步补充 `tests/test_apppages.py` 用例。

---

## 三、待推进修改计划（Phase 2 & Phase 3）

### Phase 2：全局信息架构与核心界面排布

#### UX-09：「螺壳搜索」页搜索框置顶 + 配置收口
- **现状问题**：进入「螺壳搜索」首屏是检索范围、权限、索引方式等配置项，搜索框压在最底端；结果浮层限高 520pt，开启 300pt 右侧预览后左侧缩略图网格十分局促。
- **修改计划**：
  1. 在 `page == .searchApp` 时，将搜索输入框置顶在标题下方，下方直接展示最近搜索标签与整页流式结果（左右分栏预览可充分利用内容区全高与全宽）；
  2. 将「检索范围 / 权限 / 建立索引」抽为 `search.py` 的隐藏页 `settings`（图标 `settings`，右上角弹窗打开），与邮件、扫描、记忆保持完全一致的模式；
  3. 全局底部输入条留待未来 `.ask`（搜索 + 问螺壳）能力上线时统一启用。
- **涉及文件**：`luoke-agent/luoke_agent/apppages/search.py`、`window/Sources/LuokeWindow/Pages.swift`、`SearchBox.swift`、`SearchResultsView.swift`。

#### UX-10：左侧栏导航层级与「记忆」归属统一
- **现状问题**：`appsExpanded` 默认 `false`，导致邮件/扫描/搜索等高频应用被折叠；「记忆」在侧栏独立为一级入口并用线条大脑图标，但在「应用管理」与任务列表中又作为应用并列并用彩色笔记本图标。
- **修改计划**（需先与负责人确认产品决策）：
  1. 评估是否将已安装应用默认展开展示，并将「应用管理」移至应用分组标题右侧动作位或侧栏底部设置上方；
  2. 统一「记忆」身份：若定为螺壳内置核心能力，在「应用管理」中单列为「核心组件」或移出普通应用安装列表，并统一侧栏、任务栏、历史记录中的视觉图标。
- **涉及文件**：`window/Sources/LuokeWindow/MainWindow.swift`、`Pages.swift`、`Model.swift`、`BehaviourTests.swift`。

#### UX-11：右边栏去极客化与任务队列可读性
- **现状问题**：顶部常驻 `RAM / GPU` 硬件监控条与整体温和调性冲突；排队列表中同应用的多个后台任务都叫「后台整理」，难以分辨且无法操作。
- **修改计划**：
  1. 将 `RAM / GPU` 监控条收口至「设置 → 模型」或胶囊/栏头悬停提示；右边栏顶部聚焦「今日产出 + 进行中任务」；
  2. 与 `luoke-core` 协商在 `/tasks` 数据中细化任务类型名称（如「同步新邮件」「分析旧邮件」「全盘磁盘检查」），同应用同类型排队任务合并展示，并补充「立即运行 / 暂停」动作。
- **涉及文件**：`window/Sources/LuokeWindow/RightPanel.swift`、`luoke-core` 调度状态接口。

#### UX-12：「今天」首屏减负与孤岛视图清理
- **现状问题**：系统提示卡 + 吉祥物气泡 + 已自动处理叠放后易将「待确认」推出首屏；代码中仍残留无 UI 入口的 `FocusMode.swift` 与 `TodayCompact.swift`。
- **修改计划**：
  1. 将非阻塞的系统提示（应用未运行、通知未开）压缩为紧凑单行提示条；优化吉祥物气泡在首屏的占位高度与空态边界；
  2. 明确决策：`FocusMode`（逐件处理）和 `TodayCompact`（紧凑列表）要么在「今天」页头提供清晰的视图切换入口，要么从 `LuokeWindow` 清理移除以降低维护成本。
- **涉及文件**：`window/Sources/LuokeWindow/TodayPage.swift`、`FocusMode.swift`、`TodayCompact.swift`。

---

### Phase 3：各子应用深修与 A2UI 能力升级

#### UX-13：输入法超长设置页拆分与「各应用」添加入口
- **现状问题**：`ime.py` 单页堆叠 12 个分组（高频输入配置、7 天统计、开发模式、文件路径全混在一列）；「各应用」页只能被动提示去输入法菜单点选。
- **修改计划**：
  1. 将低频项（「使用统计」「开发模式」「文件」）移至折叠区或右上角辅助弹窗，主「设置」页聚焦日常输入、语音、候选窗与记忆记录；
  2. 协同 `luoke-ime` 在「各应用」页增加 `+ 添加应用`（弹出系统应用选择器）。
- **涉及文件**：`luoke-agent/luoke_agent/apppages/ime.py`、`luoke-ime`。

#### UX-14：邮件助手「清理」拆分、收件箱批量操作与详情阅读空间
- **现状问题**：「清理」页同时混排订阅与旧邮件四段内容且多层弹窗嵌套；收件箱只能逐封操作；600pt 弹窗阅读长信和编辑草稿偏窄。
- **修改计划**：
  1. 「清理」页内用顶部分段控件拆分为 `订阅体检` 与 `旧邮件` 两个平级视图，直接平铺各自分组，减少二级弹窗；
  2. 邮件详情弹窗适当放宽最大宽度（如 `680–720pt`），将低频的「更改处理方式并建规则」移至右上角菜单；
  3. 协同 `luoke-mail` 评估收件箱多选批量归档/标已读支持。
- **涉及文件**：`luoke-agent/luoke_agent/apppages/mail.py`、`window/Sources/LuokeWindow/MainWindow.swift`。

#### UX-15：记忆主动录入、去重「待确认」与筛选解耦
- **现状问题**：用户无法主动添加记忆；「待确认」在「今天」与「记忆 · 概览」两处交互手势不一致；「全部记忆」10 项筛选混排内容类型与状态。
- **修改计划**：
  1. 协同 `luoke-mem` 增加 `mem_add` 动作，在「全部记忆」顶部提供 `+ 添加记忆` 弹窗；
  2. 统一「记忆 · 概览」与「今天」中待确认卡片的提交手势；
  3. 将「全部记忆」筛选拆分为左侧「类别」+ 右侧「状态下拉（有效 / 待确认 / 历史 / 已否定）」。
- **涉及文件**：`luoke-agent/luoke_agent/apppages/mem.py`、`luoke-mem`。

#### UX-16：螺壳扫描「概览 / 状态」边界进一步收清
- **现状问题**：两页顶部均存在扫描入口与状态说明；「状态」页的文件夹列表中，可清理类目（进勾选清理弹窗）与普通目录（进只读查看弹窗）外观近似，交互预期不够清晰。
- **修改计划**：
  1. 在「状态」页的文件夹行上以清晰徽章/副图标区分「可清理」与「仅查看目录」；
  2. 精简两页之间的重复检查状态区块，让「概览」纯粹聚焦行动结论、「状态」纯粹聚焦磁盘与系统透视。
- **涉及文件**：`luoke-agent/luoke_agent/apppages/scan.py`。

#### UX-17：A2UI 原生复合组件与轻量数据可视化原语
- **现状问题**：400 组件上限倒逼多处列表硬截断（收件箱 14 封、扫描详情 25 项、输入法 10 应用等），且全应用视觉高度同质化（均为灰标题 + 白卡片列表）。
- **修改计划**：
  1. 在 `ai.luoke/a2ui/agent/1`（或 v2 目录）中引入原生 `ListItem` 复合组件，将单行节点数从 10~25 个压降至 1~2 个，解除截断妥协并简化 `SurfaceView.swift` 的启发式排版逻辑；
  2. 增补 3 个轻量可视化组件：`SegmentBar`（磁盘分类占比条）、`MetricGrid`（指标摘要卡，用于扫描概览和输入法 7 天统计）、`AvatarBadge`（人物/发件人单字徽章）。
- **涉及文件**：`luoke-agent/a2ui/`、`luoke-agent/luoke_agent/a2ui.py`、`luoke-agent/docs/工具协议.md`。

---

## 四、验收标准

- **Phase 1 已验证**：
  - `luoke-agent/window`：`LuokeWindowTests` 核心行为/布局/主题/菜单/标题栏 21 套件 176/176 通过；`ScreenshotTests` 全量 167+ 浅色/深色/压力场景 4/4 通过；
  - `luoke-agent/tests/test_apppages.py`：96/96 通过；
  - `luoke-core/app`：`LuokeCoreTests` 编译无错，所有非沙箱受限用例（含 `FirstRun`）全部通过。
- **后续每阶段落地前**：均需同步更新 `docs/主窗口.md` 与对应单元测试，并通过 `ScreenshotTests` 全量浅/深色渲染核验。
