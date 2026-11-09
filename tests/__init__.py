"""测试包：在导入 luoke_agent 和 luoke_mem 之前，先把一切指到临时目录，并打开"拒绝真实位置"的保护
（luoke_agent/safety.py）。unittest 发现测试时先导入这个包，所以不管单跑哪个文件、按什么顺序，都先经过这里。"""
import os
import tempfile

os.environ["LUOKE_AGENT_TESTING"] = "1"
_home = tempfile.mkdtemp(prefix="la-home")
os.environ["LUOKE_HOME"] = os.path.join(_home, "luoke")          # luoke_mem 的默认位置也落在临时目录
os.environ["LUOKE_HUB_SOCKET"] = os.path.join(_home, "no-hub.sock")
