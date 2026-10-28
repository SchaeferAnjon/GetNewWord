#!/bin/zsh
# 发一个正式版，分两步（照 MeetCaption 的 scripts/release.mjs）：
#   1. scripts/release.sh            编译（Apple 芯片 + Intel）→ Developer ID 签名 → DMG → Sparkle 更新清单，
#                                    每一步都核对，文件和核对记录放在 release/<版本>/，不上传。
#   2. scripts/release.sh --publish  在本机 HEAD 上打 tag v<版本> 推上去，把第 1 步核对过的那一份传到 GitHub Release，不重新编译。
# 第 1 步之前先写发布说明 release/<版本>/notes.md（release/ 不进 git）：第 1 步把它写进 appcast，
# 装着的人在 Sparkle 更新窗口里看到的就是它；第 2 步拿它当 Release 正文，后面加 SHA-256。格式看 docs/release-notes/。
#
# 不公证（用户 2026-10-27 定的，会议字幕和 Ask Free 也一样）：第一次打开时 macOS 会拦一下，
# README、官网和发布说明教用户去「系统设置 › 隐私与安全性」点「仍要打开」。之后 Sparkle 自动更新不再弹。
#
# 需要（只有维护者有）：
#   - 钥匙串里团队 3H5S5NXPXS 的 "Developer ID Application" 证书
#   - Sparkle 签名私钥：登录钥匙串 account "getnewword"，或者 SPARKLE_KEY_FILE=<私钥文件>
#   - gh 已登录，能推这个仓库
#   - Xcode 自带的 python3：第一次运行时在 build/release-tools 装 dmgbuild 和 Markdown（scripts/release-requirements.txt）
#   - 读不到上一版的 build 号时（GitHub 上没有 Release，或本机没有上一版的 tag）：PREV_BUILD=<上一版的 build 号>
set -euo pipefail
cd "$(dirname "$0")/.."
# 要发的提交得先在 GitHub Actions 的 build 上通过（仓库私有、CI 没开时只提示）
scripts/require-ci.sh HEAD

REPO=SchaeferAnjon/GetNewWord
TEAM=3H5S5NXPXS
IDENTITY="Developer ID Application"
case "${1:-}" in
  "") PUBLISH=0 ;;
  --publish) PUBLISH=1 ;;
  *) print -u2 "用法：scripts/release.sh [--publish]"; exit 2 ;;
esac

fail() { print -u2 "没发：$*"; exit 1 }
# 联网的命令给个时限，卡住就报错（macOS 没有 timeout 命令）
limit() { perl -e 'alarm shift; exec @ARGV or die "$ARGV[0]: $!\n"' "$@" }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" }

VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml)
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && $BUILD =~ '^[0-9]+$' ]] \
  || fail "project.yml 里读不出版本号（MARKETING_VERSION=$VERSION，CURRENT_PROJECT_VERSION=$BUILD）"
TAG=v$VERSION
OUT=release/$VERSION
NOTES=$OUT/notes.md
DMG_NAME=GetNewWord-$VERSION.dmg
DMG=$OUT/$DMG_NAME
DOWNLOAD_PREFIX=https://github.com/$REPO/releases/download/$TAG/
print "== GetNewWord $VERSION（build $BUILD）"

# 代码和要发的版本对得上：工作区干净，HEAD 已经在 origin/main 上，tag 没指着别的提交，GitHub 上还没有这个 Release
[[ -z $(git status --porcelain) ]] || fail "工作区有没提交的改动（git status）"
HEAD=$(git rev-parse HEAD)
limit 120 git fetch -q --tags origin main || fail "git fetch origin 没成功"
git merge-base --is-ancestor HEAD origin/main || fail "HEAD（${HEAD:0:7}）还没推到 origin/main"
TAGGED=$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" || true)
[[ -z $TAGGED || $TAGGED == $HEAD ]] || fail "$TAG 已经指着 ${TAGGED:0:7}，不是 HEAD（${HEAD:0:7}）"
if out=$(limit 60 gh release view "$TAG" --repo "$REPO" --json tagName 2>&1); then
  fail "GitHub 上已经有 $TAG 的 Release"
elif [[ $out != *"release not found"* ]]; then
  fail "查不了 GitHub 上的 Release：$out"
fi
[[ -s $NOTES ]] || fail "还没写发布说明 $NOTES（格式看 docs/release-notes/）"
grep -qF "$VERSION" "$NOTES" || fail "$NOTES 里没提到 $VERSION，是不是上一版的说明？"
[[ $(limit 60 gh repo view "$REPO" --json visibility -q .visibility) == PUBLIC ]] \
  || print "!! 仓库 $REPO 现在不是公开的：没登录 GitHub 的人下载不了 DMG，装着的 Sparkle 也读不到 appcast.xml"

if (( PUBLISH )); then
  # 只上传第 1 步核对过的那一份，不重新编译
  [[ -f $OUT/checked.json ]] || fail "$OUT 还没核对过：先跑 scripts/release.sh"
  [[ $(plutil -extract head raw -o - "$OUT/checked.json") == $HEAD ]] \
    || fail "$OUT 不是这个提交（${HEAD:0:7}）核对过的：先重跑 scripts/release.sh"
  (cd "$OUT" && shasum -a 256 -c --quiet checked.sha256) \
    || fail "第 1 步之后安装包、appcast 或发布说明又改过：重跑 scripts/release.sh"
  [[ -n $TAGGED ]] || git tag "$TAG" "$HEAD"
  limit 120 git push -q origin "refs/tags/$TAG" || fail "推 tag $TAG 没成功"
  limit 900 gh release create "$TAG" --repo "$REPO" --verify-tag --title "GetNewWord $VERSION" \
    --notes-file "$OUT/release-body.md" "$DMG" "$OUT/GetNewWord.dmg" "$OUT/appcast.xml" \
    || fail "gh release create 没成功（tag $TAG 已经推上去了）"
  print "已发布 $TAG：https://github.com/$REPO/releases/tag/$TAG"
  print "装着 Sparkle 版本（1.2.0 起）的会在一天内查到；1.1.x 没有自动更新，要手动下载。"
  exit 0
fi

# 写好的发布说明留着，其余重新来
find "$OUT" -mindepth 1 -maxdepth 1 ! -name notes.md -exec rm -rf {} +

# 上一版的 build 号：从最新 Release 的 appcast.xml 读；那一版没有 appcast（1.1.x 还没有 Sparkle）就读它那个 tag 的 Info.plist。
# GitHub 上一个 Release 也没有，或者本机没有那个 tag（删掉旧的 v1.0.0 到 v1.1.2 以后发 1.2.0 就是这样），
# 用环境变量 PREV_BUILD 给的数（v1.1.2 是 4）；没设就停下。
prev_from_env() {
  [[ -n ${PREV_BUILD:-} ]] \
    || fail "$1，读不到上一版的 build 号。用 PREV_BUILD=<上一版的 build 号> scripts/release.sh 再跑一次（v1.1.2 是 4）"
  PREV_FROM="环境变量 PREV_BUILD，因为 $1"
}
if ! LATEST=$(limit 60 gh release view --repo "$REPO" --json tagName -q .tagName 2>"$OUT/gh.err"); then
  grep -q "release not found" "$OUT/gh.err" || fail "查不了 GitHub 上最新的 Release：$(<"$OUT/gh.err")"
  prev_from_env "GitHub 上还没有 Release"
elif limit 120 gh release download "$LATEST" --repo "$REPO" --pattern appcast.xml --output "$OUT/prev-appcast.xml" 2>"$OUT/gh.err"; then
  PREV_BUILD=$(grep -oE 'sparkle:version(>|=")[0-9]+' "$OUT/prev-appcast.xml" | grep -oE '[0-9]+$' | sort -n | tail -1 || true)
  PREV_FROM="$LATEST 的 appcast.xml"
elif grep -q "no assets match" "$OUT/gh.err"; then
  if git cat-file -e "$LATEST:GetNewWord/Info.plist" 2>/dev/null; then
    PREV_BUILD=$(git show "$LATEST:GetNewWord/Info.plist" | plutil -extract CFBundleVersion raw -o - - || true)
    PREV_FROM="$LATEST 的 Info.plist（那一版没有 appcast）"
  else
    prev_from_env "$LATEST 没有 appcast.xml，本机也没有 $LATEST 这个 tag"
  fi
else
  fail "下载 $LATEST 的 appcast.xml 没成功：$(<"$OUT/gh.err")"
fi
rm -f "$OUT/gh.err" "$OUT/prev-appcast.xml"
[[ $PREV_BUILD =~ '^[0-9]+$' ]] || fail "读不出上一版的 build 号（$PREV_FROM）"
(( BUILD > PREV_BUILD )) \
  || fail "build 号 $BUILD 不比上一版（$PREV_FROM）的 $PREV_BUILD 大：改大 project.yml 的 CURRENT_PROJECT_VERSION，不然装着的收不到这次更新"
print "build $BUILD > 上一版 $PREV_BUILD（$PREV_FROM）"

TOOLS=build/release-tools
if ! cmp -s scripts/release-requirements.txt "$TOOLS/requirements.txt"; then
  print "== 装 dmgbuild 和 Markdown 到 $TOOLS"
  rm -rf "$TOOLS" && /usr/bin/python3 -m venv "$TOOLS"
  limit 600 "$TOOLS/bin/pip" install -q --disable-pip-version-check -r scripts/release-requirements.txt || fail "装 dmgbuild 和 Markdown 没成功"
  cp scripts/release-requirements.txt "$TOOLS/requirements.txt"
fi

# 编译：先清掉上次的 Release 产物，编译失败就停（不会把旧包签名发出去）
print "== 编译（Release，arm64 + x86_64，日志 $OUT/xcodebuild.log）"
xcodegen generate >/dev/null
[[ -z $(git status --porcelain) ]] || fail "xcodegen 改了进 git 的文件（多半是 Info.plist 没跟 project.yml 一起提交）：$(git status --porcelain | head -3)"
rm -rf build/DerivedData/Build/Products/Release
xcodebuild -project GetNewWord.xcodeproj -scheme GetNewWord -configuration Release -derivedDataPath build/DerivedData \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build >"$OUT/xcodebuild.log" 2>&1 \
  || { grep -E "error:" "$OUT/xcodebuild.log" | head -20 >&2; fail "编译失败，完整日志在 $OUT/xcodebuild.log" }
APP=$OUT/GetNewWord.app
ditto build/DerivedData/Build/Products/Release/GetNewWord.app "$APP"

# Sparkle 里的辅助程序要单独带 hardened runtime 和时间戳签一遍（Sparkle 文档「Distributing」）
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@" || fail "签名没成功：${@[-1]}" }
sign "$SPK/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPK/XPCServices/Downloader.xpc"
sign "$SPK/Autoupdate"
sign "$SPK/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements GetNewWord/GetNewWord.entitlements "$APP"

# 编出来的 App：版本号、build 号、两种芯片、团队和 Developer ID、hardened runtime
check_app() {
  local app=$1 archs info
  codesign --verify --deep --strict "$app" || fail "$app 的签名校验没过"
  [[ $(plist "$app" CFBundleShortVersionString) == $VERSION ]] || fail "$app 的版本是 $(plist "$app" CFBundleShortVersionString)，不是 $VERSION"
  [[ $(plist "$app" CFBundleVersion) == $BUILD ]] || fail "$app 的 build 号是 $(plist "$app" CFBundleVersion)，不是 $BUILD"
  archs=" $(lipo -archs "$app/Contents/MacOS/GetNewWord") "
  [[ $archs == *" arm64 "* && $archs == *" x86_64 "* ]] || fail "$app 只有$archs，要 arm64 和 x86_64 都有"
  info=$(codesign -dvv "$app" 2>&1)
  [[ $info == *"TeamIdentifier=$TEAM"* && $info == *"Authority=Developer ID Application:"* ]] \
    || fail "$app 不是团队 $TEAM 的 Developer ID 签的"
  [[ $info == *"(runtime)"* ]] || fail "$app 没开 hardened runtime"
}

check_app "$APP"

# DMG：窗口排好版（背景箭头、两个图标的位置、卷图标），卷名「GetNewWord <版本>」
print "== DMG"
ICON=$APP/Contents/Resources/AppIcon.icns
[[ -f $ICON ]] || fail "App 里没有 AppIcon.icns"
mkdir -p "$OUT/dmg-background"
swift scripts/dmg/background.swift "$OUT/dmg-background" || fail "画 DMG 背景图没成功"
"$TOOLS/bin/python" scripts/dmg/build.py "GetNewWord $VERSION" "$DMG" "$APP" "$ICON" "$OUT/dmg-background/background.png" \
  >"$OUT/dmgbuild.log" 2>&1 || fail "打 DMG 没成功，看 $OUT/dmgbuild.log"
rm -rf "$OUT/dmg-background"

# 打完先只读挂载检查一遍，再签名
MNT=$PWD/$OUT/mnt
mkdir -p "$MNT"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null || fail "挂载 $DMG 没成功"
trap 'hdiutil detach -quiet -force "$MNT"' EXIT
problems=()
[[ $(diskutil info -plist "$MNT" | plutil -extract VolumeName raw -o - -) == "GetNewWord $VERSION" ]] || problems+="卷名不是「GetNewWord $VERSION」"
[[ -d $MNT/GetNewWord.app ]] || problems+="没有 GetNewWord.app"
[[ -L $MNT/Applications && $(readlink "$MNT/Applications") == /Applications ]] || problems+="没有指向 /Applications 的替身"
[[ -f $MNT/.background.tiff ]] || problems+="没有背景图 .background.tiff"
cmp -s "$MNT/.VolumeIcon.icns" "$ICON" || problems+=".VolumeIcon.icns 不是 App 的图标"
# 卷根目录的 FinderInfo 要有「自定义图标」这一位（第 9 个字节的 0x04），Finder 才显示 .VolumeIcon.icns
(( 0x$(xattr -px com.apple.FinderInfo "$MNT" 2>/dev/null | tr -d ' \n' | cut -c17-18 || print 00) & 0x04 )) || problems+="卷没有标自定义图标"
# .DS_Store 里要有窗口设置（icvp，含背景图）和图标位置（Iloc），不能有 pBBk（有它 Finder 不画背景，见 scripts/dmg/build.py）
grep -q icvp "$MNT/.DS_Store" && grep -q Iloc "$MNT/.DS_Store" || problems+=".DS_Store 里没有窗口设置或图标位置"
grep -q pBBk "$MNT/.DS_Store" && problems+=".DS_Store 里有 pBBk，Finder 会不画背景"
(( ${#problems} == 0 )) || fail "DMG 有问题：${(j:；:)problems}"
check_app "$MNT/GetNewWord.app"
hdiutil detach -quiet "$MNT" && trap - EXIT && rmdir "$MNT"

codesign --force --sign "$IDENTITY" --timestamp "$DMG" || fail "DMG 签名没成功"
[[ $(codesign -dvv "$DMG" 2>&1) == *"TeamIdentifier=$TEAM"* ]] || fail "DMG 不是团队 $TEAM 签的"

# Sparkle 更新清单：发布说明转成和 DMG 同名的 .html，generate_appcast 把它写进 <description>
print "== Sparkle 更新清单"
SPARKLE_BIN=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
mkdir -p "$OUT/appcast" && cp "$DMG" "$OUT/appcast/"
{
  print -r -- '<style>:root{color-scheme:light dark}body{font:13px/1.5 -apple-system,"PingFang SC",sans-serif}h2{font-size:14px;margin:1.2em 0 .4em}table{border-collapse:collapse;font:inherit}th,td{border:1px solid rgba(127,127,127,.35);padding:3px 8px;text-align:left}code{font:12px ui-monospace,Menlo,monospace}</style>'
  "$TOOLS/bin/python" -m markdown -e utf-8 -x tables "$NOTES"
} >"$OUT/appcast/GetNewWord-$VERSION.html" || fail "发布说明转 HTML 没成功"
KEY=(--account getnewword)
[[ -n ${SPARKLE_KEY_FILE:-} ]] && KEY=(--ed-key-file "$SPARKLE_KEY_FILE")
"$SPARKLE_BIN/generate_appcast" $KEY --download-url-prefix "$DOWNLOAD_PREFIX" "$OUT/appcast" >"$OUT/generate_appcast.log" 2>&1 \
  || fail "generate_appcast 没成功，看 $OUT/generate_appcast.log"
APPCAST=$OUT/appcast/appcast.xml
problems=()
[[ $(grep -c "<item>" "$APPCAST") == 1 ]] || problems+="条目不是正好一条"
grep -qF "url=\"$DOWNLOAD_PREFIX$DMG_NAME\"" "$APPCAST" || problems+="下载地址不是 $DOWNLOAD_PREFIX$DMG_NAME"
grep -qF "length=\"$(stat -f %z "$DMG")\"" "$APPCAST" || problems+="文件大小和 DMG 对不上"
grep -qF "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST" || problems+="sparkle:version 不是 $BUILD"
grep -qF "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST" || problems+="shortVersionString 不是 $VERSION"
grep -qF "<description><![CDATA[" "$APPCAST" || problems+="没写进发布说明"
SIG=$(grep -oE 'sparkle:edSignature="[^"]+"' "$APPCAST" | cut -d'"' -f2)
if [[ -z $SIG ]]; then
  problems+="没有 edSignature"
else
  # 签名要能用 App 里的 SUPublicEDKey 验过，不然装着的会拒绝这次更新
  swift - "$(plist "$APP" SUPublicEDKey)" "$SIG" "$DMG" <<'EOF' || problems+="edSignature 用 App 里的 SUPublicEDKey 验不过（私钥和公钥不是一对）"
import CryptoKit
import Foundation
let a = CommandLine.arguments
guard let pub = Data(base64Encoded: a[1]), let sig = Data(base64Encoded: a[2]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub),
      let file = FileManager.default.contents(atPath: a[3]) else { exit(2) }
exit(key.isValidSignature(sig, for: file) ? 0 : 1)
EOF
fi
(( ${#problems} == 0 )) || fail "appcast.xml 有问题：${(j:；:)problems}"

# 要上传的：带版本号的 DMG、不带版本号的同一个 DMG（官网和 README 链 releases/latest/download/GetNewWord.dmg）、appcast.xml
cp "$APPCAST" "$OUT/appcast.xml"
cp "$DMG" "$OUT/GetNewWord.dmg"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
{
  cat "$NOTES"
  print -r -- ""
  print -r -- "SHA-256（\`$DMG_NAME\` 和 \`GetNewWord.dmg\` 是同一个文件）：\`$SHA\`"
} >"$OUT/release-body.md"
print -r -- "{\"version\":\"$VERSION\",\"build\":\"$BUILD\",\"head\":\"$HEAD\"}" >"$OUT/checked.json"
(cd "$OUT" && shasum -a 256 "$DMG_NAME" GetNewWord.dmg appcast.xml notes.md release-body.md >checked.sha256)

print "\n$TAG 要上传的文件（$OUT）："
for f in "$DMG_NAME" GetNewWord.dmg appcast.xml; do print "  $f  $(( $(stat -f %z "$OUT/$f") / 1000 )) KB"; done
print "  SHA-256 $SHA"
print "Release 正文：$OUT/release-body.md"
print "\n核对过了，还没上传。打开 DMG 和 App 看一遍，没问题再：scripts/release.sh --publish"
