#!/bin/sh
# 把主窗口的演示程序打成一个开发版 .app：build.noindex/螺壳窗口演示.app，bundle id ai.luoke.window.demo。
# 给谁用：在本机看最新的界面（示例数据，不连日常在用的螺壳、不读真的邮件和记忆）；有了 bundle id，
# 自动化工具也认得出这个窗口。打完从 LaunchServices 注销，不进 Spotlight；ad-hoc 签名。
#
#   window/build_demo_app.sh            只打
#   window/build_demo_app.sh --open     打完打开（传给演示程序的参数写在后面，例如 --open --agent <数据目录>/run/agent.sock）
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
bundle_id=ai.luoke.window.demo
display="螺壳窗口演示"
version=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$here/luoke_agent/__init__.py")

swift build --package-path "$here/window" --product luoke-window-demo >/dev/null
bin_dir=$(swift build --package-path "$here/window" --show-bin-path)

app="$here/build.noindex/$display.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/luoke-window-demo" "$app/Contents/MacOS/luoke-window-demo"
# 资源包放 Contents/Resources（放 .app 根目录签名过不了；ResourceBundle 先找这里）
cp -R "$bin_dir/LuokeWindow_LuokeWindow.bundle" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>$display</string>
  <key>CFBundleDisplayName</key><string>$display</string>
  <key>CFBundleExecutable</key><string>luoke-window-demo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" >/dev/null 2>&1 || true
echo "$app"

if [ "${1:-}" = "--open" ]; then
    shift
    open -n "$app" --args "$@"
fi
