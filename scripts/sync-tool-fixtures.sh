#!/bin/sh
# 把一个工具仓库里已提交的场景样例（它的 fixtures/agent/）拷进 fixtures/<工具>/（不取工作区里没提交的改动），
# 记下提交号。样例是工具录的真实答复、两边之间的接口说明（docs/工具协议.md「场景样例」）；agent 这边不改它们。
# 拷完跑 python3 scripts/window_samples.py 重新生成窗口的示例，再跑测试。
# 用法：scripts/sync-tool-fixtures.sh <工具，例如 luoke-scan> [工具仓库的路径，默认 ../<工具>] [提交，默认 HEAD]
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
tool=${1:?要给工具的名字，例如 luoke-scan}
case "$tool" in luoke-[a-z]*) ;; *) echo "工具的名字是 luoke-…：$tool" >&2; exit 2 ;; esac
case "$tool" in */*|*.*) echo "工具的名字里不能有 / 和 .：$tool" >&2; exit 2 ;; esac
src=${2:-"$here/../$tool"}
rev=${3:-HEAD}
git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || { echo "找不到 $tool 的仓库：$src" >&2; exit 1; }
commit=$(git -C "$src" rev-parse --verify "$rev^{commit}")
git -C "$src" cat-file -e "$commit:fixtures/agent" 2>/dev/null || { echo "$commit 里没有 fixtures/agent/" >&2; exit 1; }
dest="$here/fixtures/$tool"
rm -rf "$dest"
mkdir -p "$dest"
git -C "$src" archive "$commit" fixtures/agent | tar -x -C "$dest" --strip-components 2
printf '%s fixtures/agent\ncommit %s\n' "$tool" "$commit" > "$here/fixtures/$tool.VERSION"
cat "$here/fixtures/$tool.VERSION"
