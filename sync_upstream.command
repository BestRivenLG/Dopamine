#!/bin/bash
# ============================================================
#  一键同步作者代码(opa334/Dopamine)
#
#  对每个分支(镜像 3.x 是你自己的提交; 3.x_mine 是你的工作分支):
#    1. git fetch upstream --prune --tags   拉作者所有分支 + tag 到本地
#    2. 把作者所有分支推到你 fork(origin)
#    3. 把作者所有 tag 推到 fork
#    4. 本地 3.x 快进到作者最新(不在 3.x 上直接提交)
#    5. 把最新 3.x 合并进 3.x_mine(有冲突则中止,提示你手动处理)
#
#  双击即可运行;失败会指出,不会覆盖你自己在 fork 上的提交。
# ============================================================
set -u

# ---------- 可配置项 ----------
UPSTREAM="upstream"        # 作者仓库 remote(已配好)
ORIGIN="origin"            # 你自己的 fork
MIRRORBR="3.x"             # 本地镜像分支(只拉取,不直接提交)
WORKBR="3.x_mine"          # 你的工作分支(存在才合并最新 3.x;不需要就留空 WORKBR="")

# ---------- 定位 git 仓库(支持 .command 放在仓库任意位置) ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "✗ 找不到 git 仓库: $SCRIPT_DIR 不在仓库内"; read -t 10 -n 1 -s -r -p "按任意键关闭"; exit 1
}
cd "$REPO_ROOT"
echo "仓库目录: $REPO_ROOT"

if ! git remote get-url "$UPSTREAM" >/dev/null 2>&1; then
  echo "✗ 没有 $UPSTREAM 远程仓库,先执行:"
  echo "    git remote add $UPSTREAM git@github.com:opa334/Dopamine.git"
  read -t 10 -n 1 -s -r -p "按任意键关闭"; exit 1
fi

# 处于未完成的 merge/rebase 时不做任何事
if [ -d "$REPO_ROOT/.git/rebase-merge" ] || [ -d "$REPO_ROOT/.git/rebase-apply" ] || [ -f "$REPO_ROOT/.git/MERGE_HEAD" ]; then
  echo "✗ 检测到未完成的 merge/rebase,先处理完(git status 查看)再运行"
  read -t 10 -n 1 -s -r -p "按任意键关闭"; exit 1
fi

FAIL=0

# ---------- 1. 拉取作者所有分支 + tag ----------
echo ""
echo "── [1/4] git fetch $UPSTREAM --prune --tags ──"
git fetch --prune --tags "$UPSTREAM" || { echo "✗ 拉取失败(网络?)"; read -t 10 -n 1 -s -r -p "按任意键关闭"; exit 1; }

# ---------- 2. 推送所有分支到 fork ----------
echo ""
echo "── [2/4] 同步所有分支到 fork($ORIGIN) ──"
if ! git push "$ORIGIN" "refs/remotes/$UPSTREAM/*:refs/heads/*"; then
  FAIL=$((FAIL+1))
  echo "⚠ 有分支推送失败:一般是该分支在 fork 上有你自己的提交(属正常),不会覆盖"
fi

# ---------- 3. 推送所有 tag 到 fork ----------
echo ""
echo "── [3/4] 同步所有 tag 到 fork($ORIGIN) ──"
if ! git push "$ORIGIN" --tags; then
  FAIL=$((FAIL+1))
  echo "⚠ tag 推送有失败:一般是作者改过同名 tag(属正常),不会覆盖"
fi

# ---------- 4. 本地更新 ----------
echo ""
echo "── [4/4] 本地更新 ──"
CURRENT_BR="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo "")"

# 4.1 镜像分支 3.x 快进到作者最新(安全:只允许快进,绝不强推)
if git show-ref --verify --quiet "refs/heads/$MIRRORBR"; then
  if git merge-base --is-ancestor "$MIRRORBR" "refs/remotes/$UPSTREAM/$MIRRORBR" 2>/dev/null; then
    if [ "$CURRENT_BR" = "$MIRRORBR" ]; then
      if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
        echo "⚠ 当前在 $MIRRORBR 且有未提交改动,先提交/暂存再运行(本次跳过本地快进)"
      else
        git merge --ff-only "refs/remotes/$UPSTREAM/$MIRRORBR" && echo "✓ 本地 $MIRRORBR 已快进到作者最新"
      fi
    else
      # 不在本分支上,直接移动指针(不影响工作区)
      git branch -f "$MIRRORBR" "refs/remotes/$UPSTREAM/$MIRRORBR" && echo "✓ 本地 $MIRRORBR 已对齐作者最新"
    fi
  else
    echo "⚠ $MIRRORBR 上有你自己的提交,不强行对齐;$MIRRORBR 保持现状"
  fi
fi

# 4.2 工作分支合并最新 3.x(有冲突则中止,不动你的数据)
if [ -n "$WORKBR" ] && git show-ref --verify --quiet "refs/heads/$WORKBR"; then
  if git merge-base --is-ancestor "$WORKBR" "$MIRRORBR"; then
    echo "✓ $WORKBR 已包含最新 $MIRRORBR,无需合并"
  else
    echo "→ 把最新 $MIRRORBR 合并进 $WORKBR ..."
    if git checkout "$WORKBR" >/dev/null 2>&1 && git merge "$MIRRORBR" --no-edit; then
      echo "✓ $WORKBR 已合并最新 3.x"
    else
      echo "✗ $WORKBR 合并有冲突或存在未提交改动,已中止并恢复原状。请手动:"
      echo "    git checkout $WORKBR"
      echo "    git merge $MIRRORBR"
      git merge --abort >/dev/null 2>&1
      FAIL=$((FAIL+1))
    fi
  fi
fi

# 切回运行前的分支
if [ -n "$CURRENT_BR" ] && [ "$(git symbolic-ref --short -q HEAD 2>/dev/null || echo "")" != "$CURRENT_BR" ]; then
  git checkout "$CURRENT_BR" >/dev/null 2>&1 || echo "⚠ 无法切回 $CURRENT_BR,请手动 git checkout $CURRENT_BR"
fi

# ---------- 汇总 ----------
echo ""
echo "================ 完成 ================"
if [ "$FAIL" -eq 0 ]; then
  echo "全部成功 ✓"
else
  echo "有 $FAIL 处警告/失败,详见上方 ⚠ ✗ 提示"
fi
echo "当前分支: $(git branch --show-current 2>/dev/null)"
read -t 10 -n 1 -s -r -p "按任意键关闭窗口..." || true