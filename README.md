# luoke-agent

简体中文 | [English](README.en.md)

螺壳主窗口和提醒背后的组件：把螺壳记忆和各个应用要跟你说的事收拢起来，挑时候说，要你决定的画成卡片，你点了才去做。它不是单独的应用，随螺壳一起装好。

**English summary.** luoke-agent is the part of 螺壳 (Luoke) behind its main window and reminders. It gathers what Luoke Memory and the apps in Luoke want to tell you, picks the moment (urgent things right away, the rest in a daily brief) and shows each one as a card; anything that changes something runs only after you click. It runs only on your Mac and ships inside 螺壳, not as a separate app.

## 它是什么

[螺壳](https://github.com/luokelabs/luoke)是在你的 Mac 上跑的本机 AI。luoke-agent 在螺壳里管这几件事：

- **「今天」**：急事、要你决定的、已经替你做了的（能撤销、能放回），一件一张卡片；也可以「一件件处理」，一次只看一件。
- **提醒**：急事（比如可疑的钓鱼邮件）当场说；别的攒成一段简报，默认每天早上一份。什么时候说、免打扰、每类事怎么说，都能在「设置 · 提醒」里改。
- **和应用之间的协议**：螺壳邮件助手、螺壳扫描这些应用，按[工具协议](docs/工具协议.md)把要说的事、能做的事交给它；你在卡片上点的，再交回应用去做，或者交回螺壳记忆。

主窗口（`window/`）编进螺壳.app，核心（`luoke_agent/`）是螺壳带着的一个 Python 进程。螺壳各部分怎么分工，见[系统文档](https://luokelabs.github.io/luoke-atlas/)。

## 现状

封闭测试中，从螺壳的 beta 2 起随螺壳一起装。版本号在 `luoke_agent/__init__.py`。系统要求和螺壳一样，见 [luokelabs/luoke](https://github.com/luokelabs/luoke)。

## 怎么用

到 [luoke.ai](https://luoke.ai) 下载螺壳。luoke-agent 随螺壳装好，不用在「应用」里单独打开：螺壳的主窗口就是它，菜单栏图标里的急事、系统通知里的简报也是它发的。

## 从源码构建和测试

核心只用 Python 标准库，Python 3.9 起能跑：

```bash
python3 -B -m unittest discover -s tests -t .
```

渲染卡片的 Swift 包和主窗口（Swift 6，macOS 14 起）：

```bash
swift test --package-path a2ui
swift test --package-path window
```

不连核心、只用示例数据看主窗口，或者把全部界面截成图（浅色、深色各一份）：

```bash
swift run --package-path window luoke-window-demo
swift run --package-path window luoke-window-shots <目录>
```

单独跑核心（开发用）。数据目录、记忆文件都要写明，找不到就报错，不会退回默认位置：

```bash
python3 -m luoke_agent serve --home <数据目录> --memory <记忆文件> --tool <应用>=<socket> --dev
python3 -m luoke_agent feed --home <数据目录>          # 看现在的卡片
```

`luoke_agent/fake_tool.py` 是一个假的应用，开发、测试时代替真的应用。测试只用临时目录里的记忆和假应用，不碰你的数据。

## 数据和隐私

- **只在你的 Mac 上运行，不连外网。** 核心只和本机的螺壳、各个应用经 Unix socket 说话；用到模型时，推理由螺壳在本机做。
- **会改动东西的，只在你点了以后才做。** 打开网页的按钮也一样，要去的网站写在按钮旁边。
- **数据在 `~/.luoke/agent/`**，只有你的账户能读。`state.db` 里是每件事的状态、卡片、你的设置和你对每类事的反应。读的是螺壳记忆，你在卡片上的回答交回螺壳记忆。
- **日志只记元数据**（编号、类别、时间、结果码），不记邮件、卡片的内容。

## 文档

- [DESIGN.md](DESIGN.md)：怎么跑、读记忆、和应用通信、挑时机，以及底线
- [docs/工具协议.md](docs/工具协议.md)：应用接进螺壳要实现的协议（MCP）
- [docs/界面接口.md](docs/界面接口.md)：螺壳.app 和核心之间的接口
- [docs/主窗口.md](docs/主窗口.md)：主窗口的设计；原型是 [docs/主窗口原型.html](docs/主窗口原型.html)
- [CONTEXT.md](CONTEXT.md)：本项目的术语

## 许可、安全、贡献

Apache License 2.0，见 [LICENSE](LICENSE) 和 [NOTICE](NOTICE)。给应用拷的 `luoke_agent/mcp.py`、`cards.py`、`a2ui.py` 也可以按 MIT 用（[LICENSE-MIT](LICENSE-MIT)）。「螺壳」的名称和图标不随许可授予。

安全问题见 [SECURITY.md](SECURITY.md)，参与开发见 [CONTRIBUTING.md](CONTRIBUTING.md)。

© 螺壳实验室 Luoke Labs
