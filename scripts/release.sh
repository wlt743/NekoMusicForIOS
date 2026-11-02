#!/bin/bash
# 构建未签名 IPA → 上传 GitHub Release → 更新 SideStore 源
#
# 用法：./scripts/release.sh
# 版本号取自 Xcode 工程的 MARKETING_VERSION
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION=$(grep -m1 'MARKETING_VERSION = ' NekoMusic.xcodeproj/project.pbxproj | sed 's/.*MARKETING_VERSION = \(.*\);/\1/')
[ -n "$VERSION" ] || { echo "读不到 MARKETING_VERSION"; exit 1; }
TAG="v${VERSION}"
IPA="build/NekoMusic-${VERSION}-unsigned.ipa"
REPO="wlt743/NekoMusicForIOS_Not-web"

echo "==> 版本 $VERSION"

# 1. 构建（未签名）
rm -rf build/Unsigned
xcodebuild -project NekoMusic.xcodeproj -scheme NekoMusic \
  -configuration Release -sdk iphoneos \
  -derivedDataPath build/Unsigned \
  build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -2

# 2. 打包
rm -rf build/ipa-work "$IPA"
mkdir -p build/ipa-work/Payload
cp -R build/Unsigned/Build/Products/Release-iphoneos/NekoMusic.app build/ipa-work/Payload/
(cd build/ipa-work && zip -qry "../NekoMusic-${VERSION}-unsigned.ipa" Payload)
SIZE=$(stat -f%z "$IPA")
echo "==> $IPA ($SIZE bytes)"

# 3. 上传 Release + 更新源（需要 GitHub token）
python3 - "$VERSION" "$TAG" "$IPA" "$SIZE" "$REPO" <<'PY'
import json, re, subprocess, sys, urllib.request, urllib.error, os

version, tag, ipa, size, repo = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
token = subprocess.check_output(
    "grep -oE 'gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}' "
    "$HOME/.dsh/.credentials.yaml | head -1", shell=True, text=True).strip()
H = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}

# 确保 tag 存在
subprocess.run(["git", "tag", "-f", tag], check=True)
subprocess.run(["git", "push", "--force",
                f"https://{token}@github.com/{repo}.git", tag],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

# 创建或复用 release
req = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases", headers=H)
releases = {r["tag_name"]: r for r in json.loads(urllib.request.urlopen(req, timeout=30).read())}
body = f"版本 {version}，未签名 IPA，可用 SideStore / AltStore 安装或自行重签名。"
if tag in releases:
    rid = releases[tag]["id"]
    d = json.dumps({"name": version, "body": body, "prerelease": False}).encode()
    urllib.request.urlopen(urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases/{rid}", data=d, headers=H, method="PATCH"), timeout=30)
else:
    d = json.dumps({"tag_name": tag, "name": version, "body": body,
                    "prerelease": False, "draft": False}).encode()
    req = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases",
                                 data=d, headers=H, method="POST")
    rid = json.loads(urllib.request.urlopen(req, timeout=30).read())["id"]

# 删旧附件，传新包
req = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/{rid}/assets", headers=H)
for a in json.loads(urllib.request.urlopen(req, timeout=30).read()):
    urllib.request.urlopen(urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases/assets/{a['id']}", headers=H, method="DELETE"), timeout=30)

name = os.path.basename(ipa)
data = open(ipa, "rb").read()
req = urllib.request.Request(
    f"https://uploads.github.com/repos/{repo}/releases/{rid}/assets?name={name}",
    data=data, headers={**H, "Content-Type": "application/octet-stream"}, method="POST")
asset = json.loads(urllib.request.urlopen(req, timeout=300).read())
print(f"==> 上传完成 {asset['name']} ({asset['size']} bytes)")

# 更新公开仓库里的 apps.json（分发源只在公开仓库）
import base64
SRC_REPO = "wlt743/NekoMusicForIOS_Not-web"
src_path = "docs/source/apps.json"

req = urllib.request.Request(
    f"https://api.github.com/repos/{SRC_REPO}/contents/{src_path}?ref=main", headers=H)
cur = json.loads(urllib.request.urlopen(req, timeout=30).read())
doc = json.loads(base64.b64decode(cur["content"]).decode())
app = doc["apps"][0]
entry = {
    "version": version,
    "date": subprocess.check_output(["date", "+%Y-%m-%d"], text=True).strip(),
    "downloadURL": asset["browser_download_url"],
    "size": asset["size"],
    "minOSVersion": "16.0",
}
app["versions"] = [entry] + [v for v in app["versions"] if v["version"] != version]

payload = json.dumps({
    "message": f"release: {version}",
    "content": base64.b64encode(
        json.dumps(doc, ensure_ascii=False, indent=2).encode()).decode(),
    "sha": cur["sha"],
    "branch": "main",
}).encode()
req = urllib.request.Request(
    f"https://api.github.com/repos/{SRC_REPO}/contents/{src_path}", data=payload, headers=H, method="PUT")
urllib.request.urlopen(req, timeout=60)
print(f"==> 公开仓库源已更新到 {version}")
PY

echo "==> 完成。源地址："
echo "https://raw.githubusercontent.com/${REPO}/main/docs/source/apps.json"
