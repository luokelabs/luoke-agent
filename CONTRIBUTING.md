# 参与贡献

luoke-agent 现在处于**封闭测试**。欢迎提 issue：

- **卡片、提醒不对**：哪类事、什么时候说的、你觉得应该怎样。**不要贴真实的卡片、邮件或记忆**，人名、标题换成编造的；能写成 `tests/` 里那样用假应用复现的最好。
- **主窗口画错了**：附截图前先遮住里面的真实内容。
- **安全问题**不要开公开 issue，见 [SECURITY.md](SECURITY.md)。

## 改代码

1. **先开 issue 说明要改什么、为什么**，商量好再动手。改[工具协议](docs/工具协议.md)、[界面接口](docs/界面接口.md)、卡片能用的组件，尤其要先说：应用和螺壳.app 都跟着它们走。
2. 核心只用 Python 标准库，Python 3.9 起要能跑；Swift 包不加第三方依赖，只用 macOS 自带的框架。
3. 提交前跑：

   ```bash
   python3 -B -m unittest discover -s tests -t .
   swift test --package-path a2ui
   swift test --package-path window
   ```

   测试只用临时目录里的记忆和假应用（`luoke_agent/fake_tool.py`），socket 只开在临时目录里，不碰你的数据、不联网。自己试核心也一样：`--home`、`--memory` 都指到临时目录。
   - 改了主窗口，用 `swift run --package-path window luoke-window-shots <目录>` 截全部界面看一遍。每个 PR 的检查（`.github/workflows/ci.yml`）会跑全部测试、截图，在 PR 上贴出和 main 比变了哪些界面。
4. **守住这几条**：
   - 会改动东西的，只在用户点了以后才做；没有点按的写入调用一律拒绝。
   - 卡片只用目录里的组件，过校验才画；打开网页的按钮要去的网站由核心写在按钮旁边，应用自己写的不认。
   - 日志只记元数据（编号、类别、时间、结果码），不记内容；不加新的联网。
5. **README 有中英两份**（`README.md`、`README.en.md`），改一份就在同一个提交里改另一份。

## 行为准则

友善、就事论事，尊重每一位参与者。
