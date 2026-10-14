#!/usr/bin/env bash
# Publishes a release: bumps pubspec.yaml, commits, tags and pushes the branch
# and tag together; .github/workflows/release.yml then builds the packages.
#
#   ./release.sh [--allow-dirty] [patch|minor|major]   # no kind: choose from a menu
#
# --allow-dirty releases with uncommitted changes in the working tree. They are
# left as they are: only pubspec.yaml is committed, and CI builds the tag.
set -euo pipefail
cd "$(dirname "$0")"

die() {
  echo "release: $*" >&2
  exit 1
}

current=$(sed -nE 's/^version: *([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+) *$/\1/p' pubspec.yaml)
[[ -n ${current} ]] || die "pubspec.yaml 的 version 不是 主.次.修订+构建号 格式"
name=${current%+*}
build=${current#*+}
IFS=. read -r major minor patch <<<"$name"

bump() {
  case $1 in
    patch) echo "$major.$minor.$((patch + 1))" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    major) echo "$((major + 1)).0.0" ;;
    *) return 1 ;;
  esac
}

usage="用法：./release.sh [--allow-dirty] [patch|minor|major]"
allow_dirty=false
kind=
for arg in "$@"; do
  case $arg in
    --allow-dirty) allow_dirty=true ;;
    *) [[ -z $kind ]] || die "$usage"; kind=$arg ;;
  esac
done
if [[ -z $kind ]]; then
  kinds=(patch minor major)
  echo "当前版本 ${name}（构建号 ${build}），选择发布类型："
  for i in "${!kinds[@]}"; do
    printf '  %d) %-5s  %s → %s\n' $((i + 1)) "${kinds[i]}" "$name" "$(bump "${kinds[i]}")"
  done
  read -rp "输入 1-3：" choice
  [[ ${choice} =~ ^[1-3]$ ]] || die "无效选择：${choice}"
  kind=${kinds[choice - 1]}
fi
next=$(bump "${kind}") || die "$usage"
next_build=$((build + 1))
tag="v$next"

if [[ $allow_dirty == true ]]; then
  # The release commit takes pubspec.yaml whole, so its own edits would ride along.
  [[ -z $(git status --porcelain -- pubspec.yaml) ]] || die "pubspec.yaml 有未提交的改动，请先提交或还原"
else
  [[ -z $(git status --porcelain) ]] || die "工作区有未提交的改动，请先提交或暂存（或加 --allow-dirty）"
fi
branch=$(git symbolic-ref --short -q HEAD) || die "当前不在分支上"
git fetch --quiet --tags origin
if git rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
  [[ $(git rev-list --count "HEAD..origin/$branch") == 0 ]] ||
    die "本地 ${branch} 落后于 origin/${branch}，请先同步"
fi
! git rev-parse -q --verify "refs/tags/${tag}" >/dev/null || die "tag ${tag} 已存在"

echo "发布 ${name}+${build} → ${next}+${next_build}（分支 ${branch}，tag ${tag}）"
read -rp "确认发布并推送？[y/N] " ok
[[ ${ok} == [yY] ]] || die "已取消"

sed -i.bak -E "s/^version: .*/version: $next+$next_build/" pubspec.yaml
rm pubspec.yaml.bak
git commit --quiet -m "chore(release): $tag" -- pubspec.yaml
git tag -a "$tag" -m "$tag"
if ! git push --atomic origin "HEAD:refs/heads/$branch" "refs/tags/$tag"; then
  die "推送失败，本地提交和 tag 已保留。重试：git push --atomic origin HEAD:refs/heads/${branch} refs/tags/${tag}；撤销：git tag -d ${tag} && git reset --keep HEAD~1"
fi

slug=$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
echo "已发布 ${tag}。构建进度：https://github.com/${slug}/actions"
