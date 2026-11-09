# luoke-agent

[简体中文](README.md) | English

The part of 螺壳 (Luoke) behind its main window and reminders. It gathers what Luoke Memory and the apps in Luoke want to tell you, picks the moment to say it, shows what needs your decision as cards, and acts only after you click. It is not a separate app: it ships inside 螺壳.

## What it is

[螺壳 (Luoke)](https://github.com/luokelabs/luoke) is a local AI that runs on your Mac. Inside it, luoke-agent looks after:

- **Today (「今天」)**: urgent things, things waiting for your decision, and things already done for you (which you can undo or put back), one card each. You can also go through them one at a time.
- **Reminders**: urgent things (a suspected phishing email, say) right away; everything else collected into a brief, by default once each morning. When to speak, quiet hours and how each kind of item is handled can all be changed in Settings · Reminders.
- **The protocol with apps**: apps such as Luoke Mail Assistant and Luoke Scan hand it what they want to tell you and what they can do, following the [tool protocol](docs/工具协议.md) (in Chinese). What you click on a card goes back to the app to carry out, or back to Luoke Memory.

The main window (`window/`) is built into 螺壳.app; the core (`luoke_agent/`) is a Python process that 螺壳 runs. For how the parts of Luoke fit together, see the [system documentation](https://luokelabs.github.io/luoke-atlas/).

## Status

In closed testing; installed with 螺壳 from its beta 2 onwards. The version number is in `luoke_agent/__init__.py`. System requirements are the same as 螺壳's; see [luokelabs/luoke](https://github.com/luokelabs/luoke).

## Using it

Download 螺壳 from [luoke.ai](https://luoke.ai). luoke-agent comes with it and doesn't need turning on under Apps: 螺壳's main window is luoke-agent, and so are the urgent items in the menu bar icon and the brief in notifications.

## Building and testing from source

The core uses only the Python standard library and runs on Python 3.9 or later:

```bash
python3 -B -m unittest discover -s tests -t .
```

The Swift packages that draw cards and the main window (Swift 6, macOS 14 or later):

```bash
swift test --package-path a2ui
swift test --package-path window
```

To look at the main window with sample data and no core, or to capture every screen as images (light and dark):

```bash
swift run --package-path window luoke-window-demo
swift run --package-path window luoke-window-shots <directory>
```

To run the core on its own (for development). The data directory and the memory file must be given; if they can't be found it stops rather than falling back to a default location:

```bash
python3 -m luoke_agent serve --home <data directory> --memory <memory file> --tool <app>=<socket> --dev
python3 -m luoke_agent feed --home <data directory>      # show the current cards
```

`luoke_agent/fake_tool.py` is a fake app that stands in for real ones during development and testing. The tests use only a memory file and fake apps in temporary directories and never touch your data.

## Data and privacy

- **It runs only on your Mac and doesn't connect to the internet.** The core talks only to 螺壳 and the apps on the same Mac, over Unix sockets; when a model is needed, 螺壳 runs it locally.
- **Anything that changes something happens only after you click.** That includes buttons that open a web page; the site they go to is shown next to the button.
- **Data lives in `~/.luoke/agent/`**, readable only by your account. `state.db` holds each item's state, the cards, your settings and how you've responded to each kind of item. It reads Luoke Memory, and your answers on cards go back to Luoke Memory.
- **Logs record only metadata** (ids, kinds, times, result codes), never the content of emails or cards.

## Documentation (in Chinese)

- [DESIGN.md](DESIGN.md): how it runs, reading memory, talking to apps, choosing when to speak, and the ground rules
- [docs/工具协议.md](docs/工具协议.md): the protocol an app implements to plug into Luoke (MCP)
- [docs/界面接口.md](docs/界面接口.md): the interface between 螺壳.app and the core
- [docs/主窗口.md](docs/主窗口.md): the main window's design; the prototype is [docs/主窗口原型.html](docs/主窗口原型.html)
- [CONTEXT.md](CONTEXT.md): this project's terms

## License, security, contributing

Apache License 2.0; see [LICENSE](LICENSE) and [NOTICE](NOTICE). `luoke_agent/mcp.py`, `cards.py` and `a2ui.py`, which apps copy, may also be used under MIT ([LICENSE-MIT](LICENSE-MIT)). The name 螺壳 and its icons are not licensed.

For security issues see [SECURITY.md](SECURITY.md); to contribute see [CONTRIBUTING.md](CONTRIBUTING.md).

© 螺壳实验室 Luoke Labs
