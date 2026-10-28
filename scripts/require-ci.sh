#!/bin/zsh
# 发版前核对：要发的提交在 GitHub Actions 的 build（.github/workflows/build.yml）上跑完并通过了。
# 用法：scripts/require-ci.sh [提交，默认 HEAD]。通过退出码 0；没推、还在跑、没过退出码 1，并说下一步怎么做。
# 仓库还是私有的时候 CI 不跑（macOS runner 按 10 倍扣私有仓库的免费额度）：只提示一句，不拦。
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=SchaeferAnjon/GetNewWord
SHA=$(git rev-parse "${1:-HEAD}^{commit}")
SHORT=${SHA:0:7}
# 联网的命令给个时限（macOS 没有 timeout 命令）
limit() { perl -e 'alarm shift; exec @ARGV or die "$ARGV[0]: $!\n"' "$@" }

VISIBILITY=$(limit 60 gh repo view "$REPO" --json visibility -q .visibility) \
  || { print -u2 "查不了 $REPO（gh auth status 看看登录了没有）"; exit 1 }
if [[ $VISIBILITY != PUBLIC ]]; then
  print "!! $REPO 现在是私有的，CI 没开：没核对 $SHORT 的 CI。仓库公开后这一步会要求 CI 通过"
  exit 0
fi

# 同一个提交可能有几次运行（推到 main、打 tag、手动重跑），新的在前：有一次通过就行
RUNS=$(limit 60 gh run list --repo "$REPO" --workflow build.yml --commit "$SHA" --limit 20 \
  --json databaseId,status,conclusion -q '.[] | "\(.databaseId) \(.status) \(.conclusion)"') \
  || { print -u2 "查不了 $SHORT 的 CI 记录"; exit 1 }
[[ -n $RUNS ]] || { print -u2 "$SHORT 在 GitHub 上还没有 CI 记录：先推上去（git push），等 build 跑完"; exit 1 }

running="" failed=""
while read -r id run_status conclusion; do
  if [[ $conclusion == success ]]; then
    print "CI 已通过：$SHORT（gh run view $id --repo $REPO）"
    exit 0
  fi
  [[ $run_status == completed ]] || running=${running:-$id}
  [[ $run_status == completed ]] && failed=${failed:-"$id $conclusion"}
done <<< "$RUNS"

[[ -z $running ]] || { print -u2 "$SHORT 的 CI 还在跑：gh run watch $running --repo $REPO，跑完再发"; exit 1 }
print -u2 "$SHORT 的 CI 没过（${failed#* }）：gh run view ${failed%% *} --repo $REPO --log-failed"
exit 1
