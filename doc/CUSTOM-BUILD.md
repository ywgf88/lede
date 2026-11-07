# LEDE (coolsnowwolf/lede) 定制构建说明 — MT7981 三设备版

本文件是「学习源码 → 定制 → 编译」的完整记录与操作手册。所有结论均来自对
`master` 分支真实源码的检索，不是凭印象写的教程。

分析基准：`55897b73604c219c7518e14a25c51d017d5defba`（2026-11-07 01:29 +0800，
`aic8800: terminate the PCI device ID table`）。

## 0. 本次已确认的构建参数

| 项 | 取值 |
|---|---|
| 设备 profile | `cetron_ct3003`（原厂 U-Boot）、`cmcc_rax3000m-nand`（**NAND 版**）、`qihoo_360t7` |
| 插件 | `luci-app-ssr-plus`、`luci-app-passwall2`、`luci-theme-vantage` |
| 默认网络 | 纯 IPv4：保留内核 IPv6 栈，删除 WAN6/ULA/ip6assign，关 RA/DHCPv6/NDP，LAN `192.168.1.1/24` |
| 体积上限 | 58 MiB（编译后硬校验） |
| 编译位置 | GitHub Actions Ubuntu 24.04 runner（本机 Windows/WSL 不可用） |

---

## 1. 这个项目是什么

Lean 的 LEDE 是 OpenWrt 的下游发行版源码树：保留 OpenWrt 构建系统，替换/新增了
LuCI 应用、主题、中文默认设置和大量国产设备支持。它**不是**可以直接 clone 后
`make` 就出固件的「配置仓库」——必须先 `feeds update/install`，再用 `.config`
选择 target/profile/软件包。

### 版本矩阵（从源码读出）

| 项目 | 值 | 出处 |
|---|---|---|
| 版本号 | 24.10.5（可被 `.config` 覆盖） | `include/version.mk` |
| LuCI feed 分支 | `openwrt-25.12` | `feeds.conf.default` |
| mediatek 内核 | `KERNEL_PATCHVER := 6.18`，测试版 6.12 | `target/linux/mediatek/Makefile` |
| 架构 / 子目标 | `arm` / `mediatek/filogic` | 同上 |
| squashfs 压缩 | xz（`-Xpreset 9 -Xe -Xbcj arm`），默认已开 | `include/image.mk` + `target/linux/generic/config-6.18` |
| 默认登录 | `192.168.1.1`，密码 `password` | `README.md` |
| 默认包集合 | `DEFAULT_PACKAGES.router`（很长一串） | `include/target.mk:55-62` |

> 注意：版本号是 24.10.5 但 LuCI feed 用的是 25.12 分支，属于上游混合状态。
> 这正是 Vantage 主题（支持 24.10/25.12）能接进来的原因，也是编译期最容易
> 出现依赖漂移的地方。

### feeds 组成（`feeds.conf.default`）

`packages` / `luci` / `routing` / `telephony`（均为 coolsnowwolf 镜像）+ **`helloworld`
（fw876/helloworld）**。`luci-app-ssr-plus` 就来自 helloworld，**源码树本身不含该包**
（`package/lean/` 下没有 ssr 目录，已核实）。

---

## 2. 三台设备：源码里已经原生支持

全部是 MT7981B + 128 MB SPI-NAND / 256 MB RAM 的同代方案，都在
`target/linux/mediatek/image/filogic.mk` 里注册，无需打补丁。

| 用户说法 | profile | 源码位置 | 关键参数 |
|---|---|---|---|
| CT3003 | `cetron_ct3003` | `filogic.mk:346` | Cetron CT3003，`mt7981b-cetron-ct3003.dts`，`factory.bin` 用 `cetron-header rd30 CT3003` 加头 |
| RAX3000M | `cmcc_rax3000m-nand` | `filogic.mk:419` | `IMAGE_SIZE := 116736k`，`KERNEL_IN_UBI := 1` |
| 360T7 | `qihoo_360t7` | `filogic.mk:972` | `mt7981b-qihoo-360t7.dts`，UBI |

还有两个**可选**变体，按需在 `DEVICES` 里加：

- `cetron_ct3003-mod` — 改过 U-Boot 的 CT3003（`filogic.mk:363`）
- `cmcc_rax3000m-emmc` — **eMMC 版** RAX3000M（`filogic.mk:406`），刷错版本会变砖

网口默认值在 `target/linux/mediatek/filogic/base-files/etc/board.d/02_network`：
CT3003 / 360T7 是 `lan1 lan2 lan3` + `wan`；RAX3000M 是 `lan1 lan2 lan3` + `eth1`。

---

## 3. 五项需求怎么落地

### 3.1 ssr-plus

来自已有的 `helloworld` feed，无需新增源。`include/target.mk` 的
`DEFAULT_PACKAGES.router` 本来就默认带它。但它的 Makefile 里有一大堆
`INCLUDE_*` 开关（MosDNS / Hysteria / Tuic / NaiveProxy / Kcptun / Shadow-TLS…），
默认 `aarch64` 会选 Xray + shadowsocks-rust + MosDNS + DNS2socks + simple-obfs，
体积很大。`configs/mt7981.seed` 里逐个关掉了非必要项，只留
**Xray + shadowsocks-rust client + nftables 透明代理**。

### 3.2 passwall2

**踩坑点**：网上教程里写的 `xiaorouji/openwrt-passwall2` 已经 404（实测
GitHub 页面与 raw README 均返回 404）。当前有效上游是
`Openwrt-Passwall/openwrt-passwall2`（分支 `main`）。它还需要配套
`xiaorouji/openwrt-passwall-packages`（分支 `main`）提供 xray-core / sing-box /
geoview / v2ray-geoip 等内核组件。

passwall2 的 `Basic_Core` 默认在 aarch64 上选 **All = xray-core + sing-box**，
两个 Go 二进制加起来轻松吃掉 20 MB+。seed 里强制成 `Basic_Core_Xray`，
让两个插件**共用一个 xray-core**，这是满足 58 MB 的关键。

两个 feed 都带 `xray-core` / `chinadns-ng`，`prepare.sh` 用
`feeds install -f -p passwall_packages` 固定成同一来源，避免同名包版本打架。

### 3.3 Vantage 主题

`anothaDev/luci-theme-vantage` 是一个**标准 OpenWrt package feed**（根目录有
`luci-theme-vantage/Makefile`、`luci-app-vantage/Makefile`），官方支持
OpenWrt 25.12 与 24.10（24.10 是 opkg/.ipk，25.12 是 apk）。接入方式：

```sh
echo 'src-git vantage https://github.com/anothaDev/luci-theme-vantage.git;main' >> feeds.conf
./scripts/feeds install luci-theme-vantage luci-app-vantage
```

- 用户要的是「主题」→ 只编 `luci-theme-vantage`；
  `luci-app-vantage`（实时仪表盘，约 730 KB）默认**不编**，省空间。
  想要仪表盘就在 seed 里把 `CONFIG_PACKAGE_luci-app-vantage=y` 打开。
- 主题自带 `/etc/uci-defaults/30_luci-theme-vantage`，但 Lean 的
  `99-default-settings` 会晚于它执行，所以补了一个 `zzzz-vantage-theme`
  兜底设置 `luci.main.mediaurlbase=/luci-static/vantage` 并清 LuCI 缓存。

### 3.4 默认网口 IPv4 — 本方案采用的解释

源码里 `CONFIG_IPV6` 是 `def_bool y`（`config/Config-build.in:188`），**没有 prompt，
不能从 `.config` 关掉**；强行改内核 config 会让两个代理插件的依赖链断裂。
因此本方案理解为：**默认网络配置只跑 IPv4**，而不是把 IPv6 栈从内核里挖掉：

- 从 `DEFAULT_PACKAGES.router` 移除 `odhcp6c / odhcpd-ipv6only / ip6tables /
  libip6tc / kmod-ipt-nat6 / luci-proto-ipv6`，也不装 `ipv6helper`；
- 首次启动脚本 `zzzz-ipv4-only`：删除 `wan6`、ULA 前缀、LAN 的 `ip6assign`，
  固定 LAN `192.168.1.1/24`，WAN 纯 DHCPv4 + `option ipv6 0`，关闭
  RA/DHCPv6/NDP，给 dnsmasq 加 `filter_aaaa=1`，禁用 odhcpd。

> 如果你的意思是「内核完全不带 IPv6」，需要额外改 `config/Config-build.in`
> 的 `def_bool y` 和 `target/linux/generic/config-6.18`，并重新梳理
> `ip6tables-mod-nat` 等被 passwall2 选择的依赖——这会明显增加编译失败概率，
> 不建议和 58 MB 限制一起做。

### 3.5 固件 ≤ 58 MiB

**这是全部需求里最紧的约束。** 源码默认给 mediatek 的
`CONFIG_TARGET_ROOTFS_PARTSIZE` 是 **448 MiB**（`config/Config-images.in:335`），
那是给 eMMC/GPT 用的，不是实际镜像大小；NAND 版 RAX3000M 另有硬编码
`IMAGE_SIZE := 116736k`（114 MB）`check-size`。也就是说**上游默认根本不会
替你守住 58 MB**，必须自己加检查。

本方案的三层控制：

1. `prepare.sh` 把 `DEFAULT_PACKAGES.router` 从 ~30 个包砍成 ~15 个
   （去掉 upnp / vsftpd / vlmcsd / accesscontrol / nlbwmon / turboacc /
   autoreboot / arpbind / filetransfer / ddns / wol / coremark / htop /
   kmod-sched-* / kmod-veth / IPv6 全家桶）。
2. seed 里 `TARGET_SQUASHFS_BLOCK_SIZE=1024`（比默认 256 压缩率更高）、
   `USE_SSTRIP` + `STRIP_KERNEL_EXPORTS`、关闭 initramfs/targz/ext4/gzip 镜像，
   两个代理插件共用 xray-core、关掉 sing-box 与所有可选 INCLUDE_*。
3. `scripts/check-size.sh` 在编译后**硬性检查**每个 sysupgrade/factory/itb
   镜像是否 ≤ `58 * 1024 * 1024` 字节，超了就 fail，并打印体积最大的 20 个
   ipk 和裁剪建议。CI 里这一步失败仍会上传产物，方便诊断。

粗算（squashfs/xz 压缩后）：kernel + base ≈ 18–24 MB，xray-core ≈ 7–10 MB，
两个 LuCI 应用及其依赖 ≈ 6–10 MB，mt7981 WiFi 固件 + wpad ≈ 4–6 MB，
Vantage 主题 ≈ 0.3 MB。**落在 40–55 MB 区间是有可能的，但不是保证**——
feed 版本一变、xray-core 一升级就可能越线。第一次云编译后请以
`check-size.sh` 的实际输出为准，按它给的顺序裁剪。

---

## 4. 为什么固件在云端编译，而不是本机

本机是 Windows + Git Bash：`wsl.exe` 被安全策略禁止启动，`gh` 未安装，没有
Linux 原生大小写敏感文件系统，也没有 OpenWrt 的编译依赖链。上游 README 明确
要求 Debian/Ubuntu 22/24、非 root 用户、大小写敏感文件系统，首次编译单线程。
**在这台机器上直接 `make` 不可能成功。**

因此交付的是：一个已定制的 fork + GitHub Actions 工作流，push 上去即在
Ubuntu 24.04 runner 上编译，三台设备共用一次工具链编译（`TARGET_MULTI_PROFILE`），
产物作为 artifact 下载。

### 云编译触发方式

1. 打开 fork 仓库 → **Actions** → **Build LEDE MT7981 firmware** → **Run workflow**；
2. `devices` 默认 `cetron_ct3003 cmcc_rax3000m-nand qihoo_360t7`；
   eMMC 版就改成 `cmcc_rax3000m-emmc`，改过 U-Boot 的 CT3003 用 `cetron_ct3003-mod`；
3. `max_mib` 默认 58；
4. 单次完整编译约 2–5 小时（首次），job 上限设为 360 分钟；
   完成后在 run 页面下载 `lede-mt7981-*` artifact。

### 在真正的 Linux / WSL 上本地编译

```bash
# Ubuntu 22.04/24.04，非 root，大小写敏感目录
git clone <your-fork-url> lede && cd lede
git checkout custom/mt7981
# 按上游 README.md「安装编译依赖」一节的 apt 清单装齐依赖
bash scripts/prepare.sh
make download -j8
make V=s -j1                       # 首次编译推荐单线程
bash scripts/check-size.sh
# 产物：bin/targets/mediatek/filogic/
```

WSL 额外注意（上游 README 原文要求）：`make` 前加
`PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`；
clone 之前用管理员 PowerShell 执行
`fsutil.exe file setCaseSensitiveInfo <path> enable`。

---

## 5. 本次新增的文件

| 文件 | 作用 |
|---|---|
| `configs/feeds.custom` | passwall_packages / passwall2 / vantage 三个 feed（含上游迁移说明） |
| `configs/mt7981.seed` | `.config` 种子：target、镜像、裁剪、包选择、IPv4 相关 |
| `scripts/prepare.sh` | 幂等准备脚本：加 feed、精简默认包、注入 uci-defaults、生成 `.config`、精确选设备 |
| `scripts/uci-defaults/zzzz-ipv4-only` | 首次启动把网络收敛为纯 IPv4 |
| `scripts/uci-defaults/zzzz-vantage-theme` | 首次启动锁定 Vantage 主题 |
| `scripts/check-size.sh` | 编译后硬校验 ≤58 MiB 并给出裁剪建议 |
| `.github/workflows/build-mt7981.yml` | Ubuntu 24.04 云编译 + 产物上传 |
| `doc/CUSTOM-BUILD.md` | 本文件 |

`prepare.sh` 里设备 profile 符号不是硬编码的：先 `make defconfig`，再从生成的
`.config` 里反查 `CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_*` 真实符号名
（上游对 `-` 的处理在不同版本不一致），匹配后写回。这样不会因为符号名
写错而静默编译出别的设备。

---

## 6. 已知风险 / 需要你确认的点

1. **58 MB 是紧约束，无法静态保证**。两个代理插件 + 主题 + 三设备同编，
   第一次云编译必须看 `check-size.sh` 输出再决定是否进一步裁剪。
2. **上游混合**：24.10.5 系统 + 25.12 LuCI feed + 6.18 内核 + 第三方
   passwall/vantage feed，任何一边更新都可能引入依赖冲突。三个 feed 都用了
   浮动 `main` 分支；要可复现，建议后续改成固定 tag/commit
   （Vantage 有 `v1.0.x` tag，passwall2/packages 目前只有 `main` 分支）。
3. **fork 需要 GitHub 凭据**：本会话没有 `gh`、没有 PAT、没有 GitHub SSH 凭据，
   无法替你完成账号侧的 fork 与 push。本地仓库和定制分支已经准备好。
4. **RAX3000M 必须分清 NAND / eMMC**，CT3003 必须分清原厂 U-Boot / mod U-Boot，
   刷错版本会变砖。默认只出 NAND 与原厂 U-Boot 版。
5. 上游 README 要求「源码编译二次发布注明 coolsnowwolf/lede 链接」——
   本文件与 fork 的 README 已保留该出处，正式发布固件时请继续保留。
6. 上游自带 `.github/workflows/openwrt-ci.yml`（KFERMercer/OpenWrt-CI，
   只有 `schedule` 触发）。fork 中定时任务默认是关闭的，不会和本方案冲突；
   若你手动启用了它，建议删掉该文件，避免每天多跑一次全量编译。
