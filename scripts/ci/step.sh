#!/bin/bash
# step.sh <输出目录> <名字> <日志文件> <命令…>
# 跑一条命令：输出照常打出来，同时存进 <输出目录>/<日志文件>；结果和用时记进 <输出目录>/results.tsv
# （post_shots.py 读它写评论）。返回命令自己的退出码。
set -uo pipefail
out=$1 name=$2 log=$3
shift 3
mkdir -p "$out"
t0=$(date +%s)
"$@" 2>&1 | tee "$out/$log"
code=${PIPESTATUS[0]}
if [ "$code" = 0 ]; then r=ok; else r=fail; fi
printf '%s\t%s\t%s\t%s\n' "$name" "$r" "$(( $(date +%s) - t0 ))" "$log" >> "$out/results.tsv"
exit "$code"
