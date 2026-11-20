# 给 agent 的场景样例

输入法（`luoke-ime mcp`）对 luoke-agent 那一路（工具协议版本 1）在几种处境下的**真实**答复：主窗口的输入法设置页由 agent 照
`data/settings` 拼，页上的动作走 `ime_set`、`ime_do`。都是测试 `Tests/LuokeShellTests/SettingsDataTests.swift` 在临时目录上
起真的 `SettingsService` 录的，不是手写的。

## 重录、核对

```bash
LUOKE_RECORD_FIXTURES=1 swift test --filter 设置页的数据   # 重录，写进 fixtures/agent/
swift test --filter 设置页的数据                           # 重录一遍和这里比，不一样就不过
```

改了 agent 看到的东西，就要重录、提交，并告诉 luoke-agent。

## 场景

两个场景都先照核心接上来时的顺序问：`server/discover`、`tools/list`、`resources/list`、outbox（`luoke://luoke-ime/outbox`，输入法没有要报的事，答空列表）、`page/apps`（旧的 A2UI 页）、`data/settings`、`data/apps`。然后：

- `normal`：小鹤双拼。忘掉过两个词，另有三个列不出原文；最近七天里有一天没打字；小鹤开着开发模式，记录文件夹在；输入法在运行。有两个单独设置的应用：备忘录（默认英文、禁止记录）、终端（拼音在候选窗口）。依次恢复一个词、清除已学词语、清零使用统计、关开发模式、改字号、终端里打开联想、备忘录恢复跟随全局，再从 Safari 的菜单点进来（带 `app` 读）、给 Safari 改一项，中间和最后各重读一次。「各应用」页上的点按 `surfaceId` 是 `apps`。
- `empty`：没学到词，没有忘掉过的词，没有使用计数，没开开发模式，记录文件夹不在。输入法没在运行，清除时答 `not_running`。

每个场景的 `scenario.json` 写处境（`situation`）和步骤（`steps`：每步 `{"clock", "do", "file"}`，照先后），`manifest.json` 是配件清单。一个请求一个文件 `{"request", "reply"}`，JSON 按键排序。

**和线上不一样的地方**：

- `resources/read` 的 `contents[0].text` 在线上是一段 JSON **文字**，这里解开成了 JSON 值。
- 路径里的临时目录写成 `~/.luoke/ime`。
- 时钟停在 2026-11-19 12:00。使用计数的日期按录的那台 Mac 的时区算中午，东西十一个时区以内录出来都一样；`scenario.json` 里一律写 `+08:00`。
- 「语音整理」的默认值按 16 GB 内存的 Mac 录（`default: false`）。
- 清单里的版本号写成 `0.0.0`。

## `data/settings`

| 字段 | 是什么 |
|---|---|
| `state` | `ok`；`not_ready`（设置文件还是第 1 版，用一下输入法就升级，这时 `ime_set`、`dev_mode` 不改）；`unreadable`（设置文件读不懂，只有 `state` 和 `paths`） |
| `settings` | `ime_set` 认的每一项：`key`、`value`，选项给代号（`options`），范围给 `min`、`max`、`step`。`currentEngine` 的选项带引擎名（`name`）。`voiceTidy` 带 `default`（没设过时按这台 Mac 的内存定）。语音那几项只有装了语音引擎才有，`predict`、`memory`、`recordingPaused` 只有装了个人化组件才有 |
| `learned` | 当前打字引擎能清除学到的词时：`{"engine": {"id", "name"}}`；不能时是 `null`。没有个数：学到了多少只有引擎自己知道 |
| `forgotten` | 用 Shift+⌫ 忘掉的词：`recent` 每个有 `id`（原样传回 `restore`）、`input`（按键）、`text`；`older` 是列不出原文的个数 |
| `usage` | `personal`：有没有个人化组件（没有时联想那四个代号不会出现）。`days`：最近七天，从早到晚，`date` 是本机日期，`counts` 按代号，那天没有的代号不出现 |
| `dev` | `engines`：能选的打字引擎和开发模式开没开；`log_dir`：记录文件夹；`log_dir_exists`：它在不在 |
| `paths` | `engines`：引擎文件夹；`settings`：设置文件 |

## `data/apps`

有单独设置的应用（在输入法菜单的「此应用设置」里加的），按名字排：

| 字段 | 是什么 |
|---|---|
| `state` | 同 `data/settings` |
| `personal` | 有没有个人化组件：没有时每个应用只有 `english`、`inline` 两项 |
| `apps` | 每个应用 `id`（bundle id）、`name`、`settings` |
| `settings` 每一项 | `key` 是 `apps.<bundle id>.<项>`。`english`、`inline`、`predict` 的 `value` 是 `follow`、`on`、`off`，`follow` 给出跟随全局时实际是开（`true`）还是关；`predict` 另有 `terminal`：终端里联想默认关，`follow` 因此是 `false`。`noRecord` 的 `value` 是布尔值 |

改一项：`ime_set` `{"key": "apps.<id>.<项>", "value": "follow" | "on" | "off"}`（`noRecord` 给布尔值）。恢复跟随全局：`{"key": "apps.<id>.reset", "value": true}`，各项都回到默认以后，这个应用就不在列表里了。bundle id 写法不对（只认字母、数字、点、连字符）的答 `invalid`。

**从菜单「此应用设置」点进来的**：读 `data/apps?app=<bundle id>`。这个应用还没有单独设置时，`apps` 里多给它一项，各项是 `follow`（`noRecord` 是 `false`），带 `"new": true`；已经在列表里、写法不对的，答复和不带参数一样。只读不记，`ime_set` 改了它的第一项才进列表。

使用计数的代号（只记次数，不记内容和应用）：

| 代号 | 数的是什么 |
|---|---|
| `commit` | 打字引擎上屏的次数 |
| `pick_first` | 上屏时选的是首选的段数（一次上屏可能分几段选，原样上屏的字母不算） |
| `pick_other` | 上屏时选的不是首选的段数 |
| `backspace_after_commit` | 上屏后紧接着按了退格的次数（每次上屏最多算一次） |
| `predict_shown` | 联想提示亮出来的次数 |
| `predict_opened` | 按 Tab 打开联想的次数 |
| `predict_picked` | 选用联想的次数 |
| `predict_chars` | 选用的联想一共多少个字（字数，不是次数） |

使用计数是正在运行的输入法每分钟写一次盘，读到的可能晚一分钟。

## 动作

都只认带 `ai.luoke/user-action` 的请求，没带的答 `needs_user_action`。

| 工具 | 参数 | 成功时 `structuredContent.data` |
|---|---|---|
| `ime_set` | `key`、`value` | `{"key", "value"}`（还带着旧页面的 `card`，agent 换过去以后去掉） |
| `ime_do` `clear_learned` | `engine`：页上显示的那个引擎 | `{"op", "engine"}` |
| `ime_do` `restore` | `id` | `{"op", "id"}`；答复时引擎已经改完，重读时那个词不在了 |
| `ime_do` `reset_usage` | | `{"op"}` |
| `ime_do` `dev_mode` | `engine`、`on` | `{"op", "engine", "on"}` |

`clear_learned`、`restore`、`reset_usage` 要正在运行的输入法来做（经 `~/.luoke/ime/requests/`），最多等 3 秒。

失败时 `isError: true`。`ime_do` 的 `structuredContent` 是 `{"code", "data": {"op", "code"}}`，`ime_set` 的只有 `{"code"}`：

| `code` | 什么时候 |
|---|---|
| `needs_user_action` | 没带用户操作 |
| `invalid` | 参数不对、不认识的 `op`、开发模式的引擎不是能选的打字引擎、`restore` 的 `id` 解不开 |
| `not_running` | 输入法没在运行（3 秒内没人取走请求） |
| `engine_not_running` | 输入法在运行，打字引擎没在运行或不能清除 |
| `engine_changed` | `clear_learned` 带的引擎不是现在的打字引擎 |
| `not_found` | `restore` 的词已经不在忘掉的列表里 |
| `not_ready`、`settings_unreadable` | 同 `state` |
| `failed` | 设置文件存不进去 |
