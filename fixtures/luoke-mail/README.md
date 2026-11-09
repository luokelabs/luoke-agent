# 给 agent 的场景样例

邮件助手（luoke-mail）对 agent 那一路（工具协议版本 1：MCP、outbox、A2UI 卡片、权限）在几种用户处境下**真实**的答复，
格式和 luoke-scan 的 `fixtures/agent/` 一样（luoke-agent 的 docs/工具协议.md「场景样例」）。都是
`scripts/record_agent_fixtures.py` 录的，不是手写的：真的邮件助手（`luoke_mail.server.App` 和它的 agent socket）、
测试用的假 IMAP 服务器、`luoke_mail/samples.py` 的虚构邮件；分拣走真的 `pipeline.sync`，模型的答复用
`bench/results` 里 Qwen3.5-9B（螺壳带的模型）对这几封邮件的真实答复。点按真的在假邮箱里移动邮件。

**本文件也是录的时候生成的**，不要手改；要改说明，改 `scripts/record_agent_fixtures.py` 里的场景。

## 重录、核对

```bash
python3 scripts/record_agent_fixtures.py            # 重录，写进 fixtures/agent/
python3 scripts/record_agent_fixtures.py --check    # 重录进内存和这里比，不一样就列出差别、退出码 1（测试里也跑）
```

改了 agent 看到的东西（outbox 的卡片、工具、权限），`--check` 就不过：重录、提交，并在 PR 里说清 agent 那边要不要跟着改。

## 每个场景里有什么

| 文件 | 请求 |
|---|---|
| `manifest.json` | 配件清单 `packaging/accessory.json`（`capabilities` 在里面） |
| `scenario.json` | 这个场景：处境、怎么录的、时钟、时区、每一步、窗口上应该是什么样 |
| `server-discover.json` | `server/discover` |
| `tools-list.json` | `tools/list` |
| `resources-list.json` | `resources/list` |
| `read-outbox*.json` | `resources/read` `luoke://luoke-mail/outbox`（agent 每分钟读） |
| `read-permissions*.json` | `resources/read` `permissions` |
| `call-<工具>*.json` | `tools/call`：卡片上的点按（带 `ai.luoke/user-action`） |

带 `-after-…` 的是点完以后再读的。每个文件是 `{"request": …, "reply": …}`，JSON 按键排序、缩进两格。
邮件助手没有基础页（`page/…`）和 `summary`：它的页面在自己的窗口里（清单的 `service.ui`）。

**和线上不一样的地方**：`resources/read` 的 `contents[0].text` 在线上是一段 JSON 文字，这里解开成了 JSON 值。
方案的编号（`new-mail-…`、`suspicious-…`）由邮件和选项算出，每次录都一样，没有换写法。时钟停在固定的时间
（见各场景的 `scenario.json`），时区是 Asia/Shanghai。

## morning：早上分拣好的一批：几封可疑、一批要你处理、其余打算整理

收件箱里是演示用的那一批虚构邮件，后台刚分拣完：每封可疑邮件一张急事卡片，要你处理的（回复、日程、待办）一张卡片列出最要紧的 8 封、每封有自己的选项，其余打算归档或移到垃圾箱的合成一行。

窗口上：

- 可疑邮件每封一件 `suspicious`、`urgent`：在「急事」；卡片上一行「移到垃圾邮件 / 先不动」（默认移到垃圾邮件）、模型给的理由，按钮「按这个处理」「在邮件助手里看」。
- 要你处理的是一件 `new-mail`、`normal`：在「要你决定」；标题「这 8 封要你处理，其余打算整理」，每封一行选项（回复的：写草稿 / 待跟进 / 归档 / 先不动；日程、待办：待跟进 / 归档 / 先不动），最后一行「照建议处理 / 先不动」；有日程的带「加入日程」（打开网页，最多 3 个）。
- 点完可疑邮件那张：答复的卡片换成结果和 [撤销]，这一件从 outbox 撤下。

outbox 里 9 件：

- `suspicious`、`urgent`：一封可疑邮件
- `suspicious`、`urgent`：一封可疑邮件
- `suspicious`、`urgent`：一封可疑邮件
- `suspicious`、`urgent`：一封可疑邮件
- `suspicious`、`urgent`：一封可疑邮件
- `suspicious`、`urgent`：一封可疑邮件
- `suspicious`、`urgent`：一封可疑邮件
- `suspicious`、`urgent`：一封可疑邮件
- `new-mail`、`normal`：20 封新邮件要处理

步骤：

1. 2026-10-12T02:30:00Z 后台分拣完了（收件箱的每一封都过了模型；见 produced.fixture）
2. 2026-10-12T02:30:00Z server/discover（`server-discover.json`）
3. 2026-10-12T02:30:00Z 列工具（agent 认 readOnlyHint）（`tools-list.json`）
4. 2026-10-12T02:30:00Z 列资源（`resources-list.json`）
5. 2026-10-12T02:30:00Z 读 outbox（每分钟一次）（`read-outbox.json`）
6. 2026-10-12T02:30:00Z 读权限的状态（`read-permissions.json`）
7. 2026-10-12T02:35:00Z 用户在第一张可疑邮件的卡片上照默认的「移到垃圾邮件」点「按这个处理」（`call-mail_apply_plan.json`）
8. 2026-10-12T02:35:00Z 点完再读 outbox（`read-outbox-after-apply.json`）

## tidy-only：只有可以整理的：通知、推送、订阅

没有要回的、没有可疑的，刚分拣完的都是可以归档或移到垃圾箱的。

窗口上：

- 一件 `new-mail`、`low`：标题「这几封打算整理」，只有「照建议处理 / 先不动」那一行。

outbox 里 1 件：

- `new-mail`、`low`：15 封新邮件可以整理

步骤：

1. 2026-10-12T02:30:00Z 后台分拣完了：都是可以整理的（通知、推送、订阅）
2. 2026-10-12T02:30:00Z server/discover（`server-discover.json`）
3. 2026-10-12T02:30:00Z 列工具（agent 认 readOnlyHint）（`tools-list.json`）
4. 2026-10-12T02:30:00Z 列资源（`resources-list.json`）
5. 2026-10-12T02:30:00Z 读 outbox（每分钟一次）（`read-outbox.json`）
6. 2026-10-12T02:30:00Z 读权限的状态（`read-permissions.json`）

## no-account：还没连邮箱

邮件助手装好了、开着，还没连邮箱（设置里没有邮箱）。

窗口上：

- outbox 是空的；权限里邮箱是 `ask`：「设置 · 权限」那一行要用户去邮件助手里连。

outbox 里 0 件：


步骤：

1. 2026-10-12T02:30:00Z 邮件助手开着，还没连邮箱
2. 2026-10-12T02:30:00Z server/discover（`server-discover.json`）
3. 2026-10-12T02:30:00Z 列工具（agent 认 readOnlyHint）（`tools-list.json`）
4. 2026-10-12T02:30:00Z 列资源（`resources-list.json`）
5. 2026-10-12T02:30:00Z 读 outbox（每分钟一次）（`read-outbox.json`）
6. 2026-10-12T02:30:00Z 读权限的状态（`read-permissions.json`）
