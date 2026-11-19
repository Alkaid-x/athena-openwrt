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
# ---------------------------------------------------------------- 1. feeds
echo "===> [1/6] 接入 feeds：nikki"
grep -q '^src-git nikki ' feeds.conf.default 2>/dev/null || \
  echo "src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main" >> feeds.conf.default
cat feeds.conf.default

# 逐个源更新：单个源挂了只剔除它自己，绝不拖死整次构建
while IFS= read -r line; do
  case "$line" in
    src-git*|src-link*)
      read -r _kind _name _rest <<<"$line"
      if ! ./scripts/feeds update "$_name"; then
        echo "WARN: feed '$_name' 更新失败，剔除该源"
        sed -i "/^src-[a-z]*[[:space:]]*$_name[[:space:]]/d" feeds.conf.default
      fi ;;
  esac
done < <(grep -E '^src-(git|link)' feeds.conf.default)

# 目录仍然缺失的源一律剔掉，避免 index 阶段 `find: feeds/xxx` 报错中断
while IFS= read -r line; do
  case "$line" in
    src-git*|src-link*)
      read -r _kind _name _rest <<<"$line"
      if [ ! -d "feeds/$_name" ]; then
        echo "WARN: feeds/$_name 不存在，剔除该源"
        sed -i "/^src-[a-z]*[[:space:]]*$_name[[:space:]]/d" feeds.conf.default
      fi ;;
  esac
done < <(grep -E '^src-(git|link)' feeds.conf.default)
echo "--- feeds.conf.default 最终内容 ---"; cat feeds.conf.default

./scripts/feeds update -a || true
./scripts/feeds install -a || true

# nikki 的三个包必须在 package/ 下可见；install 失败就手工软链
for p in nikki luci-app-nikki luci-i18n-nikki-zh-cn; do
  if [ ! -e "package/feeds/nikki/$p" ] && [ -e "feeds/nikki/$p" ]; then
    mkdir -p package/feeds/nikki
    ln -sfn "../../../feeds/nikki/$p" "package/feeds/nikki/$p"
    echo "FIX: 手工链接 $p"
  fi
done

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

if [ "$WITH_DAED" != "false" ]; then
  echo "===> [3/6] 取 NaiLink 预编译二进制（官方 release ipk，免 Go 编译）"
  DAED_IPK_URL="https://github.com/slobys/NaiLink/releases/download/openwrt-v0.6.90/daed-router-0.6.90-aarch64_cortex-a53.ipk"
  mkdir -p "$BIN" "$WORK/ipk"
  rm -f "$BIN/daed" "$BIN/btf-probe"
  if curl -fL --retry 3 -o "$WORK/daed.ipk" "$DAED_IPK_URL" || wget -q -O "$WORK/daed.ipk" "$DAED_IPK_URL"; then
    echo "   ipk: $(stat -c%s "$WORK/daed.ipk" 2>/dev/null || echo 0)B"
    ( cd "$WORK/ipk" && ar x "$WORK/daed.ipk" && \
      ( tar xzf data.tar.gz 2>/dev/null || tar --zstd -xf data.tar.zst 2>/dev/null || tar xf data.tar.* 2>/dev/null ) )
    for pair in "usr/bin/daed:daed" "usr/libexec/daed/btf-probe:btf-probe" "usr/libexec/daed/luci-proxy:luci-proxy"; do
      src="$WORK/ipk/${pair%%:*}"; dst="$BIN/${pair##*:}"
      if [ -e "$src" ]; then
        cp -r "$src" "$dst"
        echo "   <- ${pair%%:*} -> ${pair##*:}"
      fi
    done
  else
    echo "   !! 预编译包下载失败"
  fi

  # 兜底：源码树在、有 go，就自己编一次
  if [ ! -s "$BIN/daed" ] && command -v go >/dev/null 2>&1 && [ -d "$WORK/NaiLink" ]; then
    for p in ./wing/cmd/daed ./cmd/daed ./wing ./cmd; do
      [ -e "$WORK/NaiLink/$p" ] || continue
      ( cd "$WORK/NaiLink" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
          go build -trimpath -ldflags "-s -w" -o "$BIN/daed" "$p" 2>"$BIN/daed.build.log" )
      if [ -s "$BIN/daed" ]; then echo "   go build 兜底成功 <- $p"; break; fi
      rm -f "$BIN/daed"
    done
  fi

  [ -s "$BIN/daed" ] && DAED_OK=1
  echo "--- daed=$DAED_OK  daed=$(stat -c%s "$BIN/daed" 2>/dev/null || echo 0)B  probe=$(stat -c%s "$BIN/btf-probe" 2>/dev/null || echo 0)B  luci-proxy=$(stat -c%s "$BIN/luci-proxy" 2>/dev/null || echo 0)B"
else
  echo "===> [3/6] 跳过 daed（WITH_DAED=$WITH_DAED）"
fi

# BTF：RE-CS-02 的 kernel 分区被 ipq60xx.mk 写死 6144k，开 BTF 后 FIT 内核 7677924B 超限
if [ "$WITH_BTF" = "true" ]; then
  echo "=== with_btf=true：打开 BTF，并把 KERNEL_SIZE 6144k -> 8192k（daed 内核需要）"
  sed -i 's/^CONFIG_KERNEL_DEBUG_INFO=n/CONFIG_KERNEL_DEBUG_INFO=y/; s/^CONFIG_KERNEL_DEBUG_INFO_BTF=n/CONFIG_KERNEL_DEBUG_INFO_BTF=y/' "$CFG"
  sed -i '/define Device\/jdcloud_re-cs-02/,/endef/ s/KERNEL_SIZE := 6144k/KERNEL_SIZE := 8192k/' \
    target/linux/qualcommax/image/ipq60xx.mk
else
  echo "=== with_btf=false：内核守住 6144k 上限，daed 内核不可用（NaiLink 仍可用 sing-box / mihomo 内核）"
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
[ "$WITH_BTF" = "true" ] && check CONFIG_KERNEL_DEBUG_INFO_BTF
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
