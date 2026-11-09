#!/bin/bash
# 在一台远程 Mac 上编译、测试、截图；本机只改代码。机器由 LUOKE_DEV_HOST 给（ssh 的主机名），从仓库里跑：
#   scripts/remote_dev.sh             同步过去，跑 Python、LuokeA2UI、LuokeWindow 的测试
#   scripts/remote_dev.sh shots [目录]  同步过去，截全部界面，图拷回本机（默认 .tmp/shots）
#   scripts/remote_dev.sh run <命令…>   同步过去，在远程的副本里跑一条命令
# 远程放在家目录下的 LUOKE_DEV_DIR（默认 luoke-agent-dev）；两个会话同时用一台机器时各设一个，免得互相覆盖。
# 共用的机器：低优先级跑，不开窗口、不弹框；LUOKE_DEV_QUIET 里的时段不跑（默认 09:50-10:30,20:50-21:30）。
# 每个 PR 的检查不在这里，在 GitHub Actions（.github/workflows/ci.yml）。
set -euo pipefail
HOST=${LUOKE_DEV_HOST:?要设 LUOKE_DEV_HOST：远程 Mac 的 ssh 主机名}
DEV=${LUOKE_DEV_DIR:-luoke-agent-dev}
case "$DEV" in */*|.*|"") echo "LUOKE_DEV_DIR 只写一个目录名" >&2; exit 2 ;; esac
hm=$((10#$(date +%H%M)))
for span in $(echo "${LUOKE_DEV_QUIET-09:50-10:30,20:50-21:30}" | tr ',' ' '); do
    from=$((10#$(echo "${span%-*}" | tr -d :))); to=$((10#$(echo "${span#*-}" | tr -d :)))
    if [ $hm -ge $from ] && [ $hm -le $to ]; then
        echo "现在在 LUOKE_DEV_QUIET 的时段里（${span}），等过了再跑" >&2
        exit 3
    fi
done
cd "$(git rev-parse --show-toplevel)"
rsync -a --delete --exclude .git --exclude .build --exclude .swiftpm --exclude __pycache__ --exclude .tmp \
    --exclude build.noindex ./ "$HOST:$DEV/work/"
remote() {
    ssh "$HOST" "export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin; cd ~/$DEV/work && $1"
}
case "${1:-test}" in
    test)
        remote "nice -n 10 /usr/bin/python3 -B -m unittest discover -s tests -t . &&
                nice -n 10 swift test --package-path a2ui --scratch-path ~/$DEV/cache/a2ui &&
                nice -n 10 swift test --package-path window --scratch-path ~/$DEV/cache/window"
        ;;
    shots)
        out=${2:-.tmp/shots}
        remote "rm -rf ~/$DEV/shots-dev && mkdir -p ~/$DEV/shots-dev &&
                nice -n 10 swift run --package-path window --scratch-path ~/$DEV/cache/window luoke-window-shots ~/$DEV/shots-dev"
        mkdir -p "$out"
        rsync -a --delete "$HOST:$DEV/shots-dev/" "$out/"
        echo "截图在 $out"
        ;;
    run)
        shift
        remote "nice -n 10 $*"
        ;;
    *)
        sed -n 2,7p "$0" >&2
        exit 2
        ;;
esac
