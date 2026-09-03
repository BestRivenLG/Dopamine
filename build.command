#!/bin/bash
# ============================================================
#  一键编译 basebin / packages(仓库根运行 —— 主仓库/Downloads 通用)
#
#    [1] 子模块缺失时 自动 git submodule update --init --recursive
#    [2] .deps/theos 缺失时 自动软链到 Downloads 里的 theos
#    [3] bootstrap_*.tar.zst 缺失时 自动从 apt.procurs.us 下载
#    [4] make -C BaseBin / Packages  (BUILD_STANDALONE=0,避开 #if 空值坑)
#
#  编完用 Xcode 打开 Application/Dopamine.xcodeproj,按 ⌘R 装真机。
# ============================================================
set -u

BUILD="$*"                      # 可传参: build.command BaseBin Packages(默认全编)
[ -z "$BUILD" ] && BUILD="BaseBin Packages"
THEOS_SRC="$HOME/Downloads/Dopamine-3.0.9/.deps/theos"   # theos 软链来源

# ---------- 定位仓库根 ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "✗ 不在 git 仓库里: $SCRIPT_DIR"; read -t 10 -n 1 -s -r -p "按任意键关闭"; exit 1
}
cd "$ROOT"
echo "仓库目录: $ROOT"

FAIL=0
warn(){ echo "⚠  $*"; }

# ---------- [1/4] 子模块 ----------
echo ""
echo "── [1/4] 子模块检查 ──"
if git submodule status 2>/dev/null | grep -q '^\-'; then
  echo "→ 有未初始化子模块,开始下载(需外网,可能几分钟)…"
  if GIT_TERMINAL_PROMPT=0 git submodule update --init --recursive; then
    echo "✓ 子模块全部就绪"
  else
    FAIL=$((FAIL+1)); warn "子模块下载失败(检查外网)。之后可重试: git submodule update --init --recursive"
  fi
else
  echo "✓ 子模块已就绪"
fi

# ---------- [2/4] theos ----------
echo ""
echo "── [2/4] theos 检查 ──"
if [ -f ".deps/theos/makefiles/common.mk" ]; then
  echo "✓ .deps/theos 可用"
else
  if [ -d "$THEOS_SRC" ] && [ -f "$THEOS_SRC/makefiles/common.mk" ]; then
    mkdir -p .deps && ln -sfn "$THEOS_SRC" .deps/theos
    echo "✓ 已软链 theos → $THEOS_SRC"
  else
    FAIL=$((FAIL+1)); warn "找不到 theos: .deps/theos 与 $THEOS_SRC 都不存在。请先准备 theos 再重试";
  fi
fi

# ---------- [3/4] bootstrap ----------
echo ""
echo "── [3/4] bootstrap 检查 ──"
RES_DIR="Application/Dopamine/Resources"
NEED=0
for b in bootstrap_1800.tar.zst bootstrap_1900.tar.zst; do
  [ -f "$RES_DIR/$b" ] || { warn "缺 $b"; NEED=1; }
done
if [ "$NEED" = "1" ]; then
  echo "→ 下载 bootstrap(apt.procurs.us,各 ~20MB)…"
  ( cd "$RES_DIR" && ./download_bootstraps.sh ) && echo "✓ bootstrap 就绪" || { FAIL=$((FAIL+1)); warn "bootstrap 下载失败"; }
else
  echo "✓ bootstrap 已就绪"
fi

# ---------- [4/4] make ----------
echo ""
echo "── [4/4] make BUILD_STANDALONE=0 ──"
for m in $BUILD; do
  echo "→ make -C $m …"
  if make -C "$m" BUILD_STANDALONE=0; then
    echo "✓ $m 编译完成"
  else
    FAIL=$((FAIL+1)); warn "$m 编译失败,看上方输出"
  fi
done

# ---------- 汇总 ----------
echo ""
echo "================ 完成 ================"
if [ "$FAIL" -eq 0 ]; then
  echo "✓ 全部成功。用 Xcode 打开:"
  echo "     open $ROOT/Application/Dopamine.xcodeproj"
  echo "  选 Dopamine scheme + 你的 iPhone,⌘R 装真机。"
else
  echo "✗ 有 $FAIL 处失败,见上方 ⚠ 提示"
fi
read -t 15 -n 1 -s -r -p "按任意键关闭窗口…" || true