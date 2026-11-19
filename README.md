# Athena AX6600（京东云 RE-CS-02）云编译

GitHub Actions 云编译，出带四个插件的 ImmortalWrt 固件：

| 插件 | 包名 |
|---|---|
| [NaiLink](https://github.com/slobys/NaiLink) | `daed-router` + `luci-app-daed-router` |
| [clashoo](https://github.com/kenzok8/openwrt-clashoo) | `clashoo` + `luci-app-clashoo` |
| [luci-theme-vantage](https://github.com/anothaDev/luci-theme-vantage) | `luci-theme-vantage` + `luci-app-vantage` |
| [OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki) | `nikki` + `luci-app-nikki` |

- 目标：`qualcommax` / `ipq60xx` / `DEVICE_jdcloud_re-cs-02`（IPQ6010，aarch64_cortex-a53）
- 源码：`immortalwrt/immortalwrt`（主线 OpenWrt 的 ipq60xx.mk 没有 RE-CS-02，ImmortalWrt 有）
- 内核：开启 `DEBUG_INFO_BTF` + BPF_JIT + CGROUP_BPF，dae 才能跑

## 目录

```
.github/workflows/build.yml   # 云编译流程
Config/AX6600.config          # 完整 .config
Scripts/packages.sh           # 接 feed + 搬四个插件 + 交叉编译 daed + 应用配置
```

## 部署（本机 git 命令）

```bash
cd athena-cloudbuild
git init -b main
git add -A
git commit -m "feat: 雅典娜 RE-CS-02 云编译 + NaiLink/clashoo/vantage/nikki"
gh repo create athena-openwrt --public --source=. --push
gh workflow run build.yml
gh run watch
```

没有 gh 就用网页：新建 public 仓库 → 网页拖拽上传本目录全部文件（`.github` 别漏）→ Actions 页 → `Build Athena AX6600 (RE-CS-02)` → Run workflow。

## 触发方式

| 方式 | 说明 |
|---|---|
| 手动 Run workflow | 选分支 `master` / `openwrt-24.10`，选是否编 daed |
| push tag `v1` | 自动编译并发布 Release |
| 每周六 02:00（北京时间） | 定时编译 |

## 产物

`Actions → 本次运行 → Artifacts`：

- `athena-re-cs-02-YYYY-MM-DD`：sysupgrade 固件 + manifest + sha256sums
- `packages-aarch64_cortex-a53.tar.gz`：附编译出的 ipk/apk

## 刷机

U-Boot Web 页刷 sysupgrade.bin（eMMC 版用 `chenxin527/uboot-ipq60xx-emmc-build`，NOR 版用 `-nor-build`），起机后 `sysupgrade -n` 升级。

## 已知取舍

- 免费公开仓库 Actions 不限分钟；私有仓库 2000 分钟/月，全量一次约 90–130 分钟。
- daed 交叉编译失败时脚本会自动把它从 `.config` 摘掉继续编，刷机后再装发布页 ipk。
- Nikki / clashoo / daed 三者都能接管透明代理，运行时只启用一个。
