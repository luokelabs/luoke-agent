#!/bin/sh
# 把 luoke-mem 已提交的 luoke_mem 拷进 vendor/（不取工作区里没提交的改动），记下版本和提交号。
# 只拷工具用的三个模块：__init__、memory、sensitive（luoke-mem DESIGN「版本和兼容」，learn、hub、ui 是螺壳记忆 app 自己的），外加 luoke-mem 的 LICENSE。
# 拷完先在临时目录里单独导入一遍（别处装的 luoke_mem 混不进来），导入不了就报错退出，vendor/ 里原来那份不动。
# 例如 luoke_mem 0.28.0 只带这三个模块导入不了（导入时要读 prompts/labels.json），0.28.1 起又可以了。
# 用法：scripts/vendor-luoke-mem.sh [luoke-mem 仓库的路径，默认 ../luoke-mem] [提交，默认 HEAD]
# 用哪个 Python 导入：环境变量 PYTHON，默认 PATH 里的 python3
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
src=${1:-"$here/../luoke-mem"}
rev=${2:-HEAD}
python=${PYTHON:-python3}
[ -d "$src/.git" ] || { echo "找不到 luoke-mem 仓库：$src" >&2; exit 1; }
commit=$(git -C "$src" rev-parse --verify "$rev^{commit}")
mkdir -p "$here/vendor"
tmp=$(mktemp -d "$here/vendor/.luoke_mem.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
git -C "$src" archive "$commit" luoke_mem/__init__.py luoke_mem/memory.py luoke_mem/sensitive.py | tar -x -C "$tmp"
git -C "$src" show "$commit:LICENSE" > "$tmp/luoke_mem/LICENSE"  # MIT，随拷的模块一起带上（NOTICE）
# -I：不看 PYTHONPATH、用户目录和当前目录；临时目录自己插在最前面，导入的必须是刚拷的这份
check='import os, sys
here = os.path.realpath(sys.argv[1])
sys.path.insert(0, here)
import luoke_mem, luoke_mem.memory, luoke_mem.sensitive
got = os.path.realpath(os.path.dirname(luoke_mem.__file__))
assert got == os.path.join(here, "luoke_mem"), "导入的不是刚拷的这份：" + got'
if ! out=$("$python" -I -B -c "$check" "$tmp" 2>&1); then
  echo "luoke_mem ${commit} 只带三个模块导入不了，vendor/ 没换：" >&2
  printf '%s\n' "$out" | tail -5 >&2
  exit 1
fi
rm -rf "$here/vendor/luoke_mem"
mv "$tmp/luoke_mem" "$here/vendor/luoke_mem"
version=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$here/vendor/luoke_mem/__init__.py")
printf 'luoke_mem %s\ncommit %s\n' "$version" "$commit" > "$here/vendor/luoke_mem.VERSION"
cat "$here/vendor/luoke_mem.VERSION"
