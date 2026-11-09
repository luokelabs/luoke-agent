# 安全问题

luoke-agent 能读你的螺壳记忆，看得到各个应用交来的事（比如邮件的标题、发件人），还能替你把点按交给应用去做，所以安全问题我们优先处理。下面这些都算：

- **东西离开本机**：记忆、卡片、邮件的内容被发出去；或者核心连了本机以外的地方。
- **不经你点按就做事**：会改动东西的调用（交给应用去做的、交回记忆的）没有你的点按就发了出去；或者别的程序能冒充你点按。
- **接口被别人用**：别的账户、别的程序或网页能连上核心给螺壳.app 用的 socket（数据目录下的 `run/agent.sock`），或者冒充某个应用连进来。
- **卡片骗人**：应用、记忆交来的文字能让卡片冒充别的应用，让打开网页的按钮去的网站和旁边写的对不上，或者让主窗口一直卡住。
- **日志里有内容**：邮件、卡片、记忆的文字进了日志。

**请不要在公开 issue 里写细节**，用 GitHub 的私密漏洞报告：

1. 打开本仓库的 **Security** 页；
2. 点 **Report a vulnerability**，写清楚版本（`luoke_agent/__init__.py` 里的 `__version__`）、macOS 版本、怎么复现、可能的影响。

如果本仓库的 Security 页还没有这个按钮，请报到顶层仓库 [luokelabs/luoke](https://github.com/luokelabs/luoke/security)。我们会尽快回复，修好以后在发布说明里注明。

请不要在报告里附上真实的卡片、记忆、邮件，或者 `~/.luoke/agent` 里的任何文件。需要样本时，用 `luoke_agent/fake_tool.py` 这个假应用，或者照 `tests/` 里的写法造一份；人名、地址都用编造的。

---

**English.** Please report security issues privately via **Security → Report a vulnerability** on this repository (or on [luokelabs/luoke](https://github.com/luokelabs/luoke/security) if the button is not there yet), not in public issues. In scope: memory, card or email content leaving the Mac, or the core connecting anywhere off the Mac; a call that changes something going out without your click, or another program being able to click for you; other accounts, programs or web pages reaching the core's socket (`run/agent.sock` under the data directory) or posing as an app; text from an app or from memory making a card pose as another app, making a web-page button go somewhere other than the site shown beside it, or freezing the main window; email, card or memory text ending up in the logs. Please include the version (`__version__` in `luoke_agent/__init__.py`) and your macOS version, and don't attach real cards, memories, emails or anything from `~/.luoke/agent`; use the fake app in `luoke_agent/fake_tool.py` or a made-up case written like those in `tests/`.
