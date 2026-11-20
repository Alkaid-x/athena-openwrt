#!/usr/bin/env bash
# 把 ipq60xx 内核压进 RE-CS-02 的 6144k FIT 槽位
#
# 背景：target/linux/qualcommax/image/ipq60xx.mk 的 jdcloud_re-cs-02 用
#   $(call Device/FitImage) + KERNEL_SIZE := 6144k
# 内核 FIT 超过 6291456 字节时，BuildImage 会打印
#   WARNING: Image file ...-uImage.itb is too big: NNNN > 6291456
# 并丢掉内核，最终报 target/linux failed to build。
#
# 两个关键坑：
#   1. OpenWrt 的 config 合并只认 CONFIG_X=y / CONFIG_X=m 这种正向赋值，
#      "# CONFIG_X is not set" 会被直接丢掉，所以想关掉某项必须改 Kconfig 源行为，
#      或者干脆把它变成模块（=m）——本脚本走 =m 路线。
#   2. bool 型符号（如 RTC_CLASS）不能写 =m，否则 syncconfig 会报
#      warning: symbol value 'm' invalid 并弹交互提示，构建直接失败。
set -euo pipefail

CFG="target/linux/qualcommax/config-6.18"
[ -f "$CFG" ] || { echo "找不到 $CFG，内核版本可能变了，请检查 target/linux/qualcommax/"; exit 1; }

grep -q 'CONFIG_HWMON=m' "$CFG" && { echo "内核裁剪已存在，跳过"; exit 0; }

cat >> "$CFG" <<'EOF'

# ---- RE-CS-02 6144k FIT 槽位：把体积大的 built-in 降级为模块 ----
# 这些子系统运行时按需加载，放模块不影响开机与无线
CONFIG_SCSI=m
CONFIG_ATA=m
CONFIG_BLK_DEV_LOOP=m
CONFIG_NETFILTER_XTABLES=m
CONFIG_CRYPTO_USER=m
CONFIG_HWMON=m
CONFIG_PPS=m
CONFIG_PTP_1588_CLOCK=m
# -Os 换 -O2：内核体积可省 1% 左右
# CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE is not set
CONFIG_CC_OPTIMIZE_FOR_SIZE=y
EOF

echo "已写入内核裁剪：$CFG"
grep -c '=m$' "$CFG" | xargs -I{} echo "config 里现有 {} 个 =m 项"
