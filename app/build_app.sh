#!/bin/sh
# 打出「螺壳 agent.app」到 build.noindex/（不进 Spotlight，打完从 LaunchServices 注销，顶层 CLAUDE.md）。
# 默认开发版：bundle id ai.luoke.agent.dev，名字「螺壳 agent（开发）」（10-24 起用户看到的「螺壳」是主控，agent 并进它；之前先叫这个，不和主控撞名），ad-hoc 签名。
# --release：正式的 bundle id ai.luoke.agent；Developer ID 签名和公证照 luoke-core 的 tools/release_sign.sh 另做。
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
bundle_id=ai.luoke.agent.dev
display="螺壳 agent（开发）"
if [ "${1:-}" = "--release" ]; then bundle_id=ai.luoke.agent; display="螺壳 agent"; fi
version=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$here/luoke_agent/__init__.py")
swift build -c release --package-path "$here/app" >/dev/null
bin="$(swift build -c release --package-path "$here/app" --show-bin-path)/Luoke"
app="$here/build.noindex/螺壳 agent.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/core"
cp "$bin" "$app/Contents/MacOS/Luoke"
# 核心：只带源码和自带的 luoke_mem，不带 __pycache__（往 .app 里写会弄坏签名）
rsync -a --include='*/' --include='*.py' --include='*.html' --exclude='*' "$here/luoke_agent" "$here/vendor" "$app/Contents/Resources/core/"
cp "$here/vendor/luoke_mem.VERSION" "$app/Contents/Resources/core/vendor/"
# 应用图标（app/icon/，从 luoke-brand 拷来的 1024 图）做成 .icns
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
for s in 16 32 128 256 512; do
    sips -z $s $s "$here/app/icon/agent-1024.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$here/app/icon/agent-1024.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>$display</string>
  <key>CFBundleDisplayName</key><string>$display</string>
  <key>CFBundleExecutable</key><string>Luoke</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>螺壳实验室 Luoke Labs</string>
</dict></plist>
PLIST
# 给主控的配件清单（luoke-core V1 §8，2026-10-15 和 luoke-core 定）
cat > "$app/Contents/Resources/luoke-accessory.json" <<JSON
{
  "contract": 1,
  "accessory": "luoke-agent",
  "bundle_id": "$bundle_id",
  "name": "螺壳 agent",
  "version": "$version",
  "type": "app",
  "entry": [],
  "resident": true,
  "memory": true,
  "ui_element": true,
  "tasks": [],
  "data": ["~/.luoke/agent"]
}
JSON
codesign --force --sign - "$app" >/dev/null 2>&1
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" >/dev/null 2>&1 || true
echo "${app}（${bundle_id} ${version}）"
