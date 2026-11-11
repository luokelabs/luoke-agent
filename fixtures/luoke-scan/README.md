# 给 agent 的场景样例

扫描（luoke-scan）对 agent 那一路（工具协议版本 1：MCP、outbox、A2UI 卡片、基础页、权限）在几种用户处境下**真实**的答复。
都是 `scripts/record_agent_fixtures.py` 在假用户目录上跑真的 `luoke-scan mcp --fixture` 录的，不是手写的：
agent 拿它们当样例数据和测试的输入，就是两边之间的接口说明。代码改了 agent 看到的东西，`--check` 就不过，
要重录、提交，并且在 PR 里说清 agent 那边要不要跟着改。

一个请求起一次 `luoke-scan mcp --fixture <假目录> --clock <时间>`：标准输入一条 JSON-RPC，标准输出是答复（和从外面测的
`blackbox/harness.py` 一样）；螺壳每个请求起的是同一个程序（`luoke-scan mcp --this-mac`，stdio，一行一条消息）。假用户目录用
从外面测的那一套造（`blackbox/fx.py`、`blackbox/cases/base.py`），和 `blackbox/cases/mcp_agent.py` 里同样的五个场景一样。

**本文件也是录的时候生成的**，不要手改；要改说明，改 `scripts/record_agent_fixtures.py` 里的场景。

## 重录、核对

```bash
go build -o .build/go/luoke-scan ./cmd/luoke-scan
python3 scripts/record_agent_fixtures.py            # 重录，写进 fixtures/agent/
python3 scripts/record_agent_fixtures.py --check    # 重录进临时目录和这里比，不一样就列出差别、退出码 1
python3 scripts/record_agent_fixtures.py --only decide-3 --keep   # 只录一个场景，留下假目录看看
```

## 每个场景里有什么

一个场景一个文件夹，一个请求一个文件，名字照请求起：

| 文件 | 请求 |
|---|---|
| `manifest.json` | 配件清单 `packaging/luoke-accessory.json`（主控经 `GET /accessories` 交给 agent 的那份，`capabilities` 在里面） |
| `scenario.json` | 这个场景：处境、怎么录的（假目录改了什么、时钟、时区、每一步）、窗口上应该是什么样 |
| `server-discover.json` | `server/discover` |
| `tools-list.json` | `tools/list`（`annotations.readOnlyHint`、只在 Mac 上的 `_meta.ai.luoke/where`） |
| `resources-list.json` | `resources/list` |
| `read-outbox*.json` | `resources/read` `luoke://luoke-scan/outbox`（agent 每分钟读；`outbox` 也认） |
| `read-summary*.json` | `resources/read` `summary` |
| `read-permissions*.json` | `resources/read` `permissions` |
| `read-page-<页>*.json` | `resources/read` `page/overview`、`page/mac`、`page/cleaned` |
| `call-<工具>*.json` | `tools/call`：卡片、页上的点按（带 `ai.luoke/user-action`），或对话里模型调的只读工具 |

带 `-after-…` 的是点完以后再读的。每个文件是 `{"request": …, "reply": …}`：`request` 是 agent 发的那条 JSON-RPC
（`_meta` 里照 agent 带协议版本、`clientInfo`、`clientCapabilities`，点按的再带 `ai.luoke/user-action`），`reply` 是扫描的答复。
JSON 按键排序、缩进两格。

**和线上不一样的地方**（重放时要换回去）：

- `resources/read` 的 `contents[0].text` 在线上是一段 JSON **文字**（`mimeType: application/json`），这里解开成了 JSON 值；
  重放时 `json.dumps` 回去。
- 由路径和随机数算出的 12 位十六进制编号（发现、方案 `p-…`、清理记录 `c-…`、卡片 `security-…`、`round-…`、`scan-…`）
  按在场景里出现的先后换成 `000000000001`、`000000000002`……；同一个场景里前后对得上（outbox 里的方案编号就是点按时发的那个），
  不同场景之间不对应。
- 路径：假用户目录是 `~`，临时目录是 `$TMPDIR`（真 Mac 上是 `/var/folders/…/T`，卡片照原样写），废纸篓是 `~/.Trash`，
  假目录的别处是 `$FIXTURE`。
- 时钟停在固定的时间（`--clock`，见各场景的 `scenario.json`），时区是 Asia/Shanghai：卡片和页上的「10月20日 20:00」这类按它写，
  `created`、`expires` 这类是 UTC。大小（「62.9 MB」）照录的那台 Mac 的区域设置写，小数点是逗号的区域录出来会不一样。

## 重放时要知道的

- agent 要问的：`tools/list`（认 `readOnlyHint`）、`luoke://luoke-scan/outbox`、`summary`、`permissions`；打开应用页时读
  `page/<页>`。`server/discover`、`resources/list` 扫描都答，agent 现在不一定问。
- 会改动东西的（`scan_apply`、`scan_ignore`、`scan_restore`、`scan_autoclean`，清单 `actions` 里的四个）只认带
  `ai.luoke/user-action`（`surfaceId` 是工具自己起的卡片编号或页 id、`componentId`、`at`）的调用，没带的答
  `isError: true`、`structuredContent.code: "needs_user_action"`。`outbox_ack` 是只读的记账。
- 按钮的 `event.context` 里的 `{"path": "/choices"}` 换成点的时候卡片数据模型里的值（`{"i0": ["trash"], "i1": ["keep"], …}`），
  方案编号这类写死的值照卡片上的。
- 点按的答复：`content[0].text` 一句话；`structuredContent.card` 是**更新原卡片**的消息（没有 `createSurface`，组件编号带
  `r<数字>-` 前缀，换掉原来的组件）；`done: true` 表示办完了，agent 回 `outbox_ack` `answered`，扫描已经从 outbox 撤下它。
  对话里调的只读工具（`scan_status`、`scan_findings`、`scan_plan`）答一张**新卡片**（第一条是 `createSurface`，编号 `scan-…`）。
  基础页上点的，答复里的卡片不画，窗口重新读那一页。
- 没录的：`scan_reveal`、`scan_open_settings`（在假目录上也会真的打开访达、系统设置；答一句「在访达里选中了 …」/
  「打开了系统设置的「…」页。」，没有卡片）；`scan_now`（另起一个进程查，马上答「开始查了……」，查完 outbox 换成新的一轮）；
  `scan_plan`（和一轮的卡片上那份方案一样的东西，答一张新卡片）。
- 「今天」里分在哪一段，下面照 luoke-agent 现在的分段规则（`luoke_agent/agent.py` 的 `_section`：`auto-done` → 已经替你做了，
  `urgent` → 急事，`needs-access` → 要你决定，`low` → 顺便看看，别的 → 要你决定）写的，不是扫描定的。

## 要对齐的

- 一轮的那件没有自动清的时候是 `findings`、`low`（清单 `reports` 里这样登记），卡片上却是要用户定的清理方案；照 agent 现在的
  分段规则它在「顺便看看」，不在「要你决定」。要不要改，由 agent 那边定（扫描这边改 urgency 要改清单的 `reports`）。
- 扫描这边要改的，改了样例跟着变，agent 别照着它排版：
  - 方案里的一项指着好几处（`cleaned-restore` 里 25 个 `wings-*` 临时文件夹）时，清理记录每处各记一行，标题都是那一项的、
    不记大小：「清理记录」页那一批写成「…、临时目录里有 25 个 wings-*…、临时目录里有 25 个 wings-*… 等 26 样（62.9 MB）」，
    `scan_restore` 的答复「放回了 26 项」下面同一个标题列好几行，和执行时说的「移到废纸篓 2 项（194 MB）」对不上。
  - 点完以后、下一轮之前，一轮那件的标题还按上一轮的报告数：`malware` 里 eicar 已经移走，点完再读 outbox，标题的「另有 … 条要你看」
    还算着它，卡片上的方案已经没有它。
  - 点完以后 outbox 里那件的卡片不变（`autoclean-done` 里点了「放回」，再读 outbox 还是点之前那张，「放回」还在）。
    agent 照卡片变没变决定重画，窗口上留着答复换上的那张（录的时候也照这样，下一下点的是换上的那张的按钮）；
    agent 的状态丢了（例如重装）才会又看到旧的。要不要点完就换掉 outbox 里的卡片，扫描这边以后定。

## 场景

## `first-run-no-fda`：第一次扫描，还没给完全磁盘访问

刚装好螺壳，还没在系统设置里给「螺壳」打开完全磁盘访问。扫描第一次查这台 Mac：下载、文稿、桌面和别的应用的容器都没看（看了 macOS 会弹框问），别处照查。

**怎么录的**：blackbox/fx.py 造的假目录：blackbox/cases/base.py 的 `build`（照单元测试的 Fixture.build 摆），fakes.json 是 `fx.standard_fakes`（和单元测试的 Fixture.Fakes.standard 一样），另加一块 494 GB、还剩 182 GB 的硬盘；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）。

假目录改过：pip 的缓存 60 MB（~/Library/Caches/pip/http/blob，半天前写的），之前没查过：没有它 3 天前的大小；~/Library/Application Support/com.apple.TCC/TCC.db 改成读不了（chmod 000）：没有完全磁盘访问时 macOS 也不让读它。

**扫描报的**

- 概览（`summary`）：count 7，「能清出 62.9 MB，另外 6 项等你处理」
- 权限（`permissions`）：`admin` ask、`auto` off、`fda` denied
- outbox：2 件
  - `round/2026-10-20T12:00:00Z`：`findings`、`low` → 顺便看看（later）
    - 标题：能清出 62.9 MB，另外 6 项等你处理
    - 摘要：会重建的缓存 1 项，不用你选；另外 6 项在「螺壳扫描」里等你看。有 9 项要打开「完全磁盘访问」才能查。
    - 卡片（surface `round-000000000001`）：
      - **能清出 62.9 MB**
      - 会重建的缓存 1 项，不用你选；另外 6 项在「螺壳扫描」里等你看。
      - 按钮：「清理 1 项缓存」→ `scan_apply`、「打开自动清理」→ `scan_autoclean`
  - `needs-access/full-disk-access`：`needs-access`、`low` → 要你决定（decide）
    - 标题：下载、文稿、桌面还没查
    - 摘要：给「螺壳」打开「完全磁盘访问」就能查，删掉的应用留下的数据和权限也会一起查。
    - 卡片（surface `access-000000000003`）：
      - **下载、文稿、桌面还没查**
      - 给「螺壳」打开「完全磁盘访问」就能查，删掉的应用留下的数据和权限也会一起查。
      - 按钮：「打开设置」→ `scan_open_settings`
- 基础页 `page/overview`：
  - **扫描**
  - 上次查 10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - 这周清掉
  - 还没清过
  - 能清出
  - 62.9 MB
  - 等你处理
  - 6 项
  - （分隔线）
  - 可以清掉 5
  - 会自动重建的缓存 1 项（62.9 MB）
  - pip
  - 按钮：「清理」→ `scan_apply`
  - 选项：wings 留下的临时文件夹（131.1 MB）（trash/keep/ignore，默认 keep）
  - 25 个 wings-*，在系统临时目录里
  - 选项：已经删掉的应用「removed」留下的数据（2.1 MB）（trash/keep/ignore，默认 keep）
  - 选项：很久没动过的项目「old-pushed」（147 KB）（trash/keep/ignore，默认 keep）
  - 选项：会跟着电脑一起启动的「gone」（trash/keep/ignore，默认 keep）
  - 开机后在后台自动运行。不认识可以移除。
  - 按钮：「按上面的选择清理」→ `scan_apply`
  - （分隔线）
  - 要你看看 2
  - 硬盘没加密：电脑丢了，别人能直接读出里面的东西
  - 打开时会给你一个恢复密钥，抄下来放好。
  - 按钮：「打开 FileVault 设置」→ `scan_open_settings`
  - 「gone」已经删掉了却还在运行
  - 它会跟着开机启动，重启后还会再运行。 / 要停掉它：把上面「会跟着电脑一起启动的『gone』」改成「移到废纸篓」，清理后重启一下电脑。
  - （分隔线）
  - 有 9 项要打开「完全磁盘访问」才能查
  - 按钮：「打开设置」→ `scan_open_settings`
  - （分隔线）
  - 自动清理
  - 按钮：「打开自动清理」→ `scan_autoclean`
  - 打开后，每天那一轮不用你点就清：会重建的缓存、装好了的应用的安装包、下载文件夹里的重复文件、测试工具留下的临时文件夹。移到废纸篓的都能放回，要你定的照样先问你。
  - 病毒库更新于 10月20日
- 基础页 `page/mac`：
  - 硬盘还剩
  - 182.0 GB
  - 一年多没打开过的大文件
  - 没查全
  - 安全设置（1 项没查成）
  - 1 项没开启
  - 上次扫描：10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - 没允许完全磁盘访问：下载、文稿、桌面、照片和一些应用的数据等查不了。给「螺壳」打开开关以后，回来点「现在查一下」。
  - 按钮：「打开「完全磁盘访问」设置」→ `scan_open_settings`
  - （分隔线）
  - 硬盘
  - 用了 312.0 GB，一共 494.0 GB
  - （分隔线）
  - 占地方最多的文件夹（不含下载、文稿、桌面、照片和一些应用的数据等）
  - 临时文件
  - 262.2 MB
  - 开发工具的缓存
  - 64.0 MB
  - 已经删掉的应用留下的数据（5 个应用）
  - 10.5 MB
  - Projects
  - 3.4 MB
  - Present 的缓存
  - 2.1 MB
  - 这些加起来约 342 MB。下载、文稿、桌面、照片和一些应用的数据等没查，那里有多大还不知道。
  - （分隔线）
  - 一年多没打开过的大文件
  - 1 MB 以上算大文件，按大小排
  - 下载、文稿、桌面、照片和一些应用的数据等没查；别的地方没找到一年多没打开过的大文件。
  - （分隔线）
  - 权限
  - 完全磁盘访问
  - 没允许
  - 按钮：「打开「完全磁盘访问」设置」→ `scan_open_settings`
  - 已经删掉的应用还拿着权限
  - 没查成，要先允许完全磁盘访问
  - （分隔线）
  - 安全设置
  - 硬盘加密（文件保险箱）
  - 没开启
  - 只打开来路清楚的应用
  - 没查成
  - 防火墙
  - 已开启
  - 系统完整性保护
  - 已开启
  - 锁屏要密码
  - 已开启
  - 自动检查系统更新
  - 已开启
  - 没开启的怎么打开，在「概览」的「要你看看的」里有写。
  - 没查成的，下次扫描或点上面的「现在查一下」时会再查。
- 基础页 `page/cleaned`：
  - **清理记录**
  - 还没清理过。

**窗口上**

- 「今天 · 要你决定」里一张「扫描需要「完全磁盘访问」」，按钮「打开设置」；应用页的 `needs` 里有 `fda`。
- 完全磁盘访问在清单里写着 `owner: "luoke"`：权限页照螺壳.app 报的（`POST /host`）画，工具报的 `denied` 只作参考；螺壳.app 报了 `granted` 以后 agent 撤掉这张。
- 一轮的那件（`findings`，low）在「顺便看看」；概览页写「有 N 项没查成，下一轮再查」。

**文件**（按请求的先后）

| 文件 | 请求 | 什么时候 |
|---|---|---|
| `server-discover.json` | server/discover | 2026-10-20T12:00:00Z：server/discover |
| `tools-list.json` | tools/list | 2026-10-20T12:00:00Z：列工具（agent 认 readOnlyHint） |
| `resources-list.json` | resources/list | 2026-10-20T12:00:00Z：列资源 |
| `read-outbox.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:00:00Z：读 outbox（每分钟一次） |
| `read-summary.json` | resources/read `summary` | 2026-10-20T12:00:00Z：读概览（侧栏的计数和一句话） |
| `read-permissions.json` | resources/read `permissions` | 2026-10-20T12:00:00Z：读权限的状态 |
| `read-page-overview.json` | resources/read `page/overview` | 2026-10-20T12:00:00Z：读基础页 page/overview |
| `read-page-mac.json` | resources/read `page/mac` | 2026-10-20T12:00:00Z：读基础页 page/mac |
| `read-page-cleaned.json` | resources/read `page/cleaned` | 2026-10-20T12:00:00Z：读基础页 page/cleaned |
| `call-scan_status.json` | tools/call `scan_status` | 2026-10-20T12:00:00Z：对话里问「扫描怎么样了」：模型调 scan_status（只读，答一张新卡片） |

`call-scan_status.json` 答：「上一轮：2026-10-20T12:00:00Z，用了 0 秒；发现：放心删 1、要确认 5、仅供参考 15；放心删的能腾出 62.9 MB；病毒库 daily 27000（2026-10-20）；没查成：space、space.system、space.duplicates、leftover.app-data、leftover.installer、stale.large-file、secrets、permission.stale-grant、malware；自动清：关」（新卡片）

## `fda-granted`：允许了完全磁盘访问以后再查一轮

刚装好、没给完全磁盘访问时查过一轮（下载里那个大视频看不到）。用户照「状态」页的提示在系统设置里打开了完全磁盘访问，两小时后回来点「现在查一下」。两轮之间不清任何记录，第二轮走增量的路：下载、文稿、桌面这一轮第一次量。

**怎么录的**：blackbox/fx.py 造的假目录：blackbox/cases/base.py 的 `build`（照单元测试的 Fixture.build 摆），fakes.json 是 `fx.standard_fakes`（和单元测试的 Fixture.Fakes.standard 一样），另加一块 494 GB、还剩 182 GB 的硬盘；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）。

假目录改过：pip 的缓存 60 MB（~/Library/Caches/pip/http/blob，半天前写的），之前没查过：没有它 3 天前的大小；~/Library/Application Support/com.apple.TCC/TCC.db 改成读不了（chmod 000）：没有完全磁盘访问时 macOS 也不让读它；下载里放了一个 40 MB、一年多没打开过的视频（Spotlight 也报它），第一轮没权限看不到；用户打开了完全磁盘访问：去掉 --no-full-disk-access，TCC 的数据库改回能读。

**扫描报的**

- 概览（`summary`）：count 12，「11 项等你处理，其中 2 项要尽快」
- 权限（`permissions`）：`admin` ask、`auto` off、`fda` granted
- outbox：3 件
  - `security/malware.clamav/000000000006`：`security`、`urgent` → 急事（urgent）
    - 标题：下载里的「eicar-test.com」可能是病毒
    - 摘要：下载里的「eicar-test.com」可能是病毒。病毒库认出了它。建议移到废纸篓，先不要打开。
    - 卡片（surface `security-000000000004`）：
      - **下载里的「eicar-test.com」可能是病毒**
      - 病毒库认出了它。建议移到废纸篓，先不要打开。
      - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - `security/malware.yara.luoke_fake_password_dialog/000000000009`：`security`、`urgent` → 急事（urgent）
    - 标题：下载里的「update.scpt」可能是病毒
    - 摘要：下载里的「update.scpt」可能是病毒。病毒库认出了它。建议移到废纸篓，先不要打开。
    - 卡片（surface `security-000000000007`）：
      - **下载里的「update.scpt」可能是病毒**
      - 病毒库认出了它。建议移到废纸篓，先不要打开。
      - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - `round/2026-10-20T14:00:00Z`：`findings`、`low` → 顺便看看（later）
    - 标题：能清出 62.9 MB，另外 9 项等你处理
    - 摘要：会重建的缓存 1 项，不用你选；另外 9 项在「螺壳扫描」里等你看。
    - 卡片（surface `round-000000000010`）：
      - **能清出 62.9 MB**
      - 会重建的缓存 1 项，不用你选；另外 9 项在「螺壳扫描」里等你看。
      - 按钮：「清理 1 项缓存」→ `scan_apply`、「打开自动清理」→ `scan_autoclean`
- 基础页 `page/overview`：
  - **扫描**
  - 上次查 10月20日 22:00
  - 按钮：「现在查一下」→ `scan_now`
  - 这周清掉
  - 还没清过
  - 能清出
  - 62.9 MB
  - 等你处理
  - 11 项
  - （分隔线）
  - 要尽快处理 2
  - 下载里的「eicar-test.com」可能是病毒
  - 病毒库认出了它。建议移到废纸篓，先不要打开。
  - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - 下载里的「update.scpt」可能是病毒
  - 病毒库认出了它。建议移到废纸篓，先不要打开。
  - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - （分隔线）
  - 可以清掉 6
  - 会自动重建的缓存 1 项（62.9 MB）
  - pip
  - 按钮：「清理」→ `scan_apply`
  - 选项：wings 留下的临时文件夹（131.1 MB）（trash/keep/ignore，默认 keep）
  - 25 个 wings-*，在系统临时目录里
  - 选项：会议录像 2023 全年合集.mov（41.9 MB）（trash/keep/ignore，默认 keep）
  - 13 个月没打开过
  - 选项：已经删掉的应用「removed」留下的数据（4.2 MB）（trash/keep/ignore，默认 keep）
  - 选项：很久没动过的项目「old-pushed」（147 KB）（trash/keep/ignore，默认 keep）
  - 选项：会跟着电脑一起启动的「gone」（trash/keep/ignore，默认 keep）
  - 开机后在后台自动运行。不认识可以移除。
  - 按钮：「按上面的选择清理」→ `scan_apply`
  - （分隔线）
  - 要你看看 4
  - 硬盘没加密：电脑丢了，别人能直接读出里面的东西
  - 打开时会给你一个恢复密钥，抄下来放好。
  - 按钮：「打开 FileVault 设置」→ `scan_open_settings`
  - 「gone」已经删掉了却还在运行
  - 它会跟着开机启动，重启后还会再运行。 / 要停掉它：把上面「会跟着电脑一起启动的『gone』」改成「移到废纸篓」，清理后重启一下电脑。
  - 2 个已删除的应用仍有权限
  - 「tool」、「removed」 / 在系统设置中选中它们，点「−」移除。
  - 按钮：「打开「录屏」」→ `scan_open_settings`、「打开「完全磁盘访问」」→ `scan_open_settings`
  - （分隔线）
  - 自动清理
  - 按钮：「打开自动清理」→ `scan_autoclean`
  - 打开后，每天那一轮不用你点就清：会重建的缓存、装好了的应用的安装包、下载文件夹里的重复文件、测试工具留下的临时文件夹。移到废纸篓的都能放回，要你定的照样先问你。
  - 病毒库更新于 10月20日
- 基础页 `page/mac`：
  - 硬盘还剩
  - 182.0 GB
  - 一年多没打开过的大文件
  - 1 个
  - 安全设置（1 项没查成）
  - 1 项没开启
  - 上次扫描：10月20日 22:00
  - 按钮：「现在查一下」→ `scan_now`
  - （分隔线）
  - 硬盘
  - 用了 312.0 GB，一共 494.0 GB
  - （分隔线）
  - 占地方最多的文件夹
  - 临时文件
  - 262.2 MB
  - 开发工具的缓存
  - 64.0 MB
  - 下载
  - 42.0 MB
  - 已经删掉的应用留下的数据（5 个应用）
  - 11.5 MB
  - Projects
  - 3.4 MB
  - 几个应用共用的数据
  - 3.1 MB
  - Present 的缓存
  - 2.1 MB
  - 这些加起来约 388 MB。其余是没列出来的小文件夹，以及系统和应用本身。
  - （分隔线）
  - 一年多没打开过的大文件
  - 1 MB 以上算大文件，按大小排
  - 会议录像 2023 全年合集.mov
  - 41.9 MB
  - 按钮：「在访达里显示」→ `scan_reveal`
  - （分隔线）
  - 权限
  - 完全磁盘访问
  - 已允许
  - 已经删掉的应用还拿着权限
  - 2 个
  - 要收回，去「概览」看。
  - （分隔线）
  - 安全设置
  - 硬盘加密（文件保险箱）
  - 没开启
  - 只打开来路清楚的应用
  - 没查成
  - 防火墙
  - 已开启
  - 系统完整性保护
  - 已开启
  - 锁屏要密码
  - 已开启
  - 自动检查系统更新
  - 已开启
  - 没开启的怎么打开，在「概览」的「要你看看的」里有写。
  - 没查成的，下次扫描或点上面的「现在查一下」时会再查。
- 基础页 `page/cleaned`：
  - **清理记录**
  - 还没清理过。

**窗口上**

- 「状态」页（`page/mac`）：第一轮是没允许的样子（`read-page-mac-before-fda.json`）；第二轮下载进了「占地方最多的文件夹」，大视频进了「一年多没打开过的大文件」，标题和合计句换成允许以后的说法。

**文件**（按请求的先后）

| 文件 | 请求 | 什么时候 |
|---|---|---|
| `read-outbox-before-fda.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:00:00Z：读 outbox（每分钟一次） |
| `read-summary-before-fda.json` | resources/read `summary` | 2026-10-20T12:00:00Z：读概览（侧栏的计数和一句话） |
| `read-permissions-before-fda.json` | resources/read `permissions` | 2026-10-20T12:00:00Z：读权限的状态 |
| `read-page-overview-before-fda.json` | resources/read `page/overview` | 2026-10-20T12:00:00Z：读基础页 page/overview |
| `read-page-mac-before-fda.json` | resources/read `page/mac` | 2026-10-20T12:00:00Z：读基础页 page/mac |
| `read-page-cleaned-before-fda.json` | resources/read `page/cleaned` | 2026-10-20T12:00:00Z：读基础页 page/cleaned |
| `server-discover.json` | server/discover | 2026-10-20T14:00:00Z：server/discover |
| `tools-list.json` | tools/list | 2026-10-20T14:00:00Z：列工具（agent 认 readOnlyHint） |
| `resources-list.json` | resources/list | 2026-10-20T14:00:00Z：列资源 |
| `read-outbox.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T14:00:00Z：读 outbox（每分钟一次） |
| `read-summary.json` | resources/read `summary` | 2026-10-20T14:00:00Z：读概览（侧栏的计数和一句话） |
| `read-permissions.json` | resources/read `permissions` | 2026-10-20T14:00:00Z：读权限的状态 |
| `read-page-overview.json` | resources/read `page/overview` | 2026-10-20T14:00:00Z：读基础页 page/overview |
| `read-page-mac.json` | resources/read `page/mac` | 2026-10-20T14:00:00Z：读基础页 page/mac |
| `read-page-cleaned.json` | resources/read `page/cleaned` | 2026-10-20T14:00:00Z：读基础页 page/cleaned |

## `decide-3`：要你决定 3 项的清理方案

查完一轮，没有急事。清理方案三项：pip 的缓存（放心删：会自己重建，删了马上腾出空间）、测试留下的 25 个临时文件夹和一个推送过的老项目（要确认，默认先不动）；下面另列要去系统设置里收回的权限、进不了方案的一条和一条高风险提醒。

**怎么录的**：blackbox/fx.py 造的假目录：blackbox/cases/base.py 的 `build`（照单元测试的 Fixture.build 摆），fakes.json 是 `fx.standard_fakes`（和单元测试的 Fixture.Fakes.standard 一样），另加一块 494 GB、还剩 182 GB 的硬盘；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）；luoke-scan scan --fixture $FIXTURE --clock 2026-10-17T12:00:00Z（3 天前查过一轮：pip 的缓存还是空的）。

假目录改过：pip 的缓存长到 60 MB；删掉了 ~/Downloads/eicar-test.com；删掉了 ~/Downloads/update.scpt；删掉了 ~/Library/LaunchAgents/io.example.gone.plist；删掉了 ~/Library/Application Support/io.example.removed；删掉了 ~/Library/Preferences/io.example.removed.plist；删掉了 ~/Library/Group Containers/ABCDE12345.io.example.removed；删掉了 ~/Library/Containers/ABCDE12345.io.example.removed。

**扫描报的**

- 概览（`summary`）：count 8，「能清出 62.9 MB，另外 7 项等你处理」
- 权限（`permissions`）：`admin` ask、`auto` off、`fda` granted
- outbox：1 件
  - `round/2026-10-20T12:00:00Z`：`findings`、`low` → 顺便看看（later）
    - 标题：能清出 62.9 MB，另外 7 项等你处理
    - 摘要：会重建的缓存 1 项，不用你选；另外 7 项在「螺壳扫描」里等你看。
    - 卡片（surface `round-000000000001`）：
      - **能清出 62.9 MB**
      - 会重建的缓存 1 项，不用你选；另外 7 项在「螺壳扫描」里等你看。
      - 按钮：「清理 1 项缓存」→ `scan_apply`、「打开自动清理」→ `scan_autoclean`
- 基础页 `page/overview`：
  - **扫描**
  - 上次查 10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - 这周清掉
  - 还没清过
  - 能清出
  - 62.9 MB
  - 等你处理
  - 7 项
  - （分隔线）
  - 可以清掉 4
  - 会自动重建的缓存 1 项（62.9 MB）
  - pip
  - 按钮：「清理」→ `scan_apply`
  - 选项：wings 留下的临时文件夹（131.1 MB）（trash/keep/ignore，默认 keep）
  - 25 个 wings-*，在系统临时目录里
  - 选项：已经删掉的应用「stillused」留下的数据（2.1 MB）（trash/keep/ignore，默认 keep）
  - 选项：很久没动过的项目「old-pushed」（147 KB）（trash/keep/ignore，默认 keep）
  - 按钮：「按上面的选择清理」→ `scan_apply`
  - （分隔线）
  - 要你看看 4
  - 硬盘没加密：电脑丢了，别人能直接读出里面的东西
  - 打开时会给你一个恢复密钥，抄下来放好。
  - 按钮：「打开 FileVault 设置」→ `scan_open_settings`
  - 「gone」已经删掉了却还在运行
  - 重启一下电脑就好。
  - 2 个已删除的应用仍有权限
  - 「tool」、「removed」 / 在系统设置中选中它们，点「−」移除。
  - 按钮：「打开「录屏」」→ `scan_open_settings`、「打开「完全磁盘访问」」→ `scan_open_settings`
  - （分隔线）
  - 自动清理
  - 按钮：「打开自动清理」→ `scan_autoclean`
  - 打开后，每天那一轮不用你点就清：会重建的缓存、装好了的应用的安装包、下载文件夹里的重复文件、测试工具留下的临时文件夹。移到废纸篓的都能放回，要你定的照样先问你。
  - 病毒库更新于 10月20日
- 基础页 `page/mac`：
  - 硬盘还剩
  - 182.0 GB
  - 一年多没打开过的大文件
  - 没有
  - 安全设置（1 项没查成）
  - 1 项没开启
  - 上次扫描：10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - （分隔线）
  - 硬盘
  - 用了 312.0 GB，一共 494.0 GB
  - （分隔线）
  - 占地方最多的文件夹
  - 临时文件
  - 262.2 MB
  - 开发工具的缓存
  - 64.0 MB
  - 已经删掉的应用留下的数据（5 个应用）
  - 11.5 MB
  - Projects
  - 3.4 MB
  - Present 的缓存
  - 2.1 MB
  - 几个应用共用的数据
  - 2.1 MB
  - 这些加起来约 345 MB。其余是没列出来的小文件夹，以及系统和应用本身。
  - （分隔线）
  - 一年多没打开过的大文件
  - 1 MB 以上算大文件，按大小排
  - 没找到一年多没打开过的大文件。
  - （分隔线）
  - 权限
  - 完全磁盘访问
  - 已允许
  - 已经删掉的应用还拿着权限
  - 2 个
  - 要收回，去「概览」看。
  - （分隔线）
  - 安全设置
  - 硬盘加密（文件保险箱）
  - 没开启
  - 只打开来路清楚的应用
  - 没查成
  - 防火墙
  - 已开启
  - 系统完整性保护
  - 已开启
  - 锁屏要密码
  - 已开启
  - 自动检查系统更新
  - 已开启
  - 没开启的怎么打开，在「概览」的「要你看看的」里有写。
  - 没查成的，下次扫描或点上面的「现在查一下」时会再查。
- 基础页 `page/cleaned`：
  - **清理记录**
  - 还没清理过。

**窗口上**

- 一轮的那件是 `findings`、`low`：照 agent 现在的分段规则在「顺便看看」，不在「要你决定」（见下面「要对齐的」）。
- 卡片（luoke-scan#129）：标题「能清出 X」，一行「会重建的缓存 N 项，不用你选；另外 M 项在「螺壳扫描」里等你看」，按钮「清理 N 项缓存」（`scan_apply`，`choices` 直接写着只删缓存的那几项）。
- 扫描页（`page/overview`）：「可以清掉」在「要你看看」前面；缓存合成一行带自己的「清理」，别的每项一个 `ChoicePicker`（移到废纸篓 / 先不动 / 以后别提），下面一行小字写是什么；按钮「按上面的选择清理」把 `/choices` 换成当时的选项转给 `scan_apply`。
- 点完答复带 `done: false`：卡片还在，换成「已删掉会重建的缓存 N 项（腾出 X）；另外 M 项在「螺壳扫描」里等你看」（核心认 `openPage` 时那一句换成按钮「去扫描页看 M 项」），这一件留在 outbox 里；没有别的要看了才撤下。

**文件**（按请求的先后）

| 文件 | 请求 | 什么时候 |
|---|---|---|
| `server-discover.json` | server/discover | 2026-10-20T12:00:00Z：server/discover |
| `tools-list.json` | tools/list | 2026-10-20T12:00:00Z：列工具（agent 认 readOnlyHint） |
| `resources-list.json` | resources/list | 2026-10-20T12:00:00Z：列资源 |
| `read-outbox.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:00:00Z：读 outbox（每分钟一次） |
| `read-summary.json` | resources/read `summary` | 2026-10-20T12:00:00Z：读概览（侧栏的计数和一句话） |
| `read-permissions.json` | resources/read `permissions` | 2026-10-20T12:00:00Z：读权限的状态 |
| `read-page-overview.json` | resources/read `page/overview` | 2026-10-20T12:00:00Z：读基础页 page/overview |
| `read-page-mac.json` | resources/read `page/mac` | 2026-10-20T12:00:00Z：读基础页 page/mac |
| `read-page-cleaned.json` | resources/read `page/cleaned` | 2026-10-20T12:00:00Z：读基础页 page/cleaned |
| `call-scan_findings.json` | tools/call `scan_findings` | 2026-10-20T12:00:00Z：对话里问「要我看的是哪些」：模型调 scan_findings（只读） |
| `call-scan_apply.json` | tools/call `scan_apply`（带 user-action） | 2026-10-20T12:05:00Z：用户在一轮的卡片上点「清理 1 项缓存」（只删会重建的缓存） |
| `read-outbox-after-apply.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:05:00Z：点完再读 outbox |
| `read-summary-after-apply.json` | resources/read `summary` | 2026-10-20T12:05:00Z：点完再读概览 |

`call-scan_findings.json` 答：「[要确认] 进程 100（gone）的程序已经被删掉了，它还在跑 / [要确认] /opt/gone/tool 已经不在这台 Mac 上，还拿着「录屏」 / [要确认] io.example.removed 已经不在这台 Mac 上，还拿着「完全磁盘访问」 / [要确认] 临时目录里有 25 个 wings-* 没被删掉，共 131.1 MB / [要确认] io.example.stillused 的数据还在，但这台 Mac 上没有这个应用 / [要确认] old-pushed 半年多没动过，都已推送，删了能从远程找回」（新卡片）

`call-scan_apply.json` 答：「删掉会重建的缓存 1 项（腾出 62.9 MB）。」（done: false，更新原卡片）

## `malware`：下载里有报毒的文件

下载文件夹里有一个病毒库认得的文件（eicar 测试文件）和一个伪造系统密码框的脚本。每个一件急事，一轮的卡片上也列着它们（默认先不动）。

**怎么录的**：blackbox/fx.py 造的假目录：blackbox/cases/base.py 的 `build`（照单元测试的 Fixture.build 摆），fakes.json 是 `fx.standard_fakes`（和单元测试的 Fixture.Fakes.standard 一样），另加一块 494 GB、还剩 182 GB 的硬盘；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）；luoke-scan scan --fixture $FIXTURE --clock 2026-10-17T12:00:00Z（3 天前查过一轮：pip 的缓存还是空的）。

假目录改过：pip 的缓存长到 60 MB。

**扫描报的**

- 概览（`summary`）：count 12，「11 项等你处理，其中 2 项要尽快」
- 权限（`permissions`）：`admin` ask、`auto` off、`fda` granted
- outbox：3 件
  - `security/malware.clamav/000000000003`：`security`、`urgent` → 急事（urgent）
    - 标题：下载里的「eicar-test.com」可能是病毒
    - 摘要：下载里的「eicar-test.com」可能是病毒。病毒库认出了它。建议移到废纸篓，先不要打开。
    - 卡片（surface `security-000000000001`）：
      - **下载里的「eicar-test.com」可能是病毒**
      - 病毒库认出了它。建议移到废纸篓，先不要打开。
      - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - `security/malware.yara.luoke_fake_password_dialog/000000000006`：`security`、`urgent` → 急事（urgent）
    - 标题：下载里的「update.scpt」可能是病毒
    - 摘要：下载里的「update.scpt」可能是病毒。病毒库认出了它。建议移到废纸篓，先不要打开。
    - 卡片（surface `security-000000000004`）：
      - **下载里的「update.scpt」可能是病毒**
      - 病毒库认出了它。建议移到废纸篓，先不要打开。
      - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - `round/2026-10-20T12:00:00Z`：`findings`、`low` → 顺便看看（later）
    - 标题：能清出 62.9 MB，另外 9 项等你处理
    - 摘要：会重建的缓存 1 项，不用你选；另外 9 项在「螺壳扫描」里等你看。
    - 卡片（surface `round-000000000007`）：
      - **能清出 62.9 MB**
      - 会重建的缓存 1 项，不用你选；另外 9 项在「螺壳扫描」里等你看。
      - 按钮：「清理 1 项缓存」→ `scan_apply`、「打开自动清理」→ `scan_autoclean`
- 基础页 `page/overview`：
  - **扫描**
  - 上次查 10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - 这周清掉
  - 还没清过
  - 能清出
  - 62.9 MB
  - 等你处理
  - 11 项
  - （分隔线）
  - 要尽快处理 2
  - 下载里的「eicar-test.com」可能是病毒
  - 病毒库认出了它。建议移到废纸篓，先不要打开。
  - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - 下载里的「update.scpt」可能是病毒
  - 病毒库认出了它。建议移到废纸篓，先不要打开。
  - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - （分隔线）
  - 可以清掉 6
  - 会自动重建的缓存 1 项（62.9 MB）
  - pip
  - 按钮：「清理」→ `scan_apply`
  - 选项：wings 留下的临时文件夹（131.1 MB）（trash/keep/ignore，默认 keep）
  - 25 个 wings-*，在系统临时目录里
  - 选项：已经删掉的应用「removed」留下的数据（4.2 MB）（trash/keep/ignore，默认 keep）
  - 选项：已经删掉的应用「stillused」留下的数据（2.1 MB）（trash/keep/ignore，默认 keep）
  - 选项：很久没动过的项目「old-pushed」（147 KB）（trash/keep/ignore，默认 keep）
  - 选项：会跟着电脑一起启动的「gone」（trash/keep/ignore，默认 keep）
  - 开机后在后台自动运行。不认识可以移除。
  - 按钮：「按上面的选择清理」→ `scan_apply`
  - （分隔线）
  - 要你看看 4
  - 硬盘没加密：电脑丢了，别人能直接读出里面的东西
  - 打开时会给你一个恢复密钥，抄下来放好。
  - 按钮：「打开 FileVault 设置」→ `scan_open_settings`
  - 「gone」已经删掉了却还在运行
  - 它会跟着开机启动，重启后还会再运行。 / 要停掉它：把上面「会跟着电脑一起启动的『gone』」改成「移到废纸篓」，清理后重启一下电脑。
  - 2 个已删除的应用仍有权限
  - 「tool」、「removed」 / 在系统设置中选中它们，点「−」移除。
  - 按钮：「打开「录屏」」→ `scan_open_settings`、「打开「完全磁盘访问」」→ `scan_open_settings`
  - （分隔线）
  - 自动清理
  - 按钮：「打开自动清理」→ `scan_autoclean`
  - 打开后，每天那一轮不用你点就清：会重建的缓存、装好了的应用的安装包、下载文件夹里的重复文件、测试工具留下的临时文件夹。移到废纸篓的都能放回，要你定的照样先问你。
  - 病毒库更新于 10月20日
- 基础页 `page/mac`：
  - 硬盘还剩
  - 182.0 GB
  - 一年多没打开过的大文件
  - 没有
  - 安全设置（1 项没查成）
  - 1 项没开启
  - 上次扫描：10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - （分隔线）
  - 硬盘
  - 用了 312.0 GB，一共 494.0 GB
  - （分隔线）
  - 占地方最多的文件夹
  - 临时文件
  - 262.2 MB
  - 开发工具的缓存
  - 64.0 MB
  - 已经删掉的应用留下的数据（5 个应用）
  - 11.5 MB
  - Projects
  - 3.4 MB
  - 几个应用共用的数据
  - 3.1 MB
  - Present 的缓存
  - 2.1 MB
  - 这些加起来约 346 MB。其余是没列出来的小文件夹，以及系统和应用本身。
  - （分隔线）
  - 一年多没打开过的大文件
  - 1 MB 以上算大文件，按大小排
  - 没找到一年多没打开过的大文件。
  - （分隔线）
  - 权限
  - 完全磁盘访问
  - 已允许
  - 已经删掉的应用还拿着权限
  - 2 个
  - 要收回，去「概览」看。
  - （分隔线）
  - 安全设置
  - 硬盘加密（文件保险箱）
  - 没开启
  - 只打开来路清楚的应用
  - 没查成
  - 防火墙
  - 已开启
  - 系统完整性保护
  - 已开启
  - 锁屏要密码
  - 已开启
  - 自动检查系统更新
  - 已开启
  - 没开启的怎么打开，在「概览」的「要你看看的」里有写。
  - 没查成的，下次扫描或点上面的「现在查一下」时会再查。
- 基础页 `page/cleaned`：
  - **清理记录**
  - 还没清理过。

**窗口上**

- 两件 `security`、`urgent`：急事横幅，菜单栏图标多一个小点，按「主动提醒」的设置发通知。
- 急事卡片上：「移到废纸篓」（`scan_apply`，方案只有这一项）、「在访达里显示」（`scan_reveal`，只在 Mac 上）、「不是病毒」（`scan_ignore`）。点了以后卡片换成一行「已记下：……以后不再提醒。」带「撤销」（`scan_ignore`，`undo: true`）。
- 点完答复带 `done: true`，这一件从 outbox 撤下；一轮的那件还在，它的方案里少了已经处理的那两项。

**文件**（按请求的先后）

| 文件 | 请求 | 什么时候 |
|---|---|---|
| `server-discover.json` | server/discover | 2026-10-20T12:00:00Z：server/discover |
| `tools-list.json` | tools/list | 2026-10-20T12:00:00Z：列工具（agent 认 readOnlyHint） |
| `resources-list.json` | resources/list | 2026-10-20T12:00:00Z：列资源 |
| `read-outbox.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:00:00Z：读 outbox（每分钟一次） |
| `read-summary.json` | resources/read `summary` | 2026-10-20T12:00:00Z：读概览（侧栏的计数和一句话） |
| `read-permissions.json` | resources/read `permissions` | 2026-10-20T12:00:00Z：读权限的状态 |
| `read-page-overview.json` | resources/read `page/overview` | 2026-10-20T12:00:00Z：读基础页 page/overview |
| `read-page-mac.json` | resources/read `page/mac` | 2026-10-20T12:00:00Z：读基础页 page/mac |
| `read-page-cleaned.json` | resources/read `page/cleaned` | 2026-10-20T12:00:00Z：读基础页 page/cleaned |
| `call-outbox_ack-shown.json` | tools/call `outbox_ack` | 2026-10-20T12:02:00Z：agent 把急事说给用户以后记一下（outbox_ack shown） |
| `call-scan_apply.json` | tools/call `scan_apply`（带 user-action） | 2026-10-20T12:02:00Z：用户在 eicar 那张急事卡片上点「移到废纸篓」 |
| `call-scan_ignore.json` | tools/call `scan_ignore`（带 user-action） | 2026-10-20T12:02:00Z：用户在 update.scpt 那张上点「不是病毒」：卡片换成一行「已记下：「update.scpt」以后不再提醒。」和「撤销」 |
| `read-outbox-after.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:02:00Z：点完再读 outbox |
| `read-summary-after.json` | resources/read `summary` | 2026-10-20T12:02:00Z：点完再读概览 |

`call-outbox_ack-shown.json` 答：「记下了。」

`call-scan_apply.json` 答：「移到废纸篓 1 项（4 KB）。」（done: true，更新原卡片）

`call-scan_ignore.json` 答：「已记下：「update.scpt」以后不再提醒。」（done: true，更新原卡片）

## `cleaned-restore`：清理过，清理记录里能放回

用户在扫描页上把临时文件夹改成移到废纸篓，点了「按上面的选择清理」：25 个临时文件夹进了废纸篓（缓存有自己的「清理」，这一下不动它）。一小时后打开扫描的「清理记录」页，那一批有「放回」；点了以后整批回到原处。

**怎么录的**：blackbox/fx.py 造的假目录：blackbox/cases/base.py 的 `build`（照单元测试的 Fixture.build 摆），fakes.json 是 `fx.standard_fakes`（和单元测试的 Fixture.Fakes.standard 一样），另加一块 494 GB、还剩 182 GB 的硬盘；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）；luoke-scan scan --fixture $FIXTURE --clock 2026-10-17T12:00:00Z（3 天前查过一轮：pip 的缓存还是空的）。

假目录改过：pip 的缓存长到 60 MB；删掉了 ~/Downloads/eicar-test.com；删掉了 ~/Downloads/update.scpt；删掉了 ~/Library/LaunchAgents/io.example.gone.plist；删掉了 ~/Library/Application Support/io.example.removed；删掉了 ~/Library/Preferences/io.example.removed.plist；删掉了 ~/Library/Group Containers/ABCDE12345.io.example.removed；删掉了 ~/Library/Containers/ABCDE12345.io.example.removed。

**扫描报的**

- 概览（`summary`）：count 8，「能清出 62.9 MB，另外 7 项等你处理」
- 权限（`permissions`）：`admin` ask、`auto` off、`fda` granted
- outbox：0 件
- 基础页 `page/overview`：
  - **扫描**
  - 上次查 10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - 这周清掉
  - 还没清过
  - 能清出
  - 62.9 MB
  - 等你处理
  - 7 项
  - （分隔线）
  - 可以清掉 4
  - 会自动重建的缓存 1 项（62.9 MB）
  - pip
  - 按钮：「清理」→ `scan_apply`
  - 选项：wings 留下的临时文件夹（131.1 MB）（trash/keep/ignore，默认 keep）
  - 25 个 wings-*，在系统临时目录里
  - 选项：已经删掉的应用「stillused」留下的数据（2.1 MB）（trash/keep/ignore，默认 keep）
  - 选项：很久没动过的项目「old-pushed」（147 KB）（trash/keep/ignore，默认 keep）
  - 按钮：「按上面的选择清理」→ `scan_apply`
  - （分隔线）
  - 要你看看 4
  - 硬盘没加密：电脑丢了，别人能直接读出里面的东西
  - 打开时会给你一个恢复密钥，抄下来放好。
  - 按钮：「打开 FileVault 设置」→ `scan_open_settings`
  - 「gone」已经删掉了却还在运行
  - 重启一下电脑就好。
  - 2 个已删除的应用仍有权限
  - 「tool」、「removed」 / 在系统设置中选中它们，点「−」移除。
  - 按钮：「打开「录屏」」→ `scan_open_settings`、「打开「完全磁盘访问」」→ `scan_open_settings`
  - （分隔线）
  - 自动清理
  - 按钮：「打开自动清理」→ `scan_autoclean`
  - 打开后，每天那一轮不用你点就清：会重建的缓存、装好了的应用的安装包、下载文件夹里的重复文件、测试工具留下的临时文件夹。移到废纸篓的都能放回，要你定的照样先问你。
  - 病毒库更新于 10月20日
- 基础页 `page/mac`：
  - 硬盘还剩
  - 182.0 GB
  - 一年多没打开过的大文件
  - 没有
  - 安全设置（1 项没查成）
  - 1 项没开启
  - 上次扫描：10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - （分隔线）
  - 硬盘
  - 用了 312.0 GB，一共 494.0 GB
  - （分隔线）
  - 占地方最多的文件夹
  - 临时文件
  - 262.2 MB
  - 开发工具的缓存
  - 64.0 MB
  - 已经删掉的应用留下的数据（5 个应用）
  - 11.5 MB
  - Projects
  - 3.4 MB
  - Present 的缓存
  - 2.1 MB
  - 几个应用共用的数据
  - 2.1 MB
  - 这些加起来约 345 MB。其余是没列出来的小文件夹，以及系统和应用本身。
  - （分隔线）
  - 一年多没打开过的大文件
  - 1 MB 以上算大文件，按大小排
  - 没找到一年多没打开过的大文件。
  - （分隔线）
  - 权限
  - 完全磁盘访问
  - 已允许
  - 已经删掉的应用还拿着权限
  - 2 个
  - 要收回，去「概览」看。
  - （分隔线）
  - 安全设置
  - 硬盘加密（文件保险箱）
  - 没开启
  - 只打开来路清楚的应用
  - 没查成
  - 防火墙
  - 已开启
  - 系统完整性保护
  - 已开启
  - 锁屏要密码
  - 已开启
  - 自动检查系统更新
  - 已开启
  - 没开启的怎么打开，在「概览」的「要你看看的」里有写。
  - 没查成的，下次扫描或点上面的「现在查一下」时会再查。
- 基础页 `page/cleaned`：
  - **清理记录**
  - （分隔线）
  - 你清的：临时目录里有 25 个 wings-* 没被删掉，共 131.1 MB 等 25 项
  - 10月20日 20:05
  - 「放回」把还在废纸篓里的 25 项放回原来的位置。
  - 按钮：「放回」→ `scan_restore`

**窗口上**

- 「清理记录」页（`page/cleaned`）一批一段：「你清的：……（大小）」、时间、按钮「放回」（`scan_restore`，参数是批次 `p-…`）。
- 页上的按钮照卡片走 `POST /action`，`ai.luoke/user-action` 的 `surfaceId` 是页 id `cleaned`；答复里的卡片不画，窗口重新读这一页：那一批写「已放回」，「放回」按钮没了。

**文件**（按请求的先后）

| 文件 | 请求 | 什么时候 |
|---|---|---|
| `server-discover.json` | server/discover | 2026-10-20T12:05:00Z：server/discover |
| `tools-list.json` | tools/list | 2026-10-20T12:05:00Z：列工具（agent 认 readOnlyHint） |
| `resources-list.json` | resources/list | 2026-10-20T12:05:00Z：列资源 |
| `read-outbox-before.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:05:00Z：读 outbox（每分钟一次） |
| `read-summary-before.json` | resources/read `summary` | 2026-10-20T12:05:00Z：读概览（侧栏的计数和一句话） |
| `read-permissions-before.json` | resources/read `permissions` | 2026-10-20T12:05:00Z：读权限的状态 |
| `read-page-overview-before.json` | resources/read `page/overview` | 2026-10-20T12:05:00Z：读基础页 page/overview |
| `read-page-mac-before.json` | resources/read `page/mac` | 2026-10-20T12:05:00Z：读基础页 page/mac |
| `read-page-cleaned-before.json` | resources/read `page/cleaned` | 2026-10-20T12:05:00Z：读基础页 page/cleaned |
| `call-scan_apply.json` | tools/call `scan_apply`（带 user-action） | 2026-10-20T12:05:00Z：用户在扫描页上把临时文件夹改成移到废纸篓，点「按上面的选择清理」 |
| `read-outbox.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T13:00:00Z：读 outbox（每分钟一次） |
| `read-summary.json` | resources/read `summary` | 2026-10-20T13:00:00Z：读概览（侧栏的计数和一句话） |
| `read-permissions.json` | resources/read `permissions` | 2026-10-20T13:00:00Z：读权限的状态 |
| `read-page-overview.json` | resources/read `page/overview` | 2026-10-20T13:00:00Z：读基础页 page/overview |
| `read-page-mac.json` | resources/read `page/mac` | 2026-10-20T13:00:00Z：读基础页 page/mac |
| `read-page-cleaned.json` | resources/read `page/cleaned` | 2026-10-20T13:00:00Z：读基础页 page/cleaned |
| `call-scan_restore.json` | tools/call `scan_restore`（带 user-action） | 2026-10-20T13:05:00Z：用户在「清理记录」页上点那一批的「放回」 |
| `read-page-cleaned-after-restore.json` | resources/read `page/cleaned` | 2026-10-20T13:05:00Z：点完窗口重新读这一页 |
| `read-permissions-after-restore.json` | resources/read `permissions` | 2026-10-20T13:05:00Z：点完再读权限（点的方案放回不关自动清） |

`call-scan_apply.json` 答：「移到废纸篓 1 项（131.1 MB）。」（done: true，更新原卡片）

`call-scan_restore.json` 答：「放回了 25 项。」（done: true，更新原卡片）

## `autoclean-done`：不用点就清了 4 类

用户之前在设置里打开了自动清（默认关）。主控在空闲时跑了每天那一轮（`scan --autoclean`）：查完把四类不用点就清的清掉了：pip 的缓存直接删（会重建），装好了的应用的安装包、下载里的重复文件、Puppeteer 留下的临时文件夹移进废纸篓（能放回）。用户回来看到报告，先点了「放回」，又点了「关掉自动清理」。

**怎么录的**：blackbox/fx.py 造的假目录：blackbox/cases/base.py 的 `build`（照单元测试的 Fixture.build 摆），fakes.json 是 `fx.standard_fakes`（和单元测试的 Fixture.Fakes.standard 一样），另加一块 494 GB、还剩 182 GB 的硬盘；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）；luoke-scan scan --fixture $FIXTURE --clock 2026-10-17T12:00:00Z（3 天前查过一轮：pip 的缓存还是空的）。

假目录改过：pip 的缓存长到 60 MB；删掉了 ~/Downloads/eicar-test.com；删掉了 ~/Downloads/update.scpt；删掉了 ~/Library/LaunchAgents/io.example.gone.plist；删掉了 ~/Library/Application Support/io.example.removed；删掉了 ~/Library/Preferences/io.example.removed.plist；删掉了 ~/Library/Group Containers/ABCDE12345.io.example.removed；删掉了 ~/Library/Containers/ABCDE12345.io.example.removed；加了装好了的应用的安装包、文稿里也有一份的下载、21 个 Puppeteer 临时文件夹（都是 20 天前来的）；用户之前在设置里打开了自动清（默认关）：2026-10-20T07:12:00Z 带 user-action（surfaceId `settings`）调了 `scan_autoclean` `{"on": true}`。

**扫描报的**

- 概览（`summary`）：count 6，「6 项等你处理」
- 权限（`permissions`）：`admin` ask、`auto` on、`fda` granted
- outbox：1 件
  - `round/2026-10-20T12:00:00Z`：`auto-done`、`normal` → 已经替你做了（done）
    - 标题：自动移到废纸篓 23 项（118.6 MB），清了 62.9 MB 的工具缓存；6 项等你处理
    - 摘要：清了 62.9 MB 的工具缓存（pip），用到时会重新下载。移到废纸篓：装好了的应用的安装包 1 项（6.3 MB）、下载文件夹里的重复文件 1 项（2.1 MB）、测试工具留下的临时文件夹 21 项（110.2 MB）。另外 6 项在「螺壳扫描」里等你看。
    - 卡片（surface `round-000000000001`）：
      - **自动移到废纸篓 23 项（118.6 MB），清了 62.9 MB 的工具缓存**
      - 清了 62.9 MB 的工具缓存（pip），用到时会重新下载。移到废纸篓：装好了的应用的安装包 1 项（6.3 MB）、下载文件夹里的重复文件 1 项（2.1 MB）、测试工具留下的临时文件夹 21 项（110.2 MB）。
      - 装好了的应用的安装包：Fixtureapp-2.0.dmg
      - 下载文件夹里的重复文件：report-2026.pdf
      - 测试工具留下的临时文件夹：Puppeteer 留下的临时文件夹等 21 项
      - 按钮：「放回」→ `scan_restore`、「关掉自动清理」→ `scan_autoclean`
      - （分隔线）
      - **6 项等你处理**
      - 另外 6 项在「螺壳扫描」里等你看。
- 基础页 `page/overview`：
  - **扫描**
  - 上次查 10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - 这周清掉
  - 181.5 MB
  - 能清出
  - 没有
  - 等你处理
  - 6 项
  - （分隔线）
  - 可以清掉 2
  - 选项：wings 留下的临时文件夹（131.1 MB）（trash/keep/ignore，默认 keep）
  - 25 个 wings-*，在系统临时目录里
  - 选项：很久没动过的项目「old-pushed」（147 KB）（trash/keep/ignore，默认 keep）
  - 按钮：「按上面的选择清理」→ `scan_apply`
  - （分隔线）
  - 要你看看 4
  - 硬盘没加密：电脑丢了，别人能直接读出里面的东西
  - 打开时会给你一个恢复密钥，抄下来放好。
  - 按钮：「打开 FileVault 设置」→ `scan_open_settings`
  - 「gone」已经删掉了却还在运行
  - 重启一下电脑就好。
  - 2 个已删除的应用仍有权限
  - 「tool」、「removed」 / 在系统设置中选中它们，点「−」移除。
  - 按钮：「打开「录屏」」→ `scan_open_settings`、「打开「完全磁盘访问」」→ `scan_open_settings`
  - （分隔线）
  - 自动清理
  - 按钮：「关掉自动清理」→ `scan_autoclean`
  - 每天那一轮不用你点就清：会重建的缓存、装好了的应用的安装包、下载文件夹里的重复文件、测试工具留下的临时文件夹。移到废纸篓的都能放回，要你定的照样先问你。
  - 病毒库更新于 10月20日
- 基础页 `page/mac`：
  - 硬盘还剩
  - 182.0 GB
  - 一年多没打开过的大文件
  - 没有
  - 安全设置（1 项没查成）
  - 1 项没开启
  - 上次扫描：10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - （分隔线）
  - 硬盘
  - 用了 312.0 GB，一共 494.0 GB
  - （分隔线）
  - 占地方最多的文件夹
  - 临时文件
  - 372.3 MB
  - 开发工具的缓存
  - 64.0 MB
  - 已经删掉的应用留下的数据（5 个应用）
  - 11.5 MB
  - 下载
  - 8.4 MB
  - Projects
  - 3.4 MB
  - Present 的缓存
  - 2.1 MB
  - 几个应用共用的数据
  - 2.1 MB
  - 文稿
  - 2.1 MB
  - 这些加起来约 465 MB。其余是没列出来的小文件夹，以及系统和应用本身。
  - （分隔线）
  - 一年多没打开过的大文件
  - 1 MB 以上算大文件，按大小排
  - 没找到一年多没打开过的大文件。
  - （分隔线）
  - 权限
  - 完全磁盘访问
  - 已允许
  - 已经删掉的应用还拿着权限
  - 2 个
  - 要收回，去「概览」看。
  - （分隔线）
  - 安全设置
  - 硬盘加密（文件保险箱）
  - 没开启
  - 只打开来路清楚的应用
  - 没查成
  - 防火墙
  - 已开启
  - 系统完整性保护
  - 已开启
  - 锁屏要密码
  - 已开启
  - 自动检查系统更新
  - 已开启
  - 没开启的怎么打开，在「概览」的「要你看看的」里有写。
  - 没查成的，下次扫描或点上面的「现在查一下」时会再查。
- 基础页 `page/cleaned`：
  - **清理记录**
  - （分隔线）
  - 自动清理的：重复的 report-2026.pdf、安装包 Fixtureapp-2.0.dmg、Puppeteer 留下的临时文件夹等 24 项（181.5 MB）
  - 10月20日 20:00
  - 「放回」把还在废纸篓里的 23 项放回原来的位置；删掉的缓存不用放回，用到时会重建。
  - 按钮：「放回」→ `scan_restore`

**窗口上**

- 一轮的那件是 `auto-done`、`normal`：在「已经替你做了」；上半张说清了什么（[放回]、[关掉自动清理]），下半张是还要用户定的方案。
- 「放回」整批放回以后，放回过的那三类以后先问（`permissions.auto` 还是 `on`：缓存照清）；「关掉自动清理」以后 `auto` 是 `off`，概览页上自动清理的开关是关的，权限页的开关跟着变。

**文件**（按请求的先后）

| 文件 | 请求 | 什么时候 |
|---|---|---|
| `server-discover.json` | server/discover | 2026-10-20T12:01:00Z：server/discover |
| `tools-list.json` | tools/list | 2026-10-20T12:01:00Z：列工具（agent 认 readOnlyHint） |
| `resources-list.json` | resources/list | 2026-10-20T12:01:00Z：列资源 |
| `read-outbox.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:01:00Z：读 outbox（每分钟一次） |
| `read-summary.json` | resources/read `summary` | 2026-10-20T12:01:00Z：读概览（侧栏的计数和一句话） |
| `read-permissions.json` | resources/read `permissions` | 2026-10-20T12:01:00Z：读权限的状态 |
| `read-page-overview.json` | resources/read `page/overview` | 2026-10-20T12:01:00Z：读基础页 page/overview |
| `read-page-mac.json` | resources/read `page/mac` | 2026-10-20T12:01:00Z：读基础页 page/mac |
| `read-page-cleaned.json` | resources/read `page/cleaned` | 2026-10-20T12:01:00Z：读基础页 page/cleaned |
| `call-scan_restore.json` | tools/call `scan_restore`（带 user-action） | 2026-10-20T12:10:00Z：用户在自动清的卡片上点「放回」（整批放回，放回过的那几类以后先问） |
| `read-permissions-after-restore.json` | resources/read `permissions` | 2026-10-20T12:10:00Z：点完再读权限 |
| `read-outbox-after-restore.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:10:00Z：点完再读 outbox |
| `call-scan_autoclean-off.json` | tools/call `scan_autoclean`（带 user-action） | 2026-10-20T12:11:00Z：用户再点「关掉自动清理」 |
| `read-permissions-after-off.json` | resources/read `permissions` | 2026-10-20T12:11:00Z：点完再读权限 |
| `read-page-overview-after-off.json` | resources/read `page/overview` | 2026-10-20T12:11:00Z：再读概览页 |

`call-scan_restore.json` 答：「放回了 23 项。」（done: false，更新原卡片）

`call-scan_autoclean-off.json` 答：「好，以后都先问你再清。」（done: false，更新原卡片）

## `full-report`：用了一阵的开发机：一轮查出一长串

基础假目录不去掉东西（报毒的两个文件、坏了的 LaunchAgent、删了的应用留下的数据都在），再加上开发机上常见的：几样会重建的缓存、很久没用的模型、多年没打开过的视频、明文写在 MCP 设置里的密钥、从网上下载代码直接运行的 skill、临时签名的程序在看所有应用的按键。查完一轮：急事、一份很长的清理方案、一串螺壳不替你动的提醒都有。

**怎么录的**：blackbox/fx.py 造的假目录：blackbox/cases/base.py 的 `build`（照单元测试的 Fixture.build 摆），fakes.json 是 `fx.standard_fakes`（和单元测试的 Fixture.Fakes.standard 一样），另加一块 494 GB、还剩 182 GB 的硬盘；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）；luoke-scan scan --fixture $FIXTURE --clock 2026-10-17T12:00:00Z（3 天前查过一轮：pip 的缓存还是空的）；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）。

假目录改过：pip 的缓存长到 60 MB；Spotlight 报出三个一年多没打开过的大文件（一个名字很长）；装着微信和 Microsoft Teams（各有一些数据、缓存）；加了五样会重建的缓存（go-build、uv、npm、Xcode 的 DerivedData、Bun，各 52–58 MB）、25 天前下载的 Hugging Face 模型、8 年多没打开过的视频、Gemini 的 MCP 设置里明文写的密钥（别人也能读）、一个从网上下载代码直接运行的 skill、一个临时签名的程序在看所有应用的按键。

**扫描报的**

- 概览（`summary`）：count 22，「16 项等你处理，其中 2 项要尽快」
- 权限（`permissions`）：`admin` ask、`auto` off、`fda` granted
- outbox：3 件
  - `security/malware.clamav/000000000003`：`security`、`urgent` → 急事（urgent）
    - 标题：下载里的「eicar-test.com」可能是病毒
    - 摘要：下载里的「eicar-test.com」可能是病毒。病毒库认出了它。建议移到废纸篓，先不要打开。
    - 卡片（surface `security-000000000001`）：
      - **下载里的「eicar-test.com」可能是病毒**
      - 病毒库认出了它。建议移到废纸篓，先不要打开。
      - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - `security/malware.yara.luoke_fake_password_dialog/000000000006`：`security`、`urgent` → 急事（urgent）
    - 标题：下载里的「update.scpt」可能是病毒
    - 摘要：下载里的「update.scpt」可能是病毒。病毒库认出了它。建议移到废纸篓，先不要打开。
    - 卡片（surface `security-000000000004`）：
      - **下载里的「update.scpt」可能是病毒**
      - 病毒库认出了它。建议移到废纸篓，先不要打开。
      - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - `round/2026-10-20T12:00:00Z`：`findings`、`low` → 顺便看看（later）
    - 标题：能清出 349.2 MB，另外 14 项等你处理
    - 摘要：会重建的缓存 6 项，不用你选；另外 14 项在「螺壳扫描」里等你看。
    - 卡片（surface `round-000000000007`）：
      - **能清出 349.2 MB**
      - 会重建的缓存 6 项，不用你选；另外 14 项在「螺壳扫描」里等你看。
      - 按钮：「清理 6 项缓存」→ `scan_apply`、「打开自动清理」→ `scan_autoclean`
- 基础页 `page/overview`：
  - **扫描**
  - 上次查 10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - 这周清掉
  - 还没清过
  - 能清出
  - 349.2 MB
  - 等你处理
  - 16 项
  - （分隔线）
  - 要尽快处理 2
  - 下载里的「eicar-test.com」可能是病毒
  - 病毒库认出了它。建议移到废纸篓，先不要打开。
  - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - 下载里的「update.scpt」可能是病毒
  - 病毒库认出了它。建议移到废纸篓，先不要打开。
  - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - （分隔线）
  - 可以清掉 14
  - 会自动重建的缓存 6 项（349.2 MB）
  - pip、Go、uv、npm、Xcode、Bun
  - 按钮：「清理」→ `scan_apply`
  - 选项：wings 留下的临时文件夹（131.1 MB）（trash/keep/ignore，默认 keep）
  - 25 个 wings-*，在系统临时目录里
  - 选项：安装包「macOS Sonoma 安装程序 备份 2023 年 3 月最终版 (1).dmg」（31.5 MB）（trash/keep/ignore，默认 keep）
  - 400 天前下载
  - 选项：macOS Sonoma 安装程序 备份 2023 年 3 月最终版 (1).dmg（31.5 MB）（trash/keep/ignore，默认 keep）
  - 13 个月没打开过
  - 选项：二零二三年大学毕业典礼全程录像（含校长致辞和学生代表发言）完整版.mp4（21 MB）（trash/keep/ignore，默认 keep）
  - 20 个月没打开过
  - 选项：IMG_8519.MOV（12.6 MB）（trash/keep/ignore，默认 keep）
  - 8 年多没打开过
  - 选项：很久没动过的项目「old-pushed」（147 KB）（trash/keep/ignore，默认 keep）
  - 选项：「Claude Code」的插件「quick-setup」能操作你的电脑（trash/keep/ignore，默认 trash）
  - AI 用到它时，可能改动、删除或外传你的文件。不认识的建议移到废纸篓。
  - 按钮：「在访达里显示「quick-setup」」→ `scan_reveal`
  - 选项：会跟着电脑一起启动的「gone」（trash/keep/ignore，默认 keep）
  - 开机后在后台自动运行。不认识可以移除。
  - 按钮：「按上面的选择清理」→ `scan_apply`
  - （分隔线）
  - 要你看看 6
  - 「Keys」能读到你按的每一个键
  - 输入法、快捷键工具常这样；不认得就在「输入监控」里关掉它。
  - 按钮：「打开「输入监控」设置」→ `scan_open_settings`、「在访达里显示」→ `scan_reveal`
  - 有密码或密钥直接放在文件里，别人可能看得到
  - 换个地方存，或者把这个密码改掉。
  - 按钮：「在访达里显示」→ `scan_reveal`
  - 硬盘没加密：电脑丢了，别人能直接读出里面的东西
  - 打开时会给你一个恢复密钥，抄下来放好。
  - 按钮：「打开 FileVault 设置」→ `scan_open_settings`
  - 「gone」已经删掉了却还在运行
  - 它会跟着开机启动，重启后还会再运行。 / 要停掉它：把上面「会跟着电脑一起启动的『gone』」改成「移到废纸篓」，清理后重启一下电脑。
  - 2 个已删除的应用仍有权限
  - 「tool」、「removed」 / 在系统设置中选中它们，点「−」移除。
  - 按钮：「打开「录屏」」→ `scan_open_settings`、「打开「完全磁盘访问」」→ `scan_open_settings`
  - （分隔线）
  - 自动清理
  - 按钮：「打开自动清理」→ `scan_autoclean`
  - 打开后，每天那一轮不用你点就清：会重建的缓存、装好了的应用的安装包、下载文件夹里的重复文件、测试工具留下的临时文件夹。移到废纸篓的都能放回，要你定的照样先问你。
  - 病毒库更新于 10月20日
- 基础页 `page/mac`：
  - 硬盘还剩
  - 182.0 GB
  - 一年多没打开过的大文件
  - 3 个
  - 安全设置（1 项没查成）
  - 1 项没开启
  - 上次扫描：10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - （分隔线）
  - 硬盘
  - 用了 312.0 GB，一共 494.0 GB
  - （分隔线）
  - 占地方最多的文件夹
  - 开发工具的缓存
  - 358.6 MB
  - 临时文件
  - 262.2 MB
  - 下载
  - 31.5 MB
  - 影片
  - 21.0 MB
  - 图片
  - 12.6 MB
  - 已经删掉的应用留下的数据（5 个应用）
  - 11.5 MB
  - 微信的数据
  - 9.4 MB
  - Microsoft Teams 的缓存
  - 5.2 MB
  - 这些加起来约 712 MB。其余是没列出来的小文件夹，以及系统和应用本身。
  - （分隔线）
  - 一年多没打开过的大文件
  - 1 MB 以上算大文件，按大小排
  - macOS Sonoma 安装程序…月最终版 (1).dmg
  - 31.5 MB
  - 按钮：「在访达里显示」→ `scan_reveal`
  - 二零二三年大学毕业典礼…完整版.mp4
  - 21.0 MB
  - 按钮：「在访达里显示」→ `scan_reveal`
  - IMG_8519.MOV
  - 12.6 MB
  - 按钮：「在访达里显示」→ `scan_reveal`
  - （分隔线）
  - 权限
  - 完全磁盘访问
  - 已允许
  - 已经删掉的应用还拿着权限
  - 2 个
  - 要收回，去「概览」看。
  - （分隔线）
  - 安全设置
  - 硬盘加密（文件保险箱）
  - 没开启
  - 只打开来路清楚的应用
  - 没查成
  - 防火墙
  - 已开启
  - 系统完整性保护
  - 已开启
  - 锁屏要密码
  - 已开启
  - 自动检查系统更新
  - 已开启
  - 没开启的怎么打开，在「概览」的「要你看看的」里有写。
  - 没查成的，下次扫描或点上面的「现在查一下」时会再查。
- 基础页 `page/cleaned`：
  - **清理记录**
  - 还没清理过。

**窗口上**

- 急事卡片几张（报毒的文件、看按键的程序……），一轮的那件：「能清出 X，另外 N 项等你处理」，按钮只删会重建的缓存；扫描页上缓存合成一行，别的每项一个选择、一行小字写是什么，后面是「要你看看」的各类，各带一句能做的事和按钮。
- 窗口要画得下这么长的卡片：截图和真机上看到的一样长。

**文件**（按请求的先后）

| 文件 | 请求 | 什么时候 |
|---|---|---|
| `server-discover.json` | server/discover | 2026-10-20T12:00:00Z：server/discover |
| `tools-list.json` | tools/list | 2026-10-20T12:00:00Z：列工具（agent 认 readOnlyHint） |
| `resources-list.json` | resources/list | 2026-10-20T12:00:00Z：列资源 |
| `read-outbox.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:00:00Z：读 outbox（每分钟一次） |
| `read-summary.json` | resources/read `summary` | 2026-10-20T12:00:00Z：读概览（侧栏的计数和一句话） |
| `read-permissions.json` | resources/read `permissions` | 2026-10-20T12:00:00Z：读权限的状态 |
| `read-page-overview.json` | resources/read `page/overview` | 2026-10-20T12:00:00Z：读基础页 page/overview |
| `read-page-mac.json` | resources/read `page/mac` | 2026-10-20T12:00:00Z：读基础页 page/mac |
| `read-page-cleaned.json` | resources/read `page/cleaned` | 2026-10-20T12:00:00Z：读基础页 page/cleaned |

## `crowded`：用了很久的 Mac：能清的有几十项

基础假目录上再加：41 个已经装好的应用留下的安装包、node-gyp/Cargo/Gradle/Go/Composer 的缓存、7 组重复文件、5 个能自己运行命令的 AI 插件、4 个来路不明的应用（数目照 luoke-scan#129 里的一台真机）。

**怎么录的**：blackbox/fx.py 造的假目录：blackbox/cases/base.py 的 `build`（照单元测试的 Fixture.build 摆），fakes.json 是 `fx.standard_fakes`（和单元测试的 Fixture.Fakes.standard 一样），另加一块 494 GB、还剩 182 GB 的硬盘；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）；luoke-scan scan --fixture $FIXTURE --clock 2026-10-17T12:00:00Z（3 天前查过一轮：pip 的缓存还是空的）；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）。

假目录改过：pip 的缓存长到 60 MB；41 个已经装好的应用（AsterNote…GroveMail）和它们 30 天前下载的安装包（带下载标记、临时签名，文件名里好几个点）；node-gyp、Cargo、Gradle（两处）、Go、Composer 的缓存（各 51–54 MB）；7 组重复文件，文稿和下载里各一份，名字是百分号编码的；5 个从网上下载代码直接运行的 skill；4 个两天前来的、没有签名的应用。

**扫描报的**

- 概览（`summary`）：count 73，「66 项等你处理，其中 2 项要尽快」
- 权限（`permissions`）：`admin` ask、`auto` off、`fda` granted
- outbox：3 件
  - `security/malware.clamav/000000000003`：`security`、`urgent` → 急事（urgent）
    - 标题：下载里的「eicar-test.com」可能是病毒
    - 摘要：下载里的「eicar-test.com」可能是病毒。病毒库认出了它。建议移到废纸篓，先不要打开。
    - 卡片（surface `security-000000000001`）：
      - **下载里的「eicar-test.com」可能是病毒**
      - 病毒库认出了它。建议移到废纸篓，先不要打开。
      - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - `security/malware.yara.luoke_fake_password_dialog/000000000006`：`security`、`urgent` → 急事（urgent）
    - 标题：下载里的「update.scpt」可能是病毒
    - 摘要：下载里的「update.scpt」可能是病毒。病毒库认出了它。建议移到废纸篓，先不要打开。
    - 卡片（surface `security-000000000004`）：
      - **下载里的「update.scpt」可能是病毒**
      - 病毒库认出了它。建议移到废纸篓，先不要打开。
      - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - `round/2026-10-20T12:00:00Z`：`findings`、`low` → 顺便看看（later）
    - 标题：能清出 622 MB，另外 64 项等你处理
    - 摘要：会重建的缓存 7 项，不用你选；另外 64 项在「螺壳扫描」里等你看。
    - 卡片（surface `round-000000000007`）：
      - **能清出 622 MB**
      - 会重建的缓存 7 项，不用你选；另外 64 项在「螺壳扫描」里等你看。
      - 按钮：「清理 7 项缓存」→ `scan_apply`、「打开自动清理」→ `scan_autoclean`
- 基础页 `page/overview`：
  - **扫描**
  - 上次查 10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - 这周清掉
  - 还没清过
  - 能清出
  - 622 MB
  - 等你处理
  - 66 项
  - （分隔线）
  - 要尽快处理 2
  - 下载里的「eicar-test.com」可能是病毒
  - 病毒库认出了它。建议移到废纸篓，先不要打开。
  - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - 下载里的「update.scpt」可能是病毒
  - 病毒库认出了它。建议移到废纸篓，先不要打开。
  - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - （分隔线）
  - 可以清掉 63
  - 会自动重建的缓存 7 项（392.2 MB）
  - pip、Go、Cargo、Gradle、Composer、node-gyp
  - 按钮：「清理」→ `scan_apply`
  - 选项：已经装好的应用留下的安装包，一共 41 项（215.1 MB）（trash/keep/ignore，默认 trash）
  - 「AsterChat」、「AsterCode」、「AsterDraw」、「AsterMail」等，这 41 项一起处理
  - 选项：wings 留下的临时文件夹（131.1 MB）（trash/keep/ignore，默认 keep）
  - 25 个 wings-*，在系统临时目录里
  - 选项：7 组重复的文件（14.7 MB）（trash/clone/keep/ignore，默认 trash）
  - 「香港-4.v2.pdf」、「香港-6.v2.pdf」、「香港-2.v2.pdf」、「香港-0.v2.pdf」等，这 7 项一起处理
  - 选项：很久没动过的项目「old-pushed」（147 KB）（trash/keep/ignore，默认 keep）
  - 选项：5 个 AI 插件能操作你的电脑（trash/keep/ignore，默认 trash）
  - 「helper-0」、「helper-1」、「helper-2」、「helper-3」等，这 5 项一起处理 / AI 用到它们时，可能改动、删除或外传你的文件。不认识的建议移到废纸篓。
  - 在访达里逐个看（5 个）
  - 按钮：「在访达里显示「helper-0」」→ `scan_reveal`、「在访达里显示「helper-1」」→ `scan_reveal`、「在访达里显示「helper-2」」→ `scan_reveal`、「在访达里显示「helper-3」」→ `scan_reveal`、「在访达里显示「helper-4」」→ `scan_reveal`
  - 选项：会跟着电脑一起启动的「gone」（trash/keep/ignore，默认 keep）
  - 开机后在后台自动运行。不认识可以移除。
  - 按钮：「按上面的选择清理」→ `scan_apply`
  - （分隔线）
  - 要你看看 8
  - 硬盘没加密：电脑丢了，别人能直接读出里面的东西
  - 打开时会给你一个恢复密钥，抄下来放好。
  - 按钮：「打开 FileVault 设置」→ `scan_open_settings`
  - 4 个最近装的应用来路不明
  - 「Clipper.Pro」、「Notes Lite」、「Snap Tool 2.1」、「Viewer」 / 确认是你自己装的就好；不认识就移到废纸篓。
  - 在访达里逐个看（4 个）
  - 按钮：「在访达里显示「Clipper.Pro」」→ `scan_reveal`、「在访达里显示「Notes Lite」」→ `scan_reveal`、「在访达里显示「Snap Tool 2.1」」→ `scan_reveal`、「在访达里显示「Viewer」」→ `scan_reveal`
  - 「gone」已经删掉了却还在运行
  - 它会跟着开机启动，重启后还会再运行。 / 要停掉它：把上面「会跟着电脑一起启动的『gone』」改成「移到废纸篓」，清理后重启一下电脑。
  - 2 个已删除的应用仍有权限
  - 「tool」、「removed」 / 在系统设置中选中它们，点「−」移除。
  - 按钮：「打开「录屏」」→ `scan_open_settings`、「打开「完全磁盘访问」」→ `scan_open_settings`
  - （分隔线）
  - 自动清理
  - 按钮：「打开自动清理」→ `scan_autoclean`
  - 打开后，每天那一轮不用你点就清：会重建的缓存、装好了的应用的安装包、下载文件夹里的重复文件、测试工具留下的临时文件夹。移到废纸篓的都能放回，要你定的照样先问你。
  - 病毒库更新于 10月20日
- 基础页 `page/mac`：
  - 硬盘还剩
  - 182.0 GB
  - 一年多没打开过的大文件
  - 没有
  - 安全设置（1 项没查成）
  - 1 项没开启
  - 上次扫描：10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - （分隔线）
  - 硬盘
  - 用了 312.0 GB，一共 494.0 GB
  - （分隔线）
  - 占地方最多的文件夹
  - 开发工具的缓存
  - 337.6 MB
  - 临时文件
  - 262.2 MB
  - 下载
  - 229.8 MB
  - composer 的缓存
  - 54.5 MB
  - 文稿
  - 14.7 MB
  - 已经删掉的应用留下的数据（5 个应用）
  - 11.5 MB
  - Projects
  - 3.4 MB
  - 几个应用共用的数据
  - 3.1 MB
  - 这些加起来约 916 MB。其余是没列出来的小文件夹，以及系统和应用本身。
  - （分隔线）
  - 一年多没打开过的大文件
  - 1 MB 以上算大文件，按大小排
  - 没找到一年多没打开过的大文件。
  - （分隔线）
  - 权限
  - 完全磁盘访问
  - 已允许
  - 已经删掉的应用还拿着权限
  - 2 个
  - 要收回，去「概览」看。
  - （分隔线）
  - 安全设置
  - 硬盘加密（文件保险箱）
  - 没开启
  - 只打开来路清楚的应用
  - 没查成
  - 防火墙
  - 已开启
  - 系统完整性保护
  - 已开启
  - 锁屏要密码
  - 已开启
  - 自动检查系统更新
  - 已开启
  - 没开启的怎么打开，在「概览」的「要你看看的」里有写。
  - 没查成的，下次扫描或点上面的「现在查一下」时会再查。
- 基础页 `page/cleaned`：
  - **清理记录**
  - 还没清理过。

**窗口上**

- 能清的都在扫描页的「可以清掉」里：缓存合成一行，每个工具写一次；同一类超过 3 项的合成一行（「已经装好的应用留下的安装包，一共 41 项」），标题写合起来的大小，下面写名字，一个选择框管这几项，选择发回时的键是 `g-<第一项的键>`。
- 「要你看看」里几个 AI 插件、几个应用合成一行时，每个一个「在访达里显示「名字」」（多于 3 个时先收起）。
- 底下的按钮：核心认 `countLabel`、`countAlso`、`countWeights` 时写「移到废纸篓 {n} 项」，`count.weights` 给合成的每一行它的项数（`{"g-<键>": 41}`）；不认 `countWeights` 时照旧「按上面的选择清理」。
- 一页不超过 200 个组件。

**文件**（按请求的先后）

| 文件 | 请求 | 什么时候 |
|---|---|---|
| `server-discover.json` | server/discover | 2026-10-20T12:00:00Z：server/discover |
| `tools-list.json` | tools/list | 2026-10-20T12:00:00Z：列工具（agent 认 readOnlyHint） |
| `resources-list.json` | resources/list | 2026-10-20T12:00:00Z：列资源 |
| `read-outbox.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:00:00Z：读 outbox（每分钟一次） |
| `read-summary.json` | resources/read `summary` | 2026-10-20T12:00:00Z：读概览（侧栏的计数和一句话） |
| `read-permissions.json` | resources/read `permissions` | 2026-10-20T12:00:00Z：读权限的状态 |
| `read-page-overview.json` | resources/read `page/overview` | 2026-10-20T12:00:00Z：读基础页 page/overview |
| `read-page-mac.json` | resources/read `page/mac` | 2026-10-20T12:00:00Z：读基础页 page/mac |
| `read-page-cleaned.json` | resources/read `page/cleaned` | 2026-10-20T12:00:00Z：读基础页 page/cleaned |

## `feedback-152`：一位用户的反馈（luoke-scan#152）：清理没删完、看不懂的几行

基础假目录上再加 luoke-scan#152 里报的几样：Gradle、Xcode 的缓存里各有删不掉的（一个只读的文件夹、一个锁定的文件），pip 和 uv 编译过源码包，5 个 AI 插件，4 个对话模板里多了话的本机模型，已经删掉的 Discord 还拿着权限。查完一轮，用户在扫描页上点缓存那一行的「清理」。

**怎么录的**：blackbox/fx.py 造的假目录：blackbox/cases/base.py 的 `build`（照单元测试的 Fixture.build 摆），fakes.json 是 `fx.standard_fakes`（和单元测试的 Fixture.Fakes.standard 一样），另加一块 494 GB、还剩 182 GB 的硬盘；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）；luoke-scan scan --fixture $FIXTURE --clock 2026-10-17T12:00:00Z（3 天前查过一轮：pip 的缓存还是空的）；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）。

假目录改过：pip 的缓存长到 60 MB；Gradle 的缓存（54 MB，其中一个文件夹只读）、Xcode 的 DerivedData（53 MB，另有一个锁定的文件）；pip、uv 编译过源码包；5 个 AI 插件（3 个在 ~/.claude/skills，2 个是插件市场装的）；Hugging Face 缓存里 4 个模型的 tokenizer_config.json 里多了一段把密码和密钥发出去、不告诉用户的话；TCC 里已经删掉的 Discord 还拿着录屏和麦克风。

**扫描报的**

- 概览（`summary`）：count 26，「23 项等你处理，其中 2 项要尽快」
- 权限（`permissions`）：`admin` ask、`auto` off、`fda` granted
- outbox：3 件
  - `security/malware.clamav/000000000003`：`security`、`urgent` → 急事（urgent）
    - 标题：下载里的「eicar-test.com」可能是病毒
    - 摘要：下载里的「eicar-test.com」可能是病毒。病毒库认出了它。建议移到废纸篓，先不要打开。
    - 卡片（surface `security-000000000001`）：
      - **下载里的「eicar-test.com」可能是病毒**
      - 病毒库认出了它。建议移到废纸篓，先不要打开。
      - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - `security/malware.yara.luoke_fake_password_dialog/000000000006`：`security`、`urgent` → 急事（urgent）
    - 标题：下载里的「update.scpt」可能是病毒
    - 摘要：下载里的「update.scpt」可能是病毒。病毒库认出了它。建议移到废纸篓，先不要打开。
    - 卡片（surface `security-000000000004`）：
      - **下载里的「update.scpt」可能是病毒**
      - 病毒库认出了它。建议移到废纸篓，先不要打开。
      - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - `round/2026-10-20T12:00:00Z`：`findings`、`low` → 顺便看看（later）
    - 标题：能清出 176.2 MB，另外 21 项等你处理
    - 摘要：会重建的缓存 3 项，不用你选；另外 21 项在「螺壳扫描」里等你看。
    - 卡片（surface `round-000000000007`）：
      - **能清出 176.2 MB**
      - 会重建的缓存 3 项，不用你选；另外 21 项在「螺壳扫描」里等你看。
      - 按钮：「清理 3 项缓存」→ `scan_apply`、「打开自动清理」→ `scan_autoclean`
- 基础页 `page/overview`：
  - **扫描**
  - 上次查 10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - 这周清掉
  - 还没清过
  - 能清出
  - 176.2 MB
  - 等你处理
  - 23 项
  - （分隔线）
  - 要尽快处理 2
  - 下载里的「eicar-test.com」可能是病毒
  - 病毒库认出了它。建议移到废纸篓，先不要打开。
  - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - 下载里的「update.scpt」可能是病毒
  - 病毒库认出了它。建议移到废纸篓，先不要打开。
  - 按钮：「移到废纸篓」→ `scan_apply`、「不是病毒」→ `scan_ignore`
  - （分隔线）
  - 可以清掉 17
  - 会自动重建的缓存 3 项（176.2 MB）
  - pip、Xcode、Gradle
  - 按钮：「清理」→ `scan_apply`
  - 选项：wings 留下的临时文件夹（131.1 MB）（trash/keep/ignore，默认 keep）
  - 25 个 wings-*，在系统临时目录里
  - 选项：已经删掉的应用「removed」留下的数据（4.2 MB）（trash/keep/ignore，默认 keep）
  - 选项：已经删掉的应用「stillused」留下的数据（2.1 MB）（trash/keep/ignore，默认 keep）
  - 选项：很久没动过的项目「old-pushed」（147 KB）（trash/keep/ignore，默认 keep）
  - 选项：本机模型的对话模板里多了给模型的话，一共 4 项（trash/keep/ignore，默认 trash）
  - 「MiniCPM-V-4_6」、「Qwen3.5-0.8B-Base」、「Qwen3.5-2B-Base」、「Qwen3.5-4B-MLX-4bit」，这 4 项一起处理 / 每次和它们对话都会悄悄带上这些话，可能让它们瞒着你或把回答带偏。删掉这些模型，从可信的地方重新下载。 / 包含：外发对话内容、对你隐瞒。
  - 在访达里逐个看（4 个）
  - 按钮：「在访达里显示「MiniCPM-V-4_6」的模板」→ `scan_reveal`、「在访达里显示「Qwen3.5-0.8B-Base」的模板」→ `scan_reveal`、「在访达里显示「Qwen3.5-2B-Base」的模板」→ `scan_reveal`、「在访达里显示「Qwen3.5-4B-MLX-4bit」的模板」→ `scan_reveal`
  - 选项：「Claude Code」的插件「claude-automation-recommender」能操作你的电脑（trash/keep/ignore，默认 trash）
  - AI 用到它时，可能改动、删除或外传你的文件。不认识的建议移到废纸篓。
  - 按钮：「在访达里显示「claude-automation-recommender」」→ `scan_reveal`
  - 选项：「Claude Code」的插件「cloudflare」能操作你的电脑（trash/keep/ignore，默认 trash）
  - AI 用到它时，可能改动、删除或外传你的文件。不认识的建议移到废纸篓。
  - 按钮：「在访达里显示「cloudflare」」→ `scan_reveal`
  - 选项：「Claude Code」的插件「example-command」能操作你的电脑（trash/keep/ignore，默认 trash）
  - AI 用到它时，可能改动、删除或外传你的文件。不认识的建议移到废纸篓。
  - 按钮：「在访达里显示「example-command」」→ `scan_reveal`
  - 还有 3 项
  - 选项：会跟着电脑一起启动的「gone」（trash/keep/ignore，默认 keep）
  - 开机后在后台自动运行。不认识可以移除。
  - 选项：pip 装软件时会自动运行里面的程序（scripts-off/keep/ignore，默认 keep）
  - 遇到恶意软件，装的时候就会中招。建议关闭，个别软件可能会装不上。
  - 选项：uv 装软件时会自动运行里面的程序（scripts-off/keep/ignore，默认 keep）
  - 遇到恶意软件，装的时候就会中招。建议关闭，个别软件可能会装不上。
  - 按钮：「按上面的选择清理」→ `scan_apply`
  - （分隔线）
  - 要你看看 7
  - 2 个 AI 插件能操作你的电脑
  - 「command-development」、「hook-development」 / AI 用到它们时，可能改动、删除或外传你的文件。不认识的，在 Claude Code 里输入 /plugin 卸载。
  - 按钮：「在访达里显示「command-development」」→ `scan_reveal`、「在访达里显示「hook-development」」→ `scan_reveal`
  - 硬盘没加密：电脑丢了，别人能直接读出里面的东西
  - 打开时会给你一个恢复密钥，抄下来放好。
  - 按钮：「打开 FileVault 设置」→ `scan_open_settings`
  - 「gone」已经删掉了却还在运行
  - 它会跟着开机启动，重启后还会再运行。 / 要停掉它：把上面「会跟着电脑一起启动的『gone』」改成「移到废纸篓」，清理后重启一下电脑。
  - 3 个已删除的应用仍有权限
  - 「tool」、「Discord」、「removed」 / 在系统设置中选中它们，点「−」移除。
  - 按钮：「打开「录屏」」→ `scan_open_settings`、「打开「麦克风」」→ `scan_open_settings`、「打开「完全磁盘访问」」→ `scan_open_settings`
  - （分隔线）
  - 自动清理
  - 按钮：「打开自动清理」→ `scan_autoclean`
  - 打开后，每天那一轮不用你点就清：会重建的缓存、装好了的应用的安装包、下载文件夹里的重复文件、测试工具留下的临时文件夹。移到废纸篓的都能放回，要你定的照样先问你。
  - 病毒库更新于 10月20日
- 基础页 `page/mac`：
  - 硬盘还剩
  - 182.0 GB
  - 一年多没打开过的大文件
  - 没有
  - 安全设置（1 项没查成）
  - 1 项没开启
  - 上次扫描：10月20日 20:00
  - 按钮：「现在查一下」→ `scan_now`
  - （分隔线）
  - 硬盘
  - 用了 312.0 GB，一共 494.0 GB
  - （分隔线）
  - 占地方最多的文件夹
  - 临时文件
  - 262.2 MB
  - 开发工具的缓存
  - 177.2 MB
  - 已经删掉的应用留下的数据（5 个应用）
  - 11.5 MB
  - Projects
  - 3.4 MB
  - 几个应用共用的数据
  - 3.1 MB
  - Present 的缓存
  - 2.1 MB
  - 这些加起来约 459 MB。其余是没列出来的小文件夹，以及系统和应用本身。
  - （分隔线）
  - 一年多没打开过的大文件
  - 1 MB 以上算大文件，按大小排
  - 没找到一年多没打开过的大文件。
  - （分隔线）
  - 权限
  - 完全磁盘访问
  - 已允许
  - 已经删掉的应用还拿着权限
  - 3 个
  - 要收回，去「概览」看。
  - （分隔线）
  - 安全设置
  - 硬盘加密（文件保险箱）
  - 没开启
  - 只打开来路清楚的应用
  - 没查成
  - 防火墙
  - 已开启
  - 系统完整性保护
  - 已开启
  - 锁屏要密码
  - 已开启
  - 自动检查系统更新
  - 已开启
  - 没开启的怎么打开，在「概览」的「要你看看的」里有写。
  - 没查成的，下次扫描或点上面的「现在查一下」时会再查。
- 基础页 `page/cleaned`：
  - **清理记录**
  - 还没清理过。

**窗口上**

- 清理以后结果里写清还剩多少、为什么（锁定的文件删不掉），只读的文件夹改了权限照删。
- 「要你看看」里：插件说清 AI 用到它们时才运行、有什么风险；对话模板那行写多出来的话会做什么，「在访达里显示」选中模板文件；已经删掉的应用写出名字和权限，每项权限一个按钮。

**文件**（按请求的先后）

| 文件 | 请求 | 什么时候 |
|---|---|---|
| `server-discover.json` | server/discover | 2026-10-20T12:00:00Z：server/discover |
| `tools-list.json` | tools/list | 2026-10-20T12:00:00Z：列工具（agent 认 readOnlyHint） |
| `resources-list.json` | resources/list | 2026-10-20T12:00:00Z：列资源 |
| `read-outbox.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:00:00Z：读 outbox（每分钟一次） |
| `read-summary.json` | resources/read `summary` | 2026-10-20T12:00:00Z：读概览（侧栏的计数和一句话） |
| `read-permissions.json` | resources/read `permissions` | 2026-10-20T12:00:00Z：读权限的状态 |
| `read-page-overview.json` | resources/read `page/overview` | 2026-10-20T12:00:00Z：读基础页 page/overview |
| `read-page-mac.json` | resources/read `page/mac` | 2026-10-20T12:00:00Z：读基础页 page/mac |
| `read-page-cleaned.json` | resources/read `page/cleaned` | 2026-10-20T12:00:00Z：读基础页 page/cleaned |
| `call-scan_apply-caches.json` | tools/call `scan_apply`（带 user-action） | 2026-10-20T12:05:00Z：用户在扫描页上点缓存那一行的「清理」 |
| `read-page-overview-after-caches.json` | resources/read `page/overview` | 2026-10-20T12:05:00Z：点完再读扫描页 |
| `read-outbox-after-caches.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:05:00Z：点完再读 outbox |

`call-scan_apply-caches.json` 答：「删掉会重建的缓存 2 项（腾出 119.5 MB），部分处理了 1 项。Xcode 的缓存：未删完，1 个文件已锁定，剩 1 MB。」（done: false，更新原卡片）
