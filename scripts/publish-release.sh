#!/bin/bash
set -euo pipefail

# 发版收尾：建 GitHub Release，并把 Homebrew 配方指到新 tag（不等 CI）。
#
# 用法（在仓库根目录）：
#   bash scripts/publish-release.sh            # 版本号取脚本里的 VERSION
#   bash scripts/publish-release.sh v0.2.0     # 显式指定

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAP_REPO="${STANDUP_TAP_REPO:-x0c/homebrew-tap}"
SOURCE_REPO="${STANDUP_REPO:-x0c/standup-reminder}"

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null || die "未找到 gh"
gh auth status >/dev/null 2>&1 || die "gh 未登录"

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  VERSION="$(/usr/bin/awk -F'"' '/^VERSION=/ {print $2; exit}' standup-reminder.sh)"
  [[ -n "$VERSION" ]] || die "读不到 VERSION"
  TAG="v${VERSION}"
fi
VERSION="${TAG#v}"
printf '==> 发布 %s\n' "$TAG"

printf '==> 跑测试\n'
bash tests/test.sh || die "测试未过，禁止发版"

git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null \
  || die "本地没有 ${TAG} 标签，先打好标签再跑"
git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1 \
  || die "${TAG} 还没推到 origin，先 git push origin --tags"

if gh release view "$TAG" --repo "$SOURCE_REPO" >/dev/null 2>&1; then
  printf '==> Release %s 已存在\n' "$TAG"
else
  printf '==> 创建 Release %s\n' "$TAG"
  gh release create "$TAG" --repo "$SOURCE_REPO" --title "$TAG" --generate-notes
fi

ARCHIVE_URL="https://github.com/${SOURCE_REPO}/archive/refs/tags/${TAG}.tar.gz"
printf '==> 下载源码归档并计算哈希\n'
TMP="$(/usr/bin/mktemp -t standup-archive)"
curl -fsSL "$ARCHIVE_URL" -o "$TMP"
SHA="$(/usr/bin/python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$TMP")"
rm -f "$TMP"
printf '    sha256=%s\n' "$SHA"

TOKEN="${HOMEBREW_TAP_TOKEN:-$(gh auth token)}"
[[ -n "$TOKEN" ]] || die "拿不到可写 ${TAP_REPO} 的令牌"

WORK="$(/usr/bin/mktemp -d -t standup-tap)"
git clone -q "https://x-access-token:${TOKEN}@github.com/${TAP_REPO}.git" "$WORK/tap"
FORMULA="$WORK/tap/Formula/standup-reminder.rb"
[[ -f "$FORMULA" ]] || die "tap 里没有 Formula/standup-reminder.rb"

/usr/bin/python3 - "$FORMULA" "$VERSION" "$SHA" "$ARCHIVE_URL" <<'PY'
import re, sys
path, version, sha, url = sys.argv[1:]
text = open(path, encoding="utf-8").read()
current = re.search(r'archive/refs/tags/v([0-9][^"/]*)', text)
if current:
    def parts(v):
        return tuple(int(x) for x in re.split(r'[^\d]+', v) if x != "")
    if parts(current.group(1)) > parts(version):
        print(f"跳过配方写入：tap 已是 v{current.group(1)}，高于本次 {version}")
        sys.exit(0)
text = re.sub(r'url "https://github.com/.*/archive/refs/tags/v[^"]+"', f'url "{url}"', text, count=1)
text = re.sub(r'^  sha256 ".*"', f'  sha256 "{sha}"', text, count=1, flags=re.M)
text = re.sub(r'\n  environment_variables REMINDER_INTERVAL: "[^"]+"', "", text, count=1)
open(path, "w", encoding="utf-8").write(text)
print("已写入配方")
PY

cd "$WORK/tap"
if git diff --quiet -- Formula/standup-reminder.rb; then
  printf '==> 配方无变化\n'
else
  git add Formula/standup-reminder.rb
  git commit -m "standup-reminder ${TAG}"
  git push origin HEAD
  printf '==> 已推送 tap 配方\n'
fi

printf '\n核对：\n'
printf '  Release: https://github.com/%s/releases/tag/%s\n' "$SOURCE_REPO" "$TAG"
printf '  Formula: https://github.com/%s/blob/main/Formula/standup-reminder.rb\n' "$TAP_REPO"
printf '  期望版本: %s  sha256: %s\n' "$VERSION" "$SHA"
rm -rf "$WORK"
