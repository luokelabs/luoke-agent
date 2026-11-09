# 给 agent 的场景样例

扫描（luoke-scan）对 agent 那一路（工具协议版本 1：MCP、outbox、A2UI 卡片、基础页、权限）在几种用户处境下**真实**的答复。
都是 `scripts/record_agent_fixtures.py` 在假用户目录上跑真的 `luoke-scan mcp --fixture` 录的，不是手写的：
agent 拿它们当样例数据和测试的输入，就是两边之间的接口说明。代码改了 agent 看到的东西，`--check` 就不过，
要重录、提交，并且在 PR 里说清 agent 那边要不要跟着改。

一个请求起一次 `luoke-scan mcp --fixture <假目录> --clock <时间>`：标准输入一条 JSON-RPC，标准输出是答复（和从外面测的
`blackbox/harness.py` 一样）；螺壳常驻起的是同一个程序（`luoke-scan mcp --this-mac`，stdio，一行一条消息）。假用户目录用
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
| `read-page-<页>*.json` | `resources/read` `page/overview`、`page/cleaned` |
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
    不记大小：「清理记录」页那一批写成「…、临时目录里有 25 个 wings-*…、临时目录里有 25 个 wings-*… 等 26 项（62.9 MB）」，
    `scan_restore` 的答复「放回了 26 项」下面同一个标题列好几行，和执行时说的「移到废纸篓 2 项（194 MB）」对不上。
  - 点完以后、下一轮之前，一轮那件的标题还按上一轮的报告数：`malware` 里 eicar 已经移走，点完再读 outbox，标题的「另有 … 条要你看」
    还算着它，卡片上的方案已经没有它。
  - 点完以后 outbox 里那件的卡片不变（`autoclean-done` 里点了「放回」，再读 outbox 还是点之前那张，「放回」还在）。
    agent 照卡片变没变决定重画，窗口上留着答复换上的那张（录的时候也照这样，下一下点的是换上的那张的按钮）；
    agent 的状态丢了（例如重装）才会又看到旧的。要不要点完就换掉 outbox 里的卡片，扫描这边以后定。

## 场景

## `first-run-no-fda`：第一次扫描，还没给完全磁盘访问

刚装好螺壳，还没在系统设置里给「螺壳」打开完全磁盘访问。扫描第一次查这台 Mac：下载、文稿、桌面和别的应用的容器都没看（看了 macOS 会弹框问），别处照查。

**怎么录的**：blackbox/fx.py 造的假目录：blackbox/cases/base.py 的 `build`（照单元测试的 Fixture.build 摆），fakes.json 是 `fx.standard_fakes`（和单元测试的 Fixture.Fakes.standard 一样）；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）。

假目录改过：pip 的缓存 60 MB（~/Library/Caches/pip/http/blob，半天前写的），之前没查过：没有它 3 天前的大小；~/Library/Application Support/com.apple.TCC/TCC.db 改成读不了（chmod 000）：没有完全磁盘访问时 macOS 也不让读它。

**扫描报的**

- 概览（`summary`）：count 7，「能清出 62.9 MB，另外有 6 件事值得看一眼」
- 权限（`permissions`）：`admin` ask、`auto` off、`fda` denied
- outbox：2 件
  - `round/2026-10-20T12:00:00Z`：`findings`、`low` → 顺便看看（later）
    - 标题：能清出 62.9 MB，另外有 6 件事值得看一眼
    - 摘要：放心删 1 条、要确认 5 条、仅供参考 15 条（其中需要留意的 1 条）。有 9 项没查成。
    - 卡片（surface `round-000000000001`）：
      - **能清出 62.9 MB，另外有 6 件事值得看一眼**
      - 会自动重建的缓存直接删掉，别的放心删的移到废纸篓，要你确认的先不动。
      - 选项：后台任务 io.example.gone 指向已经不存在的位置（trash/keep/ignore，默认 keep）
      - ~/Library/LaunchAgents/io.example.gone.plist
      - 选项：临时目录里有 25 个 wings-* 没被删掉，共 131.1 MB（trash/keep/ignore，默认 keep）
      - $TMPDIR 里的 25 项
      - 选项：pip 的缓存，删了会自动重建（62.9 MB）（remove/keep/ignore，默认 remove）
      - ~/Library/Caches/pip
      - 选项：io.example.removed 的数据还在，但这台 Mac 上没有这个应用（2.1 MB）（trash/keep/ignore，默认 keep）
      - ~/Library/Application Support 里的 2 项
      - 选项：old-pushed 半年多没动过，都已推送，删了能从远程找回（147 KB）（trash/keep/ignore，默认 keep）
      - ~/Projects/old-pushed
      - 按钮：「按这个处理」→ `scan_apply`、「以后自动清」→ `scan_autoclean`
      - （分隔线）
      - 这几样螺壳不替你动，你可以自己看看：
      - 进程 100（gone）的程序已经被删掉了，它还在跑
      - （分隔线）
      - 这几条值得留意，有空看一下：
      - FileVault 没开：电脑丢了，硬盘上的东西能直接被读出来
      - 怎么办：系统设置 → 隐私与安全性 → FileVault
      - 另有 14 条仅供参考，问我就列给你。
  - `needs-access/full-disk-access`：`needs-access`、`low` → 要你决定（decide）
    - 标题：下载、文稿、桌面还没查
    - 摘要：给「螺壳」打开「完全磁盘访问」就能查，删掉的应用留下的数据和权限也会一起查。
    - 卡片（surface `access-000000000003`）：
      - **下载、文稿、桌面还没查**
      - 给「螺壳」打开「完全磁盘访问」就能查，删掉的应用留下的数据和权限也会一起查。
      - 按钮：「打开设置」→ `scan_open_settings`
- 基础页 `page/overview`：
  - **扫描**
  - 能清出 62.9 MB，另外有 6 件事值得看一眼
  - 上一轮 10月20日 20:00：放心删 1、要确认 5、仅供参考 15
  - 病毒库 daily 27000（2026-10-20）
  - 有 9 项没查成，下一轮再查
  - 自动清：关
  - 按钮：「现在查一下」→ `scan_now`
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
| `read-page-cleaned.json` | resources/read `page/cleaned` | 2026-10-20T12:00:00Z：读基础页 page/cleaned |
| `call-scan_status.json` | tools/call `scan_status` | 2026-10-20T12:00:00Z：对话里问「扫描怎么样了」：模型调 scan_status（只读，答一张新卡片） |

`call-scan_status.json` 答：「上一轮：2026-10-20T12:00:00Z，用了 0 秒；发现：放心删 1、要确认 5、仅供参考 15；放心删的能腾出 62.9 MB；病毒库 daily 27000（2026-10-20）；没查成：space、space.system、space.duplicates、leftover.app-data、leftover.installer、stale.large-file、secrets、permission.stale-grant、malware；自动清：关」（新卡片）

## `decide-3`：要你决定 3 项的清理方案

查完一轮，没有急事。一轮的卡片上有一份三项的清理方案：pip 的缓存（放心删，默认删掉：会自己重建，删了马上腾出空间）、测试留下的 25 个临时文件夹和一个推送过的老项目（要确认，默认先不动）；下面另列要去系统设置里收回的权限、进不了方案的一条和一条高风险提醒。

**怎么录的**：blackbox/fx.py 造的假目录：blackbox/cases/base.py 的 `build`（照单元测试的 Fixture.build 摆），fakes.json 是 `fx.standard_fakes`（和单元测试的 Fixture.Fakes.standard 一样）；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）；luoke-scan scan --fixture $FIXTURE --clock 2026-10-17T12:00:00Z（3 天前查过一轮：pip 的缓存还是空的）。

假目录改过：pip 的缓存长到 60 MB；删掉了 ~/Downloads/eicar-test.com；删掉了 ~/Downloads/update.scpt；删掉了 ~/Library/LaunchAgents/io.example.gone.plist；删掉了 ~/Library/Application Support/io.example.removed；删掉了 ~/Library/Preferences/io.example.removed.plist；删掉了 ~/Library/Group Containers/ABCDE12345.io.example.removed；删掉了 ~/Library/Containers/ABCDE12345.io.example.removed。

**扫描报的**

- 概览（`summary`）：count 8，「能清出 62.9 MB，另外有 7 件事值得看一眼」
- 权限（`permissions`）：`admin` ask、`auto` off、`fda` granted
- outbox：1 件
  - `round/2026-10-20T12:00:00Z`：`findings`、`low` → 顺便看看（later）
    - 标题：能清出 62.9 MB，另外有 7 件事值得看一眼
    - 摘要：放心删 1 条、要确认 6 条、仅供参考 16 条（其中需要留意的 1 条）。
    - 卡片（surface `round-000000000001`）：
      - **能清出 62.9 MB，另外有 7 件事值得看一眼**
      - 会自动重建的缓存直接删掉，别的放心删的移到废纸篓，要你确认的先不动。
      - 选项：临时目录里有 25 个 wings-* 没被删掉，共 131.1 MB（trash/keep/ignore，默认 keep）
      - $TMPDIR 里的 25 项
      - 选项：pip 的缓存，删了会自动重建（62.9 MB）（remove/keep/ignore，默认 remove）
      - ~/Library/Caches/pip
      - 选项：io.example.stillused 的数据还在，但这台 Mac 上没有这个应用（2.1 MB）（trash/keep/ignore，默认 keep）
      - ~/Library/Caches/io.example.stillused
      - 选项：old-pushed 半年多没动过，都已推送，删了能从远程找回（147 KB）（trash/keep/ignore，默认 keep）
      - ~/Projects/old-pushed
      - 按钮：「按这个处理」→ `scan_apply`、「以后自动清」→ `scan_autoclean`
      - （分隔线）
      - 这几个应用已经删了，权限还留着，可以在系统设置里移除：
      - /opt/gone/tool 已经不在这台 Mac 上，还拿着「录屏」
      - 按钮：「打开「录屏」设置」→ `scan_open_settings`
      - io.example.removed 已经不在这台 Mac 上，还拿着「完全磁盘访问」
      - 按钮：「打开「完全磁盘访问」设置」→ `scan_open_settings`
      - （分隔线）
      - 这几样螺壳不替你动，你可以自己看看：
      - 进程 100（gone）的程序已经被删掉了，它还在跑
      - （分隔线）
      - 这几条值得留意，有空看一下：
      - FileVault 没开：电脑丢了，硬盘上的东西能直接被读出来
      - 怎么办：系统设置 → 隐私与安全性 → FileVault
      - 另有 15 条仅供参考，问我就列给你。
- 基础页 `page/overview`：
  - **扫描**
  - 能清出 62.9 MB，另外有 7 件事值得看一眼
  - 上一轮 10月20日 20:00：放心删 1、要确认 6、仅供参考 16
  - 病毒库 daily 27000（2026-10-20）
  - 自动清：关
  - 按钮：「现在查一下」→ `scan_now`
- 基础页 `page/cleaned`：
  - **清理记录**
  - 还没清理过。

**窗口上**

- 一轮的那件是 `findings`、`low`：照 agent 现在的分段规则在「顺便看看」，不在「要你决定」（见下面「要对齐的」）。
- 卡片上每项一个 `ChoicePicker`（移到废纸篓 / 先不动 / 以后别提；会重建的缓存第一个是「删掉（会自动重建）」，值 `remove`），按钮「按这个处理」把 `/choices` 换成当时的选项转给 `scan_apply`。
- 点完答复带 `done: true`：卡片换成结果（移了什么、[放回]），这一件从 outbox 撤下。

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
| `read-page-cleaned.json` | resources/read `page/cleaned` | 2026-10-20T12:00:00Z：读基础页 page/cleaned |
| `call-scan_findings.json` | tools/call `scan_findings` | 2026-10-20T12:00:00Z：对话里问「要我看的是哪些」：模型调 scan_findings（只读） |
| `call-scan_apply.json` | tools/call `scan_apply`（带 user-action） | 2026-10-20T12:05:00Z：用户在一轮的卡片上照默认的选项点「按这个处理」 |
| `read-outbox-after-apply.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:05:00Z：点完再读 outbox |
| `read-summary-after-apply.json` | resources/read `summary` | 2026-10-20T12:05:00Z：点完再读概览 |

`call-scan_findings.json` 答：「[要确认] 进程 100（gone）的程序已经被删掉了，它还在跑 / [要确认] /opt/gone/tool 已经不在这台 Mac 上，还拿着「录屏」 / [要确认] io.example.removed 已经不在这台 Mac 上，还拿着「完全磁盘访问」 / [要确认] 临时目录里有 25 个 wings-* 没被删掉，共 131.1 MB / [要确认] io.example.stillused 的数据还在，但这台 Mac 上没有这个应用 / [要确认] old-pushed 半年多没动过，都已推送，删了能从远程找回」（新卡片）

`call-scan_apply.json` 答：「删掉会重建的缓存 1 项（腾出 62.9 MB）。」（done: true，更新原卡片）

## `malware`：下载里有报毒的文件

下载文件夹里有一个病毒库认得的文件（eicar 测试文件）和一个伪造系统密码框的脚本。每个一件急事，一轮的卡片上也列着它们（默认先不动）。

**怎么录的**：blackbox/fx.py 造的假目录：blackbox/cases/base.py 的 `build`（照单元测试的 Fixture.build 摆），fakes.json 是 `fx.standard_fakes`（和单元测试的 Fixture.Fakes.standard 一样）；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）；luoke-scan scan --fixture $FIXTURE --clock 2026-10-17T12:00:00Z（3 天前查过一轮：pip 的缓存还是空的）。

假目录改过：pip 的缓存长到 60 MB。

**扫描报的**

- 概览（`summary`）：count 12，「有 2 件要尽快看看，另外 1 条需要留意」
- 权限（`permissions`）：`admin` ask、`auto` off、`fda` granted
- outbox：3 件
  - `security/malware.clamav/000000000003`：`security`、`urgent` → 急事（urgent）
    - 标题：病毒库认出 eicar-test.com 是 Eicar-Test-Signature
    - 摘要：~/Downloads/eicar-test.com：病毒库认出是 Eicar-Test-Signature（daily 27000，2026-10-20）。建议移到废纸篓。
    - 卡片（surface `security-000000000001`）：
      - **病毒库认出 eicar-test.com 是 Eicar-Test-Signature**
      - ~/Downloads/eicar-test.com
      - 依据：病毒库认出是 Eicar-Test-Signature（daily 27000，2026-10-20）
      - 按钮：「移到废纸篓」→ `scan_apply`、「在访达里显示」→ `scan_reveal`、「不是病毒，以后别提」→ `scan_ignore`
  - `security/malware.yara.luoke_fake_password_dialog/000000000006`：`security`、`urgent` → 急事（urgent）
    - 标题：update.scpt：伪造的系统对话框骗你输入密码（macOS 上窃取钥匙串的木马常用）
    - 摘要：~/Downloads/update.scpt：规则 luoke_fake_password_dialog。建议移到废纸篓。
    - 卡片（surface `security-000000000004`）：
      - **update.scpt：伪造的系统对话框骗你输入密码（macOS 上窃取钥匙串的木马常用）**
      - ~/Downloads/update.scpt
      - 依据：规则 luoke_fake_password_dialog
      - 按钮：「移到废纸篓」→ `scan_apply`、「在访达里显示」→ `scan_reveal`、「不是病毒，以后别提」→ `scan_ignore`
  - `round/2026-10-20T12:00:00Z`：`findings`、`low` → 顺便看看（later）
    - 标题：能清出 62.9 MB，另外有 11 件事值得看一眼
    - 摘要：放心删 1 条、要确认 10 条、仅供参考 16 条（其中需要留意的 1 条）。
    - 卡片（surface `round-000000000007`）：
      - **能清出 62.9 MB，另外有 11 件事值得看一眼**
      - 会自动重建的缓存直接删掉，别的放心删的移到废纸篓，要你确认的先不动。
      - 选项：病毒库认出 eicar-test.com 是 Eicar-Test-Signature（4 KB）（trash/keep/ignore，默认 keep）
      - ~/Downloads/eicar-test.com
      - 选项：update.scpt：伪造的系统对话框骗你输入密码（macOS 上窃取钥匙串的木马常用）（4 KB）（trash/keep/ignore，默认 keep）
      - ~/Downloads/update.scpt
      - 选项：后台任务 io.example.gone 指向已经不存在的位置（trash/keep/ignore，默认 keep）
      - ~/Library/LaunchAgents/io.example.gone.plist
      - 选项：临时目录里有 25 个 wings-* 没被删掉，共 131.1 MB（trash/keep/ignore，默认 keep）
      - $TMPDIR 里的 25 项
      - 选项：pip 的缓存，删了会自动重建（62.9 MB）（remove/keep/ignore，默认 remove）
      - ~/Library/Caches/pip
      - 选项：io.example.removed 的数据还在，但这台 Mac 上没有这个应用（4.2 MB）（trash/keep/ignore，默认 keep）
      - ~/Library/Application Support 里的 4 项
      - 选项：io.example.stillused 的数据还在，但这台 Mac 上没有这个应用（2.1 MB）（trash/keep/ignore，默认 keep）
      - ~/Library/Caches/io.example.stillused
      - 选项：old-pushed 半年多没动过，都已推送，删了能从远程找回（147 KB）（trash/keep/ignore，默认 keep）
      - ~/Projects/old-pushed
      - 按钮：「按这个处理」→ `scan_apply`、「以后自动清」→ `scan_autoclean`
      - （分隔线）
      - 这几个应用已经删了，权限还留着，可以在系统设置里移除：
      - /opt/gone/tool 已经不在这台 Mac 上，还拿着「录屏」
      - 按钮：「打开「录屏」设置」→ `scan_open_settings`
      - io.example.removed 已经不在这台 Mac 上，还拿着「完全磁盘访问」
      - 按钮：「打开「完全磁盘访问」设置」→ `scan_open_settings`
      - （分隔线）
      - 这几样螺壳不替你动，你可以自己看看：
      - 进程 100（gone）的程序已经被删掉了，它还在跑
      - （分隔线）
      - 这几条值得留意，有空看一下：
      - FileVault 没开：电脑丢了，硬盘上的东西能直接被读出来
      - 怎么办：系统设置 → 隐私与安全性 → FileVault
      - 另有 15 条仅供参考，问我就列给你。
- 基础页 `page/overview`：
  - **扫描**
  - 有 2 件要尽快看看，另外 1 条需要留意
  - 上一轮 10月20日 20:00：放心删 1、要确认 10、仅供参考 16
  - 病毒库 daily 27000（2026-10-20）
  - 自动清：关
  - 按钮：「现在查一下」→ `scan_now`
- 基础页 `page/cleaned`：
  - **清理记录**
  - 还没清理过。

**窗口上**

- 两件 `security`、`urgent`：急事横幅，菜单栏图标多一个小点，按「主动提醒」的设置发通知。
- 急事卡片上：「移到废纸篓」（`scan_apply`，方案只有这一项）、「在访达里显示」（`scan_reveal`，只在 Mac 上）、「不是病毒，以后别提」（`scan_ignore`）。
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
| `read-page-cleaned.json` | resources/read `page/cleaned` | 2026-10-20T12:00:00Z：读基础页 page/cleaned |
| `call-outbox_ack-shown.json` | tools/call `outbox_ack` | 2026-10-20T12:02:00Z：agent 把急事说给用户以后记一下（outbox_ack shown） |
| `call-scan_apply.json` | tools/call `scan_apply`（带 user-action） | 2026-10-20T12:02:00Z：用户在 eicar 那张急事卡片上点「移到废纸篓」 |
| `call-scan_ignore.json` | tools/call `scan_ignore`（带 user-action） | 2026-10-20T12:02:00Z：用户在 update.scpt 那张上点「不是病毒，以后别提」 |
| `read-outbox-after.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:02:00Z：点完再读 outbox |
| `read-summary-after.json` | resources/read `summary` | 2026-10-20T12:02:00Z：点完再读概览 |

`call-outbox_ack-shown.json` 答：「记下了。」

`call-scan_apply.json` 答：「移到废纸篓 1 项（4 KB）。」（done: true，更新原卡片）

`call-scan_ignore.json` 答：「好，以后不再提「update.scpt：伪造的系统对话框骗你输入密码（macOS 上窃取钥匙串的木马常用）」。」（done: true，更新原卡片）

## `cleaned-restore`：清理过，清理记录里能放回

用户在一轮的卡片上把临时文件夹也改成移到废纸篓，点了「按这个处理」：pip 的缓存删掉了（放不回，工具会重建），25 个临时文件夹进了废纸篓。一小时后打开扫描的「清理记录」页，那一批有「放回」；点了以后整批回到原处。

**怎么录的**：blackbox/fx.py 造的假目录：blackbox/cases/base.py 的 `build`（照单元测试的 Fixture.build 摆），fakes.json 是 `fx.standard_fakes`（和单元测试的 Fixture.Fakes.standard 一样）；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）；luoke-scan scan --fixture $FIXTURE --clock 2026-10-17T12:00:00Z（3 天前查过一轮：pip 的缓存还是空的）。

假目录改过：pip 的缓存长到 60 MB；删掉了 ~/Downloads/eicar-test.com；删掉了 ~/Downloads/update.scpt；删掉了 ~/Library/LaunchAgents/io.example.gone.plist；删掉了 ~/Library/Application Support/io.example.removed；删掉了 ~/Library/Preferences/io.example.removed.plist；删掉了 ~/Library/Group Containers/ABCDE12345.io.example.removed；删掉了 ~/Library/Containers/ABCDE12345.io.example.removed。

**扫描报的**

- 概览（`summary`）：count 8，「能清出 62.9 MB，另外有 7 件事值得看一眼」
- 权限（`permissions`）：`admin` ask、`auto` off、`fda` granted
- outbox：0 件
- 基础页 `page/overview`：
  - **扫描**
  - 能清出 62.9 MB，另外有 7 件事值得看一眼
  - 上一轮 10月20日 20:00：放心删 1、要确认 6、仅供参考 16
  - 病毒库 daily 27000（2026-10-20）
  - 自动清：关
  - 按钮：「现在查一下」→ `scan_now`
- 基础页 `page/cleaned`：
  - **清理记录**
  - （分隔线）
  - 你清的：pip 的缓存，删了会自动重建、临时目录里有 25 个 wings-* 没被删掉，共 131.1 MB、临时目录里有 25 个 wings-* 没被删掉，共 131.1 MB 等 26 项（62.9 MB）
  - 10月20日 20:05
  - 按钮：「放回」→ `scan_restore`

**窗口上**

- 「清理记录」页（`page/cleaned`）一批一段：「你清的：……（大小）」、时间、按钮「放回」（`scan_restore`，参数是批次 `p-…`）。
- 页上的按钮照卡片走 `POST /action`，`ai.luoke/user-action` 的 `surfaceId` 是页 id `cleaned`；答复里的卡片不画，窗口重新读这一页：那一批写「已放回」，「放回」按钮没了。

**文件**（按请求的先后）

| 文件 | 请求 | 什么时候 |
|---|---|---|
| `read-outbox-before.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:00:00Z：读 outbox（一轮的卡片上有三项的方案） |
| `call-scan_apply.json` | tools/call `scan_apply`（带 user-action） | 2026-10-20T12:05:00Z：用户把「临时目录里有 25 个 wings-*」也改成移到废纸篓，点「按这个处理」 |
| `server-discover.json` | server/discover | 2026-10-20T13:00:00Z：server/discover |
| `tools-list.json` | tools/list | 2026-10-20T13:00:00Z：列工具（agent 认 readOnlyHint） |
| `resources-list.json` | resources/list | 2026-10-20T13:00:00Z：列资源 |
| `read-outbox.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T13:00:00Z：读 outbox（每分钟一次） |
| `read-summary.json` | resources/read `summary` | 2026-10-20T13:00:00Z：读概览（侧栏的计数和一句话） |
| `read-permissions.json` | resources/read `permissions` | 2026-10-20T13:00:00Z：读权限的状态 |
| `read-page-overview.json` | resources/read `page/overview` | 2026-10-20T13:00:00Z：读基础页 page/overview |
| `read-page-cleaned.json` | resources/read `page/cleaned` | 2026-10-20T13:00:00Z：读基础页 page/cleaned |
| `call-scan_restore.json` | tools/call `scan_restore`（带 user-action） | 2026-10-20T13:05:00Z：用户在「清理记录」页上点那一批的「放回」 |
| `read-page-cleaned-after-restore.json` | resources/read `page/cleaned` | 2026-10-20T13:05:00Z：点完窗口重新读这一页 |
| `read-permissions-after-restore.json` | resources/read `permissions` | 2026-10-20T13:05:00Z：点完再读权限（点的方案放回不关自动清） |

`call-scan_apply.json` 答：「移到废纸篓 1 项（131.1 MB），删掉会重建的缓存 1 项（腾出 62.9 MB）。」（done: true，更新原卡片）

`call-scan_restore.json` 答：「放回了 25 项。」（done: true，更新原卡片）

## `autoclean-done`：不用点就清了 4 类

用户之前在设置里打开了自动清（默认关）。主控在空闲时跑了每天那一轮（`scan --autoclean`）：查完把四类不用点就清的清掉了：pip 的缓存直接删（会重建），装好了的应用的安装包、下载里的重复文件、Puppeteer 留下的临时文件夹移进废纸篓（能放回）。用户回来看到报告，先点了「放回」，又点了「以后别自动清」。

**怎么录的**：blackbox/fx.py 造的假目录：blackbox/cases/base.py 的 `build`（照单元测试的 Fixture.build 摆），fakes.json 是 `fx.standard_fakes`（和单元测试的 Fixture.Fakes.standard 一样）；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）；luoke-scan scan --fixture $FIXTURE --clock 2026-10-17T12:00:00Z（3 天前查过一轮：pip 的缓存还是空的）。

假目录改过：pip 的缓存长到 60 MB；删掉了 ~/Downloads/eicar-test.com；删掉了 ~/Downloads/update.scpt；删掉了 ~/Library/LaunchAgents/io.example.gone.plist；删掉了 ~/Library/Application Support/io.example.removed；删掉了 ~/Library/Preferences/io.example.removed.plist；删掉了 ~/Library/Group Containers/ABCDE12345.io.example.removed；删掉了 ~/Library/Containers/ABCDE12345.io.example.removed；加了装好了的应用的安装包、文稿里也有一份的下载、21 个 Puppeteer 临时文件夹（都是 20 天前来的）；用户之前在设置里打开了自动清（默认关）：2026-10-20T07:12:00Z 带 user-action（surfaceId `settings`）调了 `scan_autoclean` `{"on": true}`。

**扫描报的**

- 概览（`summary`）：count 6，「有 6 件事值得看一眼」
- 权限（`permissions`）：`admin` ask、`auto` on、`fda` granted
- outbox：1 件
  - `round/2026-10-20T12:00:00Z`：`auto-done`、`normal` → 已经替你做了（done）
    - 标题：自动移到废纸篓 23 项（118.6 MB），清了 62.9 MB 的工具缓存；有 6 件事值得看一眼
    - 摘要：清了 62.9 MB 的工具缓存（pip），用到时会重新下载。移到废纸篓：装好了的应用的安装包 1 项（6.3 MB）、下载文件夹里的重复文件 1 项（2.1 MB）、测试工具留下的临时文件夹 21 项（110.2 MB）。放心删 0 条、要确认 5 条、仅供参考 19 条（其中需要留意的 1 条）。
    - 卡片（surface `round-000000000001`）：
      - **自动移到废纸篓 23 项（118.6 MB），清了 62.9 MB 的工具缓存**
      - 清了 62.9 MB 的工具缓存（pip），用到时会重新下载。移到废纸篓：装好了的应用的安装包 1 项（6.3 MB）、下载文件夹里的重复文件 1 项（2.1 MB）、测试工具留下的临时文件夹 21 项（110.2 MB）。
      - 装好了的应用的安装包：Fixtureapp-2.0.dmg
      - 下载文件夹里的重复文件：report-2026.pdf
      - 测试工具留下的临时文件夹：puppeteer_dev_chrome_profile-P00000、puppeteer_dev_chrome_profile-P00001、puppeteer_dev_chrome_profile-P00002 等 21 项
      - 按钮：「放回」→ `scan_restore`、「以后别自动清」→ `scan_autoclean`
      - （分隔线）
      - **有 6 件事值得看一眼**
      - 会自动重建的缓存直接删掉，别的放心删的移到废纸篓，要你确认的先不动。
      - 选项：临时目录里有 25 个 wings-* 没被删掉，共 131.1 MB（trash/keep/ignore，默认 keep）
      - $TMPDIR 里的 25 项
      - 选项：old-pushed 半年多没动过，都已推送，删了能从远程找回（147 KB）（trash/keep/ignore，默认 keep）
      - ~/Projects/old-pushed
      - 按钮：「按这个处理」→ `scan_apply`
      - （分隔线）
      - 这几个应用已经删了，权限还留着，可以在系统设置里移除：
      - /opt/gone/tool 已经不在这台 Mac 上，还拿着「录屏」
      - 按钮：「打开「录屏」设置」→ `scan_open_settings`
      - io.example.removed 已经不在这台 Mac 上，还拿着「完全磁盘访问」
      - 按钮：「打开「完全磁盘访问」设置」→ `scan_open_settings`
      - （分隔线）
      - 这几样螺壳不替你动，你可以自己看看：
      - 进程 100（gone）的程序已经被删掉了，它还在跑
      - （分隔线）
      - 这几条值得留意，有空看一下：
      - FileVault 没开：电脑丢了，硬盘上的东西能直接被读出来
      - 怎么办：系统设置 → 隐私与安全性 → FileVault
      - 另有 18 条仅供参考，问我就列给你。
- 基础页 `page/overview`：
  - **扫描**
  - 有 6 件事值得看一眼
  - 上一轮 10月20日 20:00：放心删 0、要确认 5、仅供参考 19
  - 病毒库 daily 27000（2026-10-20）
  - 自动清：会重建的缓存、装好了的应用的安装包、下载文件夹里的重复文件、测试工具留下的临时文件夹
  - 按钮：「现在查一下」→ `scan_now`
- 基础页 `page/cleaned`：
  - **清理记录**
  - （分隔线）
  - 自动清：重复的 report-2026.pdf、安装包 Fixtureapp-2.0.dmg、临时文件夹 puppeteer_dev_chrome_profile-P00020 等 24 项（181.5 MB）
  - 10月20日 20:00
  - 按钮：「放回」→ `scan_restore`

**窗口上**

- 一轮的那件是 `auto-done`、`normal`：在「已经替你做了」；上半张说清了什么（[放回]、[以后别自动清]），下半张是还要用户定的方案。
- 「放回」整批放回以后，放回过的那三类以后先问（`permissions.auto` 还是 `on`：缓存照清）；「以后别自动清」以后 `auto` 是 `off`，概览页写「自动清：关」，权限页的开关跟着变。

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
| `read-page-cleaned.json` | resources/read `page/cleaned` | 2026-10-20T12:01:00Z：读基础页 page/cleaned |
| `call-scan_restore.json` | tools/call `scan_restore`（带 user-action） | 2026-10-20T12:10:00Z：用户在自动清的卡片上点「放回」（整批放回，放回过的那几类以后先问） |
| `read-permissions-after-restore.json` | resources/read `permissions` | 2026-10-20T12:10:00Z：点完再读权限 |
| `read-outbox-after-restore.json` | resources/read `luoke://luoke-scan/outbox` | 2026-10-20T12:10:00Z：点完再读 outbox |
| `call-scan_autoclean-off.json` | tools/call `scan_autoclean`（带 user-action） | 2026-10-20T12:11:00Z：用户再点「以后别自动清」 |
| `read-permissions-after-off.json` | resources/read `permissions` | 2026-10-20T12:11:00Z：点完再读权限 |
| `read-page-overview-after-off.json` | resources/read `page/overview` | 2026-10-20T12:11:00Z：再读概览页 |

`call-scan_restore.json` 答：「放回了 23 项。」（done: false，更新原卡片）

`call-scan_autoclean-off.json` 答：「好，以后都先问你再清。」（done: false，更新原卡片）

## `full-report`：用了一阵的开发机：一轮查出一长串

基础假目录不去掉东西（报毒的两个文件、坏了的 LaunchAgent、删了的应用留下的数据都在），再加上开发机上常见的：几样会重建的缓存、很久没用的模型、多年没打开过的视频、明文写在 MCP 设置里的密钥、从网上下载代码直接运行的 skill、临时签名的程序在看所有应用的按键。查完一轮：急事、一份很长的清理方案、一串螺壳不替你动的提醒都有。

**怎么录的**：blackbox/fx.py 造的假目录：blackbox/cases/base.py 的 `build`（照单元测试的 Fixture.build 摆），fakes.json 是 `fx.standard_fakes`（和单元测试的 Fixture.Fakes.standard 一样）；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）；luoke-scan scan --fixture $FIXTURE --clock 2026-10-17T12:00:00Z（3 天前查过一轮：pip 的缓存还是空的）；luoke-scan update --data $FIXTURE/data --tool-dir $FIXTURE/tools --force（假的 freshclam，daily 27000，库文件的时间 2026-10-20T01:00:00Z）。

假目录改过：pip 的缓存长到 60 MB；加了五样会重建的缓存（go-build、uv、npm、Xcode 的 DerivedData、Bun，各 52–58 MB）、25 天前下载的 Hugging Face 模型、8 年多没打开过的视频、Gemini 的 MCP 设置里明文写的密钥（别人也能读）、一个从网上下载代码直接运行的 skill、一个临时签名的程序在看所有应用的按键。

**扫描报的**

- 概览（`summary`）：count 18，「有 2 件要尽快看看，另外 4 条需要留意」
- 权限（`permissions`）：`admin` ask、`auto` off、`fda` granted
- outbox：3 件
  - `security/malware.clamav/000000000003`：`security`、`urgent` → 急事（urgent）
    - 标题：病毒库认出 eicar-test.com 是 Eicar-Test-Signature
    - 摘要：~/Downloads/eicar-test.com：病毒库认出是 Eicar-Test-Signature（daily 27000，2026-10-20）。建议移到废纸篓。
    - 卡片（surface `security-000000000001`）：
      - **病毒库认出 eicar-test.com 是 Eicar-Test-Signature**
      - ~/Downloads/eicar-test.com
      - 依据：病毒库认出是 Eicar-Test-Signature（daily 27000，2026-10-20）
      - 按钮：「移到废纸篓」→ `scan_apply`、「在访达里显示」→ `scan_reveal`、「不是病毒，以后别提」→ `scan_ignore`
  - `security/malware.yara.luoke_fake_password_dialog/000000000006`：`security`、`urgent` → 急事（urgent）
    - 标题：update.scpt：伪造的系统对话框骗你输入密码（macOS 上窃取钥匙串的木马常用）
    - 摘要：~/Downloads/update.scpt：规则 luoke_fake_password_dialog。建议移到废纸篓。
    - 卡片（surface `security-000000000004`）：
      - **update.scpt：伪造的系统对话框骗你输入密码（macOS 上窃取钥匙串的木马常用）**
      - ~/Downloads/update.scpt
      - 依据：规则 luoke_fake_password_dialog
      - 按钮：「移到废纸篓」→ `scan_apply`、「在访达里显示」→ `scan_reveal`、「不是病毒，以后别提」→ `scan_ignore`
  - `round/2026-10-20T12:00:00Z`：`findings`、`low` → 顺便看看（later）
    - 标题：能清出 349.2 MB，另外有 12 件事值得看一眼
    - 摘要：放心删 6 条、要确认 8 条、仅供参考 22 条（其中需要留意的 4 条）。
    - 卡片（surface `round-000000000007`）：
      - **能清出 349.2 MB，另外有 12 件事值得看一眼**
      - 会自动重建的缓存直接删掉，别的放心删的移到废纸篓，要你确认的先不动。
      - 选项：病毒库认出 eicar-test.com 是 Eicar-Test-Signature（4 KB）（trash/keep/ignore，默认 keep）
      - ~/Downloads/eicar-test.com
      - 选项：update.scpt：伪造的系统对话框骗你输入密码（macOS 上窃取钥匙串的木马常用）（4 KB）（trash/keep/ignore，默认 keep）
      - ~/Downloads/update.scpt
      - 选项：后台任务 io.example.gone 指向已经不存在的位置（trash/keep/ignore，默认 keep）
      - ~/Library/LaunchAgents/io.example.gone.plist
      - 选项：临时目录里有 25 个 wings-* 没被删掉，共 131.1 MB（trash/keep/ignore，默认 keep）
      - $TMPDIR 里的 25 项
      - 选项：pip 的缓存，删了会自动重建（62.9 MB）（remove/keep/ignore，默认 remove）
      - ~/Library/Caches/pip
      - 选项：Go 的缓存，删了会自动重建（60.8 MB）（remove/keep/ignore，默认 remove）
      - ~/Library/Caches/go-build
      - 选项：uv 的缓存，删了会自动重建（58.7 MB）（remove/keep/ignore，默认 remove）
      - ~/.cache/uv
      - 选项：npm 的缓存，删了会自动重建（56.6 MB）（remove/keep/ignore，默认 remove）
      - ~/.npm/_cacache
      - 选项：Xcode 的缓存，删了会自动重建（55.6 MB）（remove/keep/ignore，默认 remove）
      - ~/Library/Developer/Xcode/DerivedData
      - 选项：Bun 的缓存，删了会自动重建（54.5 MB）（remove/keep/ignore，默认 remove）
      - ~/.bun/install/cache
      - 选项：old-pushed 半年多没动过，都已推送，删了能从远程找回（147 KB）（trash/keep/ignore，默认 keep）
      - ~/Projects/old-pushed
      - 按钮：「按这个处理」→ `scan_apply`、「以后自动清」→ `scan_autoclean`
      - （分隔线）
      - 这几个应用已经删了，权限还留着，可以在系统设置里移除：
      - /opt/gone/tool 已经不在这台 Mac 上，还拿着「录屏」
      - 按钮：「打开「录屏」设置」→ `scan_open_settings`
      - io.example.removed 已经不在这台 Mac 上，还拿着「完全磁盘访问」
      - 按钮：「打开「完全磁盘访问」设置」→ `scan_open_settings`
      - （分隔线）
      - 这几样螺壳不替你动，你可以自己看看：
      - 进程 100（gone）的程序已经被删掉了，它还在跑
      - （分隔线）
      - 这几条值得留意，有空看一下：
      - 没有开发者担保的程序 Keys 在看你在所有应用里按的每一个键
      - 怎么办：认得就留着；不认得的先退出它，再在 系统设置 → 隐私与安全性 → 输入监控、辅助功能 里关掉它的权限，把程序移到废纸篓
      - 按钮：「打开「输入监控」设置」→ `scan_open_settings`、「在访达里显示」→ `scan_reveal`
      - Gemini CLI 的 MCP 设置里明文写着 1 个密钥，这台 Mac 上别的账户也能读到
      - 怎么办：把密钥放进环境变量或钥匙串，设置里写成引用（例如 ${env:名字}）；已经写过的密钥最好换新的；终端里运行 chmod 600 "$HOME/.gemini/settings.json"
      - 按钮：「在访达里显示」→ `scan_reveal`
      - Claude Code 的 skill「quick-setup」：从网上下载代码直接运行，另有 1 处要看
      - 怎么办：不认识就在访达里把这个 skill 的文件夹移到废纸篓；认得的话看看它为什么要这样做；弄清楚之前别让 AI 用它
      - 按钮：「在访达里显示」→ `scan_reveal`
      - FileVault 没开：电脑丢了，硬盘上的东西能直接被读出来
      - 怎么办：系统设置 → 隐私与安全性 → FileVault
      - 另有 18 条仅供参考，问我就列给你。
- 基础页 `page/overview`：
  - **扫描**
  - 有 2 件要尽快看看，另外 4 条需要留意
  - 上一轮 10月20日 20:00：放心删 6、要确认 8、仅供参考 22
  - 病毒库 daily 27000（2026-10-20）
  - 自动清：关
  - 按钮：「现在查一下」→ `scan_now`
- 基础页 `page/cleaned`：
  - **清理记录**
  - 还没清理过。

**窗口上**

- 急事卡片几张（报毒的文件、看按键的程序……），一轮的那件是一张很长的卡片：「能清出 X，另外有 N 件事值得看一眼」，每项一个选择（会重建的缓存是「删掉（会自动重建）」），后面是「这几样螺壳不替你动」「这几条值得留意」，各带「怎么办」和按钮。
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
| `read-page-cleaned.json` | resources/read `page/cleaned` | 2026-10-20T12:00:00Z：读基础页 page/cleaned |
