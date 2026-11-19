#!/usr/bin/env bash
# 在 openwrt/ 同级目录运行：接入 feeds + 四个插件 + 应用 .config
# 由 .github/workflows/build.yml 的 step 7 调用
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/openwrt"
CFG="$ROOT/Config/AX6600.config"
WORK="$ROOT/.work"
BRANCH="${BRANCH:-master}"
WITH_DAED="${WITH_DAED:-}"

echo "===> branch=$BRANCH  with_daed='${WITH_DAED}'  root=$ROOT"
cd "$SRC"

# ---------------------------------------------------------------- 1. feeds
echo "===> [1/6] 接入 feeds：nikki + kenzok8 兜底包源"
grep -q '^src-git nikki ' feeds.conf.default 2>/dev/null || \
  echo "src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main" >> feeds.conf.default
grep -q '^src-git kenzok8 ' feeds.conf.default 2>/dev/null || \
  echo "src-git kenzok8 https://github.com/kenzok8/openwrt-packages.git;main" >> feeds.conf.default
cat feeds.conf.default

./scripts/feeds update -a
./scripts/feeds install -a

# ---------------------------------------------------------------- 2. 四个包
echo "===> [2/6] 拉取四个插件仓库"
rm -rf "$WORK"; mkdir -p "$WORK"

git clone --depth=1 https://github.com/kenzok8/openwrt-clashoo.git       "$WORK/clashoo"
git clone --depth=1 https://github.com/anothaDev/luci-theme-vantage.git  "$WORK/vantage"
git clone --depth=1 --recurse-submodules --shallow-submodules \
  https://github.com/slobys/NaiLink.git                                  "$WORK/NaiLink"

# clashoo：仓库根就是包目录
rm -rf package/openwrt-clashoo
cp -r "$WORK/clashoo" package/openwrt-clashoo

# vantage：包在两个子目录里，只搬这两个
rm -rf package/luci-theme-vantage package/luci-app-vantage
cp -r "$WORK/vantage/luci-theme-vantage" package/
cp -r "$WORK/vantage/luci-app-vantage"  package/

# NaiLink：包目录在 openwrt/
rm -rf package/nailink; mkdir -p package/nailink
cp -r "$WORK/NaiLink/openwrt/." package/nailink/
echo "--- 已就位："
ls -d package/openwrt-clashoo package/luci-theme-vantage package/luci-app-vantage package/nailink

# ---------------------------------------------------------------- 3. daed 二进制
BIN="$ROOT/nailink-bin"; mkdir -p "$BIN"
DAED_OK=0

if [ "$WITH_DAED" != "false" ] && command -v go >/dev/null 2>&1; then
  echo "===> [3/6] 交叉编译 NaiLink daed（linux/arm64）"
  pushd "$WORK/NaiLink" >/dev/null

  # 主程序
  DAED_BUILT=0
  for p in ./cmd/daed ./cmd/daed-router .; do
    if [ -e "$p" ] && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
        go build -trimpath -ldflags "-s -w" -o "$BIN/daed" "$p" 2>"$BIN/daed.build.log"; then
      echo "   daed  <- $p"; DAED_BUILT=1; break
    fi
  done

  # btf-probe
  PROBE_BUILT=0
  for p in ./cmd/btf-probe ./cmd/btfprobe ./tools/btf-probe; do
    if [ -e "$p" ] && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
        go build -trimpath -ldflags "-s -w" -o "$BIN/btf-probe" "$p" 2>/dev/null; then
      PROBE_BUILT=1; break
    fi
  done
  if [ "$PROBE_BUILT" = 0 ] && [ -f ./scripts/btf-probe.py ]; then
    cp ./scripts/btf-probe.py "$BIN/btf-probe"; PROBE_BUILT=1
  fi

  # luci-proxy（前端产物或编译产物）
  LUCIPROXY=""
  for c in ./luci-proxy/dist/luci-proxy ./luci-proxy/build/luci-proxy \
           ./luci-proxy/luci-proxy ./dist/luci-proxy ./luci-proxy.tar.gz \
           ./luci-proxy/luci-proxy.tar.gz ./luci-proxy.zip; do
    [ -e "$c" ] && { LUCIPROXY="$c"; break; }
  done
  if [ -z "$LUCIPROXY" ] && [ -f ./luci-proxy/package.json ]; then
    ( cd ./luci-proxy && (npm ci --silent || npm install --silent) && npm run build --silent ) \
      && LUCIPROXY="./luci-proxy/dist/luci-proxy"
  fi
  [ -n "$LUCIPROXY" ] && [ -e "$LUCIPROXY" ] && cp -r "$LUCIPROXY" "$BIN/luci-proxy"

  popd >/dev/null

  [ -s "$BIN/daed" ] && DAED_OK=1
  echo "--- daed=$DAED_OK  daed=$(stat -c%s "$BIN/daed" 2>/dev/null || echo 0)B  probe=$(stat -c%s "$BIN/btf-probe" 2>/dev/null || echo 0)B"
  [ -s "$BIN/luci-proxy" ] || [ -d "$BIN/luci-proxy" ] || echo "   !! luci-proxy 未找到，LuCI 代理页可能不可用"
else
  echo "===> [3/6] 跳过 daed 编译（WITH_DAED=$WITH_DAED, go=$(command -v go || echo none)）"
fi

# ---------------------------------------------------------------- 4. .config
echo "===> [4/6] 应用 .config"
cp "$CFG" .config

if [ "$DAED_OK" = 1 ]; then
  export DAED_VERSION="0.6.90"
  export DAED_BINARY="$BIN/daed"
  export DAED_BTF_PROBE="$BIN/btf-probe"
  export DAED_LUCI_PROXY="$BIN/luci-proxy"
  {
    echo "export DAED_VERSION='0.6.90'"
    echo "export DAED_BINARY='$BIN/daed'"
    echo "export DAED_BTF_PROBE='$BIN/btf-probe'"
    echo "export DAED_LUCI_PROXY='$BIN/luci-proxy'"
  } >> "$GITHUB_ENV" 2>/dev/null || true
else
  echo "--- daed 二进制缺失，从 .config 移除 daed 两项（刷机后可装 ipk）"
  sed -i '/CONFIG_PACKAGE_daed-router/d; /CONFIG_PACKAGE_luci-app-daed-router/d' .config
fi

make defconfig

# ---------------------------------------------------------------- 5. 自检
echo "===> [5/6] 配置自检"
FAIL=0
check() {
  if grep -q "^$1=y" .config; then
    echo "   OK   $1"
  else
    echo "   MISS $1"
    FAIL=1
  fi
}
check CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02
check CONFIG_PACKAGE_clashoo
check CONFIG_PACKAGE_luci-app-clashoo
check CONFIG_PACKAGE_luci-theme-vantage
check CONFIG_PACKAGE_luci-app-vantage
check CONFIG_PACKAGE_nikki
check CONFIG_PACKAGE_luci-app-nikki
check CONFIG_KERNEL_DEBUG_INFO_BTF
check CONFIG_PACKAGE_kmod-sched-bpf
[ "$DAED_OK" = 1 ] && check CONFIG_PACKAGE_daed-router

echo "--- 关键项："
grep -E '^CONFIG_(TARGET_qualcommax|KERNEL_DEBUG_INFO_BTF|PACKAGE_(daed-router|clashoo|nikki|luci-theme-vantage|luci-app-nikki))' .config || true

# ---------------------------------------------------------------- 6. 源码树核对
echo "===> [6/6] 设备支持核对"
if grep -rq "re-cs-02" target/linux/qualcommax/ ; then
  echo "   OK   target/linux/qualcommax 内找到 re-cs-02"
else
  echo "   !! 该分支没有 RE-CS-02 设备定义 —— 换 master 分支或改用 ones20250/immortalwrt_ipq" >&2
  exit 1
fi

if [ "$FAIL" = 1 ]; then
  echo "!! 有个别配置项被 defconfig 丢弃，检查包名是否随上游改名" >&2
fi

echo "===> 准备完毕"
