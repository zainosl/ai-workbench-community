#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
app_name="AI Workbench Community.app"
build_root="$project_dir/.build-community"
install_root="$HOME/Applications"
installed_app="$install_root/$app_name"

if [[ -d "$installed_app" ]] && pgrep -f "$installed_app/Contents/MacOS/AIWorkbenchNext" >/dev/null; then
    print -u2 "请先退出正在运行的 AI Workbench Community，再重新安装。"
    exit 1
fi

cd "$project_dir"
swift build -c release

mkdir -p "$build_root"
stage_root=$(mktemp -d "$build_root/package.XXXXXX")
app_bundle="$stage_root/$app_name"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources/Templates" "$install_root"
cp .build/release/AIWorkbenchNext "$app_bundle/Contents/MacOS/AIWorkbenchNext"
cp Resources/Info.plist "$app_bundle/Contents/Info.plist"
cp Resources/Templates/*.md "$app_bundle/Contents/Resources/Templates/"
codesign --force --deep --sign - "$app_bundle"

if [[ -e "$installed_app" ]]; then
    backup="$install_root/AI Workbench Community.backup.$(date +%Y%m%d-%H%M%S)-$RANDOM.app"
    mv "$installed_app" "$backup"
    print "旧版已备份到：$backup"
fi
ditto "$app_bundle" "$installed_app"
print "已安装：$installed_app"
print "首次启动后，请打开工作台内显示的本地资料目录完成配置。"
