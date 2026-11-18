# 给 agent 的场景样例

螺壳记忆（luoke-mem）对 agent 那一路（工具协议版本 1：outbox、A2UI 卡片、基础页）在几种用户处境下**真实**的答复。
都是 `scripts/record_agent_fixtures.py` 在临时目录里造一份假记忆、跑真的 `python3 -m luoke_mem mcp` 录的，不是手写的：
agent 拿它们当样例数据和测试的输入，就是两边之间的接口说明。代码改了 agent 看到的东西，`--check` 就不过，
要重录、提交，并且在 PR 里说清 agent 那边要不要跟着改。

一个请求起一次 `python3 -m luoke_mem --path <假记忆> mcp --clock <时间>`：标准输入一条 JSON-RPC，标准输出是答复。
螺壳起的是同一个命令（清单 `commands.mcp`：`-m luoke_mem --path {memory} mcp`，不带 `--clock`）。假记忆经 luoke_mem 自己的
接口写进去（`record`、`propose`、`conclude`、`state`、`ask`，时间都写死），不连模型。

**本文件也是录的时候生成的**，不要手改；要改说明，改 `scripts/record_agent_fixtures.py`。

## 重录、核对

```bash
python3 scripts/record_agent_fixtures.py            # 重录，写进 fixtures/agent/
python3 scripts/record_agent_fixtures.py --check    # 重录进临时目录和这里比，不一样就列出差别、退出码 1（tests/test_fixtures.py 也跑它）
python3 scripts/record_agent_fixtures.py --only asks --keep   # 只录一个场景，留下假记忆看看
```

## 每个场景里有什么

| 文件 | 请求 |
|---|---|
| `manifest.json` | 配件清单 `packaging/accessory.json`（0.35 起带 `capabilities`） |
| `scenario.json` | 这个场景：处境、假记忆怎么造的、时钟、时区、每一步、窗口上应该是什么样 |
| `server-discover.json` | `server/discover` |
| `tools-list.json` | `tools/list`（`annotations.readOnlyHint`；`mem_open` 带 `_meta.ai.luoke/where: mac`） |
| `resources-list.json` | `resources/list` |
| `read-outbox*.json` | `resources/read` `luoke://luoke-mem/outbox`（`outbox` 也认） |
| `read-summary*.json` | `resources/read` `summary` |
| `read-page-<页>*.json` | `resources/read` `page/overview`、`page/all`、`page/people`、`page/settings`、`page/item`、`page/asks`，和 0.37 以前的 `page/guesses`、`page/kept`、`page/sources`；`window`、`people` 场景里还有带参数的 `page/<页>?<键>=<值>` |
| `read-data-<名>*.json` | `resources/read` `data/recent`、`data/helped`、`data/asks`、`data/notes`、`data/people`、`data/sources`、`data/data`（0.40，原始数据，见下）；`people` 场景还有 `data/person?id=…`，`window` 场景还有 `data/note?id=…`、`data/notes?p=2`、`data/notes?filter=pending`（0.41）；`asks` 场景还有 `data/ask?id=…` 四件（`interest`、`fact`、`habit`、`own`），`people` 场景一件（`same-person`）（0.42） |
| `call-<工具>*.json` | `tools/call`：卡片、页上的点按（带 `ai.luoke/user-action`） |

带 `-after…` 的是点完以后再读的。每个文件是 `{"request": …, "reply": …}`：`request` 是 agent 发的那条 JSON-RPC
（`_meta` 里照 agent 带协议版本、`clientInfo`、`clientCapabilities`，点按的再带 `ai.luoke/user-action`），`reply` 是记忆的答复。
JSON 按键排序、缩进两格。

**和线上不一样的地方**（重放时要换回去）：

- `resources/read` 的 `contents[0].text` 在线上是一段 JSON **文字**（`mimeType: application/json`），这里解开成了 JSON 值；
  重放时 `json.dumps` 回去。
- 版本号是录的时候的真实版本（清单的 `version`、`server/discover` 的 `serverInfo.version`），窗口照着显示。每次升版都重录
  （`--check` 不一致就是忘了重录）。
- `manifest.json` 就是 `packaging/accessory.json`（0.35 起带 `capabilities`，`transport: "stdio"`）：螺壳本体照清单
  `commands.mcp` 起记忆。本体还不会起记忆的螺壳上，窗口会说记忆没在运行。
- 别的没换：记忆的编号是数据库里的顺序号，同一个场景里前后对得上（outbox 的 `ask/3` 就是点按时发的 `ask: 3`）；答复里没有路径。
- 时钟停在各步的 `clock`（本机时间，时区 Asia/Shanghai）。卡片、页上的「11月5日」按它写；`created`、`expires` 是不带时区的本机时间
  （工具协议 §3：不带时区的按本机时间）。

## 原始数据 `data/*`（0.40，顶层 ADR 0002）

主窗口的记忆页由 luoke-agent 的核心拼，读这几样（`resources/read`，JSON，不带 A2UI，不带页上的句子；字由 agent 写）。
清单 `capabilities.data`（0.41 起，和 `actions` 同一层）列出记忆给哪几样；没列的，核心照旧读 `page/*`。参数用默认值时不写（`data/notes` 就是第一页、`filter=all`）。
每个答复都有 `v`（形状的版本，现在是 1，只加字段不升）和 `ready`；`ready: false` 时只有 `problem`：`empty`（还没有记忆）、
`too_new`、`links`、`locked`、`broken`。时间都是本机时间 `YYYY-MM-DD HH:MM:SS`。

- **一条理解**（下面几样里的 `items`、`note`、`about`）：`id`、`text`、`kind`（`fact` 关于你、`interest` 关注的话题、
  `dislike` 不感兴趣、`preference` 处理习惯、`term` 常用说法、`taste` 精选的口味）、`status`（`active`、`proposed`、`observed`、
  `past` 以前的事、`rejected` 说过不对）、`pending`（待确认）、`confidence`（`guess`、`likely`、`sure`）、`origin`（`user` 用户自己说的、
  `inferred`）、`topic`、`entity`（关于谁，人的编号）、`formed_at`、`decided_at`、`fresh`（最新依据的时间）、`cites`（依据几条）、
  `sources`（依据来自哪些应用，`luoke-mem` 是用户自己说的）、`alike`（同一话题挨着的还有几条，只在 data/notes 里、有才写）。
- `data/recent`：最近 30 天没问就记下的，新的在前，最多 20 条，不含常用说法。`since`、`items`。
- `data/helped`：记忆不记谁读了什么，没有数可报：`recorded: false`、`items: []`。
- `data/asks`：概览上要确认的（最多 3 件，和页上一样挑）。每件 `id`、`kind`（`question` / `suggestion`）、`type`、`rank`、
  `created_at`、`expires_at`、`answer`（怎么答，同 outbox）。`type`：
  - `same_person`：`basis`（`name_inside` 一个称呼里带着另一个，`same_local` 邮箱 @ 前面一样）、`people` 两个，各 `by`
    （看着像的那个叫法或地址，`{"name": …}` 或 `{"address": …}`）、`entity`、`name`、`relations`、`addresses`；
  - `note`：关于一条理解：`basis`（`quiet` 机构的信停了、`reworded` 来信说法和确认过的不一样，带 `newer`；`guess` 别的猜测，0.42）、`note`；
  - `own`：记忆自己的问题，`text` 是问题本身；
  - `unsubscribe`、`habit`、`suggestion`（建议；没写种类的是 `suggestion`）：`about_note`、`action`、`evidence`、`text`。
  `same_person` 的 `by` 是用来比的形式（名字小写）。
  回答照旧 `mem_reply`：`same_person` 交 `choice: "answer"`、`text: "是"` 或 `"不是"`。「以后再说」哪一种问题都是 `choice: "later"`（不带 `text`）：先不问，过 7 天再问。
- `data/ask?id=`（0.42）：一件，哪个单子上的都行（今天的卡片 outbox 里的 `ask/<id>` 也是）。字段同 `data/asks`，再加：
  - `status`（`open`、`answered`、`dismissed`、`withdrawn`、`later`、`never`、`archived`）、`text`、`why`（记忆自己写的句子，
    用不用由 agent 定）；
  - `facts`：「为什么」凭的事实。`same_person`（`same_local`）：`local`（@ 前面那段）；`note` 的 `quiet`：`letters`（以前收到
    几封）、`last`（最后一封的月份）；`reworded`：`newer`；`habit`：`account`、`sender`、`name`、`category`、`action`；
    `unsubscribe`：`sender`、`times`（整批清掉几次）、`count`（共几封）、`days`；别的是 `{}`；
  - `affects`：答了改动哪个应用的哪件事，`[{tool, use}]`。按理解的种类：`fact` 是 `*`（螺壳的每个工具当作关于你的事实，
    比如邮件助手分拣、起草回复）·`fact`；`interest` 邮件助手 `digest_prefer`（挑订阅精选时优先）；`dislike` `digest_avoid`；
    `preference` `habit`；`term` 输入法 `candidates_first`；`taste` `digest_taste`。建议照它的 `action`（`unsubscribe`、`habit`）。
    `same_person` 是 `luoke-mem` · `merge_people`（并成一个人）；
  - `cites`：依据的记录，新的在前，最多 50 条（`cites_total` 是一共几条），字段同 `data/note`：`id`、`tool`、`speaker`、`kind`、
    `topic`、`text`、`happened_at`、`recorded_at`、`sensitive`。`same_person` 是两个人身上那些理解的依据；`unsubscribe` 是用户
    自己整批清掉的那几次；
  - `replies`：能怎么答，每个就是 `mem_reply` 除 `ask` 以外的参数，照原样交（`{"choice": "answer", "text": "是"}`、
    `{"choice": "later"}`……），`archive`（归档）每件都有；`write`：要带上用户写的字（`text`）的 choice，关于一条理解的问题是
    `["revise"]`（「改成」能填），没选项的问题是 `["answer"]`，别的是 `[]`。
  不在了答 `found: false`。
- `data/notes`：全部记忆。参数 `filter`（`all` 默认：生效的和攒够依据的猜测，不含常用说法和精选的口味；`pending`、`past`、
  `rejected`，或一个 `kind`）、`q`（几个词都要有）、`p`（第几页，从 1）、`n`（每页几条，默认 20，最多 100）。答 `filter`、`q`、
  `page`、`pages`、`total`、`waiting`（还在攒依据、不列的猜测几条）、`counts`（每个 filter 各几条，不受 `q` 影响）、`items`。
- `data/people`：人物（有理解或写信记录的人，写得多的在前）。参数 `q`（叫法或地址里有）、`p`、`n`。每人 `id`、`name`、`status`
  （`active` / `proposed` 猜测）、`notes`、`relations`（`relation`、`status`、`note`）、`top`（关系以外最有依据的一条：`id`、`text`、
  `kind`）、`contact`（写信：`first`、`last` 月份、`months`、`count`、`lapsed` 很久没联系、`together` 常谈的话题）。
- `data/person?id=`：一个人，同上，再加 `aliases`（每个叫法、地址）、`profile`（完整的写信档案）、`about`（关于他的全部理解）。
  不在了答 `found: false`。
- `data/note?id=`：一条理解（加 `why`、`superseded_by`、`valid_from`、`valid_to`）和全部依据 `cites`（新的在前，`p`、`n` 翻页，
  默认 50 条：`id`、`tool`、`speaker`、`kind`、`topic`、`text`、`happened_at`、`recorded_at`、`sensitive`），`merged` 是并进来的说法。
  `family`（0.43）：同一类里用户还没表态的那几条，`{head, code, notes: [编号…]}`（`code` 0.44，见下），不到两条是 `null`；`mem_note` 的 `reject_family` 要的 `family` 就是这里的 `notes`。
- `data/sources`：每个写过记忆、或关了停学的应用：`tool`、`on`（学不学）、`stopped_at`、`records`、`notes`、`topics`
  （写过哪几类记录、各几条，多的在前；话题代号：`sent-mail` 发出的邮件、`ime-commit` 打的字……）、`last`（最后一条记录）。
- `data/forget?tool=`（0.43）：忘掉一个应用写的之前先试算（试一遍再撤回，什么都不删）：`known`、`records`（会删几条记录）、`notes`（会删几条理解）、
  `kept`（它的理解里留下几条：用户表过态的、别的来源也有依据的）。没写过记忆的应用答 `found: false`。
- `data/data`：`tidied`（上次整理 `at` 和做了什么 `counts`）、`next: "idle"`（下次在用户不用电脑时，记忆不排时刻）、`typing`
  （上次归纳打的字 `at`、`outcome`）、`kept`（记住的事几条）、`terms`（输入法词条几条）、`archived_asks`（归档的问题几件）。

## 代号和数字（0.44）

窗口上的字由 agent 写。记忆照旧给自己的那句（`text`、`why`、`content[0].text`），旁边另给代号和数字，agent 照代号写自己的句子。

- **一条理解的理由**：每条理解（`data/*` 的 `items`、`note`）带 `why_data`：`why` 是记忆或邮件助手照模板写的句子时，给 `code` 和数，
  另有 `waiting`（记忆在等用户确认）；用户自己写的、或认不出的是 `null`。`code`：
  - `typing_term_pending`（打字里见到，还没记下）：`days`、`times`、`need_days`、`need_times`；`typing_term`：`days`、`times`；
  - `typing_interest_pending`：`days`、`need_days`；`typing_interest`：`days`；
  - `sent_mail_person`（发出的邮件里写到的人）：`relation`（有才写）；`frequent_contact`（常写信给这个人）：`months`；
  - `habit_overridden`（邮件助手的建议被改）：`times`、`action`；`habit_manual`（自己动手处理）：`times`、`action`（`action` 是动作的中文名）；
  - `sent_mail`（发出的邮件里提到）：`count`（有才写）；`received_mail`（收到的邮件）、`mail_opened`（多次打开这类邮件）、
    `topics_mail`、`taste_mail`、`digest_dislike`：没有数。
- **同一类**：`data/note` 的 `family` 加 `code`：`name`、`signature`、`title`（职位）、`employer`、`work`、`city`、`language`、
  `manager`、`colleague`、`report`、`client`、`partner`、`family`、`friend`、`account`、`service`、`membership`、`school`、
  `housing`、`travel`、`institution`、`birthday`、`hometown`，别的是 `other`（`head` 照旧给原来的类名）。
- **概览**（`summary`）：`state`（`recent` 有最近了解到的、`quiet` 最近没有新的、`empty` 还没有记下什么、`not_ready` 记忆打不开，
  带 `problem`，代号同 `data/*`）、`recent`（`id`、`kind`、`text`、`formed_at`）、`kept`（记住的几条）、`pending`（待确认的几条）、
  `count`（概览上要确认的几件）。
- **点按的结果**：做成了的，`structuredContent` 带 `result` 和数：
  - `mem_reply`：`result` 是交上来的 `choice`（`yes`、`no`、`past`、`revise`、`later`、`answer`、`useful`、`useless`、`never`、
    `archive`），`stale: false`；`revise`、`answer` 带用户写的 `answer`，`later` 带 `days`（过几天再问），「是不是同一个人」带
    `same`（`true` 并成了一个）。问题已经变了（在别处答过、理解已经定了或忘了）：`result: "changed"`、`stale: true`，什么也没改。
  - `mem_note`：`result` 是 `op`，`note`；`revise` 带 `new_text`；`reject_family` 带 `n`（否定了几条）、`of`（这一类几条）；
    以前的事上的 `confirm` 带 `was: "past"`（现在还是）。
  - `mem_person`：`result` 是 `op`，`person`、`name`；`rename` 带 `was`（原来的名字），`merge` 带 `other`、`other_name`，
    `split` 带 `alias`。
  - `mem_archive`：`result`（`archive`、`back`）、`n`（做成几件）、`of`（交上来几件）。
  - `mem_forget_tool`：`result: "forget_tool"`、`tool`、`records`、`notes`。`mem_learn`：`result: "learn"`、`tool`、`on`。
    `mem_forget_all`：`result: "forget_all"`。`mem_open`：`result: "opened"`。
- **没做成的**：`isError: true`，`structuredContent.code` 照旧（`invalid`、`stale`、`not_ready`、`failed`、`needs_user_action`），
  另带 `reason`：`unknown`（不认识的问题、回答或操作）、`empty_text`（要写的没写）、`same_text`（和原来的一样）、`secret`（带密码、
  验证码、证件号码，记忆不存）、`unconfirmed`（没勾或没确认）、`no_choice`（没选人）、`wrong_word`（清空没输对）、`changed`（已经变了）、
  `family_changed`（这一类的条数变了，一条都没动）、`no_share`（这个应用没写过记忆）、`empty`、`too_new`、`links`、`locked`、
  `broken`（记忆打不开，同 `data/*` 的 `problem`）、`open_failed`。

## 重放时要知道的

- agent 要问的：`tools/list`、`luoke://luoke-mem/outbox`、`summary`；打开应用页时读 `page/<页>`。
- 会改动东西的（`mem_reply`、`mem_note`、`mem_forget_tool`、`mem_learn`、`mem_forget_all`、`mem_person`、`mem_archive`，清单 `actions` 里的七个）只认带
  `ai.luoke/user-action` 的调用，没带的答 `isError: true`、`structuredContent.code: "needs_user_action"`。
  `mem_open`、`outbox_ack` 是只读的。
- 卡片上的点按（`mem_reply`）答 `content[0].text` 一句话、`structuredContent.card` 是**更新原卡片**的消息（没有 `createSurface`，
  组件编号带 `end-` 前缀）、`done: true`，记忆已经把这件从 outbox 撤下。改成的内容带密码、验证码、证件号码时答 `isError`、
  `code: "invalid"`，不带 `done`：卡片留着让用户改。问题在别处答过了，答「这条已经变了……」，也是 `done`。
  每张卡片最后一个不带边框的「归档」（`choice: "archive"`）：不算回答，这件从 outbox 撤下，记忆不会自己再问，在「归档的问题」页上能放回。
- 页上的点按（`mem_note`、`mem_forget_tool`、`mem_learn`、`mem_forget_all`、`mem_person`、`mem_archive`）只答一句话，窗口重新读那一页。
  `mem_learn` 是设置里每个应用的开关（`variant: "switch"`，`on` 是现在学不学）：上下文 `{"tool", "on"}` 里的 `on` 是点了以后的样子，
  不用确认（关了不删东西，能再打开）。
  `mem_archive` 的 `asks` 是页上列出来的那几件（「全部归档」只收它画页时列出的，不收之后新来的）；放回的那件以**新的编号**
  回到 outbox（卡片上归档的那件 agent 已经当成答完了，同一个编号不会再给用户看）。
  `mem_note`、`mem_person` 的「忘掉」和 `mem_forget_tool` 要 `sure: true`：请求的 features 里有 `confirm`（工具协议 §4 confirm）的，
  按钮直接带 `sure: true` 和 `confirm`（`{title, text, label}`），页上没有勾选框，由窗口点了先弹确认（UI 规范 v2 §18.3）；
  没有的照旧是勾选框「我知道删了找不回来」（`sure: {"path": "/checks/sure"}`）。
  `mem_forget_all` 要 `confirm: "清空"`：有 `confirm` 的窗口上按钮直接带它，`confirm` 里写会清掉多少；没有的是输入框里写「清空」
  （`confirm: {"path": "/fields/clear"}`），不然答 `invalid`、不删。
- **页带参数**（工具协议 §4 `pageArgs`，0.35）：`window`、`people` 场景的请求在 `clientCapabilities.experimental["ai.luoke/a2ui"].features`
  里带 `openPage`、`pageArgs`、`confirm`、`rowOpen`、`fieldSubmit`，别的场景什么都不带（旧的核心）。有 `rowOpen` 时人物的一行写
  `open`（「详细」那个按钮），有 `fieldSubmit` 时搜索框写 `submit`（「搜索」「找」那个按钮）；按钮照写，旧窗口还画它们。带了的，页上的「看依据」「详细」「看每天记了什么」、按类的一排、
  搜索和「上一页」「下一页」都是 `agent.open_page`（`{"page", "args"}`），录的时候照窗口那样换过去、读
  `page/<页>?<键>=<值>`（键按字母顺序，值按 RFC 3986 百分号编码）；点完会改动东西的按钮，窗口带着同样的参数重读那一页。
  卡片上的「在螺壳记忆里看」是 `agent.open_page` 到 `item`（`{"id": "<编号>"}`），页上、卡片上都没有 `mem_open`。
  不带的照旧：每页最多 15 条，「打开整份记忆」。
  - `page/all`（全部记忆）：`kind`（`fact`、`interest`……）或 `view`（`pending` 待确认、`past` 以前的事、`rejected` 说过不对的），
    `q` 搜索，`p` 第几页（从 1 起）。
  - `page/item`：`id` 一条理解的编号，`p` 依据的第几页。`page/people`：`id` 一个人（`who` 找要并的人、`wp` 第几组），没有 `id` 时 `p`。
    `page/settings`：`tool` 一个应用（`forget=1` 先说会删多少），`day`（`YYYY-MM-DD`）哪一天，`p`。`page/asks`（已归档的）：`p`。
  - 0.37 以前的标签照旧答：`page/kept` 就是 `page/all`，`page/guesses` 是它的待确认，`page/sources` 是 `page/settings`。
  - 参数不对（不认识的类、没有的编号、超出的页）照没带或最近的那一页画，不报错。
  - 新的写入：`mem_note` 的 `revise`（`text`）、`split`、`reject_family`，以前的事上的 `confirm` 是「现在还是」；
    `mem_person` 的 `rename`（`name`）、`merge`（`other`，页上选择框的值）、`split`（`alias`，叫法或邮箱地址）。
- 没录的：`mem_open`（在假记忆上也会真的起页面、开浏览器；答「在螺壳记忆里打开了。」，没有卡片）；`outbox_ack`（只答「好。」，
  记忆不记：答了的由 `mem_reply` 关掉，用户放下的那件在记忆里照旧开着，agent 自己记着放下了）。

## 要对齐的

- 页的结构照 UI 规范 v2 §18.3（0.37）：标签是概览、全部记忆、人物，清单里只有这三个不带 `hidden`；设置（`settings`）带
  `hidden` 和 `"icon": "settings"`，窗口画成右上角的齿轮。页上不写页名。行上的动作是图标按钮（`child` 是 `Icon` 加 `Text` 的一行：
  对 `check`、不对 `x`、看依据 `eye`、忘掉 `trash-2`、详细 `chevron-right`），窗口只画图标、字做悬停提示。概览上是「最近了解到的」（每条「不对」）和「想跟你确认」（最多三件，按钮同卡片）；
  页上不列总条数，条数只在设置的「数据」里。`summary` 的 `text` 是最近了解到的一件，`count` 是概览上要确认的几件。

- 「各应用的授权」页没有做：顶层 ADR 0001 以后本机里不再按应用藏敏感内容，记忆没有授权可改了（记忆自己的页面
  也只留着旧接口）。
- 「一条理解」（`item`）只从按钮进（「看依据」「在螺壳记忆里看」），清单里写 `"hidden": true`（工具协议 §1a），认它的窗口
  不画成标签。不认的旧窗口照样画成标签，没带编号时只有一句说明；`settings`、`asks` 和 0.37 以前的三页也一样。
- 核心不认 `pageArgs` 时照旧：「在螺壳记忆里看」打开记忆自己的网页、定位到那一条；每页最多 15 条，多的去整份记忆看。

## 场景

## `empty`：刚装好，记忆是空的

刚装好螺壳，还没有应用往记忆里写过东西：记忆文件还不存在。

**怎么造的**：没有记忆文件：还没有应用往记忆里写过东西（mcp 不替它建一个）。

**记忆报的**

- 概览（`summary`）：count 0，「还没有记下什么。」
- outbox：0 件
- `page/overview`：还没有记下什么。各应用用起来以后，记忆会从你打的字、发的邮件里慢慢记下关于你的事。
- `page/all`：还没有记下什么。各应用用起来以后，记忆会从你打的字、发的邮件里慢慢记下关于你的事。
- `page/people`：还没有记下什么。各应用用起来以后，记忆会从你打的字、发的邮件里慢慢记下关于你的事。
- `page/settings`：还没有记下什么。各应用用起来以后，记忆会从你打的字、发的邮件里慢慢记下关于你的事。

**窗口上**：侧栏「螺壳记忆」不带计数；每页都只有标题和一句「还没有……」；「今天」里没有记忆的卡片。

## `guesses`：有几条等确认的猜测

用了一个多星期，记忆从打字里猜了两个关注的话题，还没问；从发出的邮件里没问就记下了一条关于用户的事。用户打开应用页，在「全部记忆」上一条点「对」、一条点「不对」。

**怎么造的**：螺壳输入法记了四段打字（10月28日、11月3日、11月5日），邮件助手记了两封发出的邮件（10月28日、11月5日）；两条猜测：关注的话题「本地大模型」「爬山」，各凭两段打字（记忆还没把握，等用户定）；记下的：从两封发出的邮件归纳的「在读研究生，导师是王老师」（没问就记下了），用户自己写的常用说法「螺壳」。

**记忆报的**

- 概览（`summary`）：count 0，「最近了解到：在读研究生，导师是王老师」
- outbox：0 件
- `page/overview`：最近了解到的；在读研究生，导师是王老师；关于你 · 11月5日；按钮「不对」→ `mem_note`；按钮「打开整份记忆」→ `mem_open`
- `page/all`：CheckBox「我知道删了找不回来」；在读研究生，导师是王老师；关于你 · 11月5日；按钮「不对」→ `mem_note`；按钮「忘掉」→ `mem_note`；爬山；待确认 · 关注的话题 · 11月3日；按钮「对」→ `mem_note`；按钮「不对」→ `mem_note`；按钮「忘掉」→ `mem_note`；本地大模型；待确认 · 关注的话题 · 10月28日……
- `page/people`：还没有。各应用用起来以后，记忆会从你发出的邮件里认出你常写信给的人。；按钮「在整份记忆里看」→ `mem_open`
- `page/settings`：各应用；CheckBox「我知道删了找不回来」；螺壳输入法；从打的字里学。；按钮「忘掉螺壳输入法写的」→ `mem_forget_tool`；按钮「从螺壳输入法学」→ `mem_learn`；邮件助手；从发出的邮件里学。；按钮「忘掉邮件助手写的」→ `mem_forget_tool`；按钮「从邮件助手学」→ `mem_learn`；整理；还没有整理过。下次在你不用电脑时。……

**点了以后**

- `call-mem_note-confirm.json`：「记下了：对。」
- `call-mem_note-reject.json`：「记下了：不对，以后不再提。」

**窗口上**：概览最上面「最近了解到的」是没问就记下的那条（「不对」）；「全部记忆」里两条带「待确认」，各有「对」「不对」；点完以后「本地大模型」不再待确认，「爬山」没了。页上没有总条数。

## `asks`：记忆想问的事和建议

记忆在空闲时想好了要问的（每天合起来最多三件，记忆定）：三条猜测各一个问题、一条处理习惯的建议、一个自己想知道的带选项的问题。agent 把它们放进「今天」，用户一张张答。

**怎么造的**：螺壳输入法记了三段打字，邮件助手记了一次亲手归档某商城的促销邮件；三条猜测各有一个问题：「本地大模型」「在读博士」「爬山」；处理习惯「某商城的促销邮件归档」有一条建议；另有一个记忆自己的、带选项的问题（论文方向）。都在 11月5日 20:45 提出，11月20日过期。

**记忆报的**

- 概览（`summary`）：count 2，「最近没有新了解到的。」
- outbox：5 件
  - `ask/3`：`question`、`normal`，「记忆想问：「爬山」，对吗？」
  - `ask/2`：`question`、`normal`，「记忆想问：「在读博士」，对吗？」
  - `ask/1`：`question`、`normal`，「记忆想问：「本地大模型」，对吗？」
  - `ask/4`：`suggestion`、`normal`，「记忆建议：以后某商城的促销邮件都归档？」
  - `ask/5`：`question`、`normal`，「记忆想问：你的论文主要是哪个方向？」
- `page/overview`：最近了解到的；最近没有新了解到的。；想跟你确认；以后某商城的促销邮件都归档？；这个月你亲手归档了 6 封某商城的促销。；按钮「好」→ `mem_reply`；按钮「不用」→ `mem_reply`；按钮「别再提」→ `mem_reply`；你的论文主要是哪个方向？；邮件里常提到论文，知道方向以后挑精选更准。；ChoicePicker「选一个」；按钮「交回」→ `mem_reply`……
- `page/all`：CheckBox「我知道删了找不回来」；某商城的促销邮件归档；待确认 · 处理习惯 · 11月5日；按钮「对」→ `mem_note`；按钮「不对」→ `mem_note`；按钮「忘掉」→ `mem_note`；爬山；待确认 · 关注的话题 · 11月5日；按钮「对」→ `mem_note`；按钮「不对」→ `mem_note`；按钮「忘掉」→ `mem_note`；在读博士……
- `page/people`：还没有。各应用用起来以后，记忆会从你发出的邮件里认出你常写信给的人。；按钮「在整份记忆里看」→ `mem_open`
- `page/settings`：各应用；CheckBox「我知道删了找不回来」；螺壳输入法；从打的字里学。；按钮「忘掉螺壳输入法写的」→ `mem_forget_tool`；按钮「从螺壳输入法学」→ `mem_learn`；邮件助手；从亲手处理的邮件里学。；按钮「忘掉邮件助手写的」→ `mem_forget_tool`；按钮「从邮件助手学」→ `mem_learn`；整理；还没有整理过。下次在你不用电脑时。……

**点了以后**

- `call-mem_reply-yes.json`：「记下了：对。」（`done`）
- `call-mem_reply-revise-refused.json`：「记忆不保存密码、验证码和证件号码，改一下再点。」（`isError`，`invalid`）
- `call-mem_reply-revise.json`：「改好了。」（`done`）
- `call-mem_reply-later.json`：「好，过几天再问。」（`done`）
- `call-mem_reply-useful.json`：「好。」（`done`）
- `call-mem_reply-answer.json`：「记下了。」（`done`）

**窗口上**：「今天」里五张记忆的卡片：三张「记忆想问你」（输入框、对 / 不对 / 以前是，现在不是 / 按我改的 / 以后再说 / 在螺壳记忆里看）、一张「记忆有个建议」（好 / 不用 / 别再提 / 在螺壳记忆里看）、一张带选项的问题（选一个、交回 / 以后再说）。概览「想跟你确认」只列最值得问的三件。带验证码的改法被拒时卡片留着、上面一句话；其余答完换成一句话的结果。

## `archive`：把记忆想问的归档

记忆想问的事和建议在「今天」里攒了好几件，用户现在不想答：一张卡片上点「归档」，再到「归档的问题」页（设置里能去，旧窗口是标签）点「全部归档」。过了几天，又把其中一件放回去。

**怎么造的**：螺壳输入法记了两段打字，邮件助手记了一次亲手归档某商城的促销邮件；两条猜测各有一个问题（「本地大模型」「爬山」），处理习惯「某商城的促销邮件归档」有一条建议；都在 11月5日 20:45 提出，11月19日 20:45 过期。

**记忆报的**

- 概览（`summary`）：count 1，「最近没有新了解到的。」
- outbox：3 件
  - `ask/2`：`question`、`normal`，「记忆想问：「爬山」，对吗？」
  - `ask/1`：`question`、`normal`，「记忆想问：「本地大模型」，对吗？」
  - `ask/3`：`suggestion`、`normal`，「记忆建议：以后某商城的促销邮件都归档？」
- `page/overview`：最近了解到的；最近没有新了解到的。；想跟你确认；以后某商城的促销邮件都归档？；这个月你亲手归档了 6 封某商城的促销。；按钮「好」→ `mem_reply`；按钮「不用」→ `mem_reply`；按钮「别再提」→ `mem_reply`；按钮「打开整份记忆」→ `mem_open`
- `page/all`：CheckBox「我知道删了找不回来」；某商城的促销邮件归档；待确认 · 处理习惯 · 11月5日；按钮「对」→ `mem_note`；按钮「不对」→ `mem_note`；按钮「忘掉」→ `mem_note`；爬山；待确认 · 关注的话题 · 11月3日；按钮「对」→ `mem_note`；按钮「不对」→ `mem_note`；按钮「忘掉」→ `mem_note`；本地大模型……
- `page/people`：还没有。各应用用起来以后，记忆会从你发出的邮件里认出你常写信给的人。；按钮「在整份记忆里看」→ `mem_open`
- `page/settings`：各应用；CheckBox「我知道删了找不回来」；螺壳输入法；从打的字里学。；按钮「忘掉螺壳输入法写的」→ `mem_forget_tool`；按钮「从螺壳输入法学」→ `mem_learn`；邮件助手；从亲手处理的邮件里学。；按钮「忘掉邮件助手写的」→ `mem_forget_tool`；按钮「从邮件助手学」→ `mem_learn`；整理；还没有整理过。下次在你不用电脑时。……

**点了以后**

- `call-mem_reply-archive.json`：「归档了：不算回答，也不会自己再问。想答了，在记忆的「想问的」里放回。」（`done`）
- `call-mem_archive-all.json`：「归档了 2 件。不算回答，记忆也不会自己再问。」
- `call-mem_archive-back.json`：「放回去了，会回到「今天」里。」

**窗口上**：每张记忆的卡片最后都有一个不带边框的「归档」；点了换成一句话的结果。「归档的问题」页上面是还在问的（每件一个「归档」，两件以上有「全部归档（N 件）」），下面是「已归档 N 件」（每件一个「放回」）。全部归档以后「今天」里没有记忆的卡片了，侧栏计数是 0。放回的那件以新的编号回到「今天」。

## `sources`：几个应用写过记忆

邮件助手、输入法、扫描都往记忆里写过东西。用户在「设置」里忘掉扫描写的，又想清空整份记忆但输错了字。

**怎么造的**：邮件助手记了三封发出的邮件，螺壳输入法两段打字，螺壳扫描一次清理；用户自己写了一条「在读研究生」。

**记忆报的**

- 概览（`summary`）：count 0，「最近没有新了解到的。」
- outbox：0 件
- `page/overview`：最近了解到的；最近没有新了解到的。；按钮「打开整份记忆」→ `mem_open`
- `page/all`：CheckBox「我知道删了找不回来」；在读研究生；关于你 · 11月1日；按钮「不对」→ `mem_note`；按钮「忘掉」→ `mem_note`；按钮「打开整份记忆」→ `mem_open`
- `page/people`：还没有。各应用用起来以后，记忆会从你发出的邮件里认出你常写信给的人。；按钮「在整份记忆里看」→ `mem_open`
- `page/settings`：各应用；CheckBox「我知道删了找不回来」；螺壳输入法；从打的字里学。；按钮「忘掉螺壳输入法写的」→ `mem_forget_tool`；按钮「从螺壳输入法学」→ `mem_learn`；邮件助手；从发出的邮件里学。；按钮「忘掉邮件助手写的」→ `mem_forget_tool`；按钮「从邮件助手学」→ `mem_learn`；螺壳扫描；从扫描后清掉的里学。……

**点了以后**

- `call-mem_forget_tool-unsure.json`：「先勾上「我知道删了找不回来」。」（`isError`，`invalid`）
- `call-mem_forget_tool.json`：「忘掉了螺壳扫描写的：记录 1 条，理解 0 条。」
- `call-mem_forget_all-wrong-word.json`：「要清空整份记忆，请输入「清空」。」（`isError`，`invalid`）

**窗口上**：「设置」：「各应用」三个应用各一行（名字、「从……里学。」、「忘掉…写的」），旧窗口上面一个「我知道删了找不回来」的勾选框；「整理」上次整理和上次归纳打的字；「数据」记住的事、输入法词条各几条，底下清空整份记忆的输入框和按钮。忘掉扫描以后它那一行没了。

## `people`：记忆认出的人

用户发出的邮件里写到几个人：同一个地址写过两种叫法，记忆把它们并成一个人；另一个人只出现在一封信里，还有一封信里的「Mira Chen」记忆拿不准是不是他，问一句；还有一个人只在每月的写信记录里。用户打开「人物」，点进其中一个，忘掉；再在「是同一个人吗」的卡片上点「是」。

**怎么造的**：邮件助手从用户发出的邮件里记下三条关于别人的事：「同事：王磊（wanglei@corp.example）」「合作方：Wang Lei（同一个地址）」两条各凭两封信（10月28日、11月5日），「上级：Mira」只凭一封；记忆反刍时把同一个地址的两条并成一个人「王磊」（比较确定，他的名字成了常用说法，给语音当热词），Mira 只有一封信，是猜测；还有一封信说到「客户：Mira Chen」，记忆拿不准和 Mira 是不是同一个人，问一句；邮件助手还记了用户每月写信给谁（mail-contact）：王磊 9、10 月共 15 封，林晓 9、10 月共 5 封；林晓只出现在写信记录里，写过两个月，也算一个人；写给王磊的信的标题里两次提到用户的常用说法「主控」。

**记忆报的**

- 概览（`summary`）：count 1，「最近了解到：合作方：Wang Lei（wanglei@corp.example）」
- outbox：1 件
  - `ask/1`：`question`、`normal`，「记忆想问：「Mira」和「Mira Chen」是同一个人吗？」
- `page/overview`：最近了解到的；合作方：Wang Lei（wanglei@corp.example）；关于你 · 11月5日；按钮「不对」→ `mem_note`；按钮「看依据」→ `agent.open_page`；同事：王磊（wanglei@corp.example）；关于你 · 11月5日；按钮「不对」→ `mem_note`；按钮「看依据」→ `agent.open_page`；想跟你确认；「Mira」和「Mira Chen」是同一个人吗？；两个称呼，一个里带着另一个。……
- `page/all`：按钮「全部」→ `agent.open_page`；按钮「关于你」→ `agent.open_page`；按钮「常用说法」→ `agent.open_page`；TextField「搜索」；按钮「搜索」→ `agent.open_page`；合作方：Wang Lei（wanglei@corp.example）；关于你 · 11月5日；按钮「不对」→ `mem_note`；按钮「看依据」→ `agent.open_page`；按钮「忘掉」→ `mem_note`；同事：王磊（wanglei@corp.example）；关于你 · 11月5日……
- `page/people`：王磊；同事、合作方；按钮「详细」→ `agent.open_page`；Mira；上级；按钮「详细」→ `agent.open_page`；Mira Chen；客户；按钮「详细」→ `agent.open_page`；林晓；你写信给的人，最近一次在 2026年10月；按钮「详细」→ `agent.open_page`
- `page/settings`：各应用；邮件助手；从发出的邮件、写信给谁里学。；按钮「看记了什么」→ `agent.open_page`；按钮「忘掉邮件助手写的…」→ `agent.open_page`；按钮「从邮件助手学」→ `mem_learn`；整理；还没有整理过。下次在你不用电脑时。；还没有归纳过打的字，会在你不用电脑时进行。；数据；记住的事 2 条；输入法词条 5 条……

**点了以后**

- `call-mem_person-forget.json`：「从记忆里忘掉了林晓。」
- `call-mem_reply-same-person.json`：「记下了：是同一个人，已经并成一个。」（`done`）

**窗口上**：「人物」页三个人，每人一行名字和一句话（关系加最有依据的一条；什么都不知道时写怎么写信给他），点一行（「详细」）进这个人；列表上没有别的按钮。这个人的页上改名、并成一个、拆开、「不是一个人」「忘掉」（`sure: true` 加 `confirm`，窗口先弹确认）。忘掉林晓以后那一行没了。outbox 里一张「「Mira」和「Mira Chen」是同一个人吗？」（是 / 不是 / 以后再说，依据写各自的关系），概览「想跟你确认」里也有；点「是」以后两个 Mira 并成一行。

## `window`：记忆的事都在窗口里做

螺壳的核心认页带参数（`pageArgs`）：记忆网页上能做的，都在主窗口记忆的页上做。用户从「今天」的卡片跳到那一条，在「全部记忆」里按类看、翻页、搜索、看待确认的，看一条的全部依据、改写、拆出并进来的说法、说「这一类都不要」，把以前的事说成现在还是，看订阅精选的口味，给人改名、拆开、并成一个，在设置里看邮件助手每天记了什么，先看会删多少再忘掉输入法写的，关掉邮件助手的开关（不再从它学）再打开。

**怎么造的**：螺壳输入法记了五段打字、邮件助手记了五封发出的邮件（10月27日到11月5日），还有关于王磊的四封、每月写信给谁的记录；猜测：关注的话题「本地大模型」「电商促销与物流广告」，关于你的「某银行的信用卡」「某书店的会员」（同属「机构」这一类）；记下的：用户自己写的 16 个关注的话题；没问就记下的「在读研究生，导师是王老师」「学校：某大学计算机系」（打字里猜的「学校：某大学」并进了它）、用户确认过的「住在北京」；「住在杭州」用户说过以前是、现在不是；订阅精选的口味「大模型推理优化」；人：「王磊」（两种叫法并成的一个人）、「林晓」；记忆想问「本地大模型」对不对。

**记忆报的**

- 概览（`summary`）：count 0，「最近了解到：学校：某大学计算机系」
- outbox：1 件
  - `ask/1`：`question`、`normal`，「记忆想问：「本地大模型」，对吗？」
- `page/overview`：最近了解到的；学校：某大学计算机系；关于你 · 11月5日；按钮「不对」→ `mem_note`；按钮「看依据」→ `agent.open_page`；在读研究生，导师是王老师；关于你 · 11月4日；按钮「不对」→ `mem_note`；按钮「看依据」→ `agent.open_page`
- `page/all`：按钮「全部」→ `agent.open_page`；按钮「待确认」→ `agent.open_page`；按钮「关于你」→ `agent.open_page`；按钮「关注的话题」→ `agent.open_page`；按钮「常用说法」→ `agent.open_page`；按钮「精选的口味」→ `agent.open_page`；按钮「以前的事」→ `agent.open_page`；TextField「搜索」；按钮「搜索」→ `agent.open_page`；学校：某大学计算机系；关于你 · 11月5日；按钮「不对」→ `mem_note`……
- `page/people`：王磊；同事、合作方；按钮「详细」→ `agent.open_page`；林晓；你写信给的人，最近一次在 2026年10月；按钮「详细」→ `agent.open_page`
- `page/settings`：各应用；螺壳输入法；从打的字里学。；按钮「看记了什么」→ `agent.open_page`；按钮「忘掉螺壳输入法写的…」→ `agent.open_page`；按钮「从螺壳输入法学」→ `mem_learn`；邮件助手；从发出的邮件、写信给谁里学。；按钮「看记了什么」→ `agent.open_page`；按钮「忘掉邮件助手写的…」→ `agent.open_page`；按钮「从邮件助手学」→ `mem_learn`；整理……

**点了以后**

- `call-mem_note-revise-refused.json`：「记忆不保存密码、验证码和证件号码，改一下再点。」（`isError`，`invalid`）
- `call-mem_note-revise.json`：「改好了：旧的说法留着，标为已被取代。」
- `call-mem_note-split.json`：「拆出来了，成了一条单独的猜测。」
- `call-mem_note-reject_family.json`：「否定了 2 条，以后这一类少提。」
- `call-mem_note-confirm-past.json`：「记下了：现在还是。」
- `call-mem_person-rename.json`：「改好了：以后就叫「磊哥」。」
- `call-mem_person-merge-unchosen.json`：「先选一个人。」（`isError`，`invalid`）
- `call-mem_person-merge.json`：「并成一个人了：「林晓」并进了「磊哥」。」
- `call-mem_person-split-unsure.json`：「先勾上「确定不是同一个人」。」（`isError`，`invalid`）
- `call-mem_person-split.json`：「拆开了：「linxiao@corp.example」成了另一个人。」
- `call-mem_forget_tool-ime.json`：「忘掉了螺壳输入法写的：记录 6 条，理解 3 条。」
- `call-mem_learn-off.json`：「记忆以后不再从邮件助手学。已经记下的留着；要删，点「忘掉邮件助手写的」。」
- `call-mem_learn-on.json`：「记忆又从邮件助手学了。」

**窗口上**：页上的按钮多了「看依据」「详细」「看记了什么」、按类的一排（不带条数）、搜索框和「上一页」「下一页」（都是 `agent.open_page`，带 `args`），没有「打开整份记忆」，卡片上的「在螺壳记忆里看」跳到「一条理解」。同一话题的事实排在一起，写「可能和上下 N 条是同一件」；以前的事写「大约 N 年」；只凭一条依据的猜测不在列表上（问到的除外）；「设置」上「忘掉…写的…」先到一页说会删多少。「忘掉」「清空整份记忆」的按钮带 `confirm`（窗口先弹确认），「忘掉」带 `sure: true`，页上没有勾选框；行上是一项一行（`justify: spaceBetween`：左边字，右边图标）。「设置」每个应用一行的最右边是一个开关（`variant: "switch"`），关着的那一行写「不再从它学。已经记下的留着。」。每次点完，窗口带着同样的参数重新读那一页。
