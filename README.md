# phDroid for OnePlus Ace 5 Pro (hummer)

[`Dere3046/_patchHarmony`](https://github.com/Dere3046/_patchHarmony) 的 fork（上游基线
`687fd3c6`，v2.0.4），目标设备：

| 项目 | 值 |
|---|---|
| 机型 | 一加 Ace 5 Pro（`hummer`） |
| 系统 | LineageOS 24.0 |
| 内核 | `6.6.144-4k-g01ee97578159` |
| 内核 commit | `01ee97578159bc9cb2a60f559d20510ce33add6a` |
| KMI | `android15-6.6` |
| 原厂编译器 | clang r596125（clang 22.0.2） |

在**不刷内核**的前提下，用可加载模块补上厂商内核裁掉的容器能力。所有 `.ko` 都用
**设备自己的 config + 原厂 clang** 编出来，vermagic 与设备一致。

> **两个仓库怎么选**
>
> | 需求 | 用哪个 |
> |---|---|
> | 让 `droidspaces check` 全绿、日常跑容器 | **本仓库**（模块 ID `phdroid`） |
> | 需要真实 `unshare -Ur` / `uid_map` / `gid_map` | [`Dry-Earth/droidspaces-lkm`](https://github.com/Dry-Earth/droidspaces-lkm)（模块 ID `droidspaces_lkm`） |
>
> 两者的 namespace hook 互斥，**不能同时启用**。

---

## 1. 这个仓库实现了什么

### 1.1 按设备精确构建

不再用通用 GKI 包，而是从 OTA 的 `boot.img` + `build-manifest.xml` 反推出设备环境：

- 从 `boot.img` 解出原厂 `.config`、完整 `Linux version`、编译器 banner
- 从 `build-manifest.xml` 取 kernel / modules / devicetrees / clang / build-tools /
  kernel-build-tools / mkbootimg 的 revision
- 用原厂 clang 与同一份 config 编出**精确 KDIR**，再用它编模块

所以内核升级（`uname -r` 变化）后，模块必须重编；`service.sh` 会在加载前做
`preflight`：`uname -r` 与 `build-id.txt` 不一致、或任何一个 `.ko` 的 vermagic
对不上，就直接拒绝加载并写日志。

### 1.2 phDroid 的 6.6 适配与稳定性改动

| 改动 | 作用 |
|---|---|
| `main` + `native` 双 PID 后端 | 默认 `main`；`native` 是另一条实现，排查用 |
| namespace hook 改为 kprobe 路由 | 带 PAC 序言的函数无法用 text patch，避免内核卡死 |
| `ds_slot.c` 保留 6.6 版本 | 不合并 5.15 的 `do_exit` 重复清理钩子 |
| `backing_file_open` ABI 适配 | 厂商 6.6 签名是 `const struct file *` |
| PID cache / panic 修复 | 对应上游 `9f65632` 的两个修复 |
| 运行时符号解析 + 布局自检 | `/proc/droid_lkm/features` 能看到每个 hook 的路由与状态 |

### 1.3 `droid_lkm_misc`：让 `check` 变绿的 user namespace

`droid_lkm_misc` 用 `userns=1` 启动，提供**模拟**的 user namespace：

- `unshare(CLONE_NEWUSER)` 返回 0
- `/proc/<pid>/ns/user` 存在
- `droidspaces check` 的 `Sandboxing (user namespaces)` 变绿

但它**没有真实映射**：`uid_map` / `gid_map` 是空的，不能当安全边界。
真实 userns 请用 `droidspaces-lkm`（vendored `user_namespace.c`）。

同一模块里的 `devtmpfs` / `xt` 默认关闭（`devtmpfs=0 xt=0`），因为这两项由
extras 模块单独提供，避免重复注册。

### 1.4 extras：内核缺什么才编什么

`ci/build-extra-modules.sh` 读解包出来的 `build-config/stock.config`，对应 CONFIG
已经是 `y`/`m` 就跳过：

| 模块 | 跳过条件 |
|---|---|
| `devtmpfs_lkm` | `CONFIG_DEVTMPFS=y/m` |
| `macvlan` | `CONFIG_MACVLAN=y/m` |
| `ip6table_nat` | `CONFIG_IP6_NF_NAT` + `CONFIG_IP6_NF_TARGET_MASQUERADE` |
| `droid_lkm_pids` | `CONFIG_CGROUP_PIDS=y/m` |
| `droid_lkm_cpu` | `CONFIG_CFS_BANDWIDTH=y/m` |

打包时只把**实际编出来**的模块写进 `config.conf` 的 `modules=`，并给版本号加
`+extras`。

### 1.5 加载器与 WebUI

- `module/service.sh`：默认**不自动加载**，带 crash 计数 / blocked / 生存窗口等安全兜底
- WebUI 是 `module/webroot/` 里的预构建页面（`index.html` + `main.js`，经典脚本 +
  `window.ksu.exec`），**不依赖构建**；`webui/` 下的 React 源码未接入发布
  （Vite 产物是 ESM，KernelSU 以 `file://` 打开会被 CORS 拒绝 → 白屏）
- WebUI 保存的配置写到 `/data/adb/phdroid/config.conf`，`service.sh` 优先读它
- `service.sh install` 会复制配置并**真正加载一次**

WebUI 的详细说明见 [`webui/README.md`](webui/README.md)。

### 1.6 已定位的问题

**App 终端里 `exit` / 点 × 导致整机硬复位**：根因是 **KernelSU 的 LKM 模式 root**，
与 phDroid、模块、上游都无关（同一内核上的另一套 LKM 也能复现，换非 LKM root
后不再复位）。记录：<https://github.com/Dere3046/_patchHarmony/issues/15>。

---

## 2. 模块清单

| 模块 | 作用 | 默认加载 |
|---|---|:---:|
| `droid_lkm` | PID / IPC namespace、SYSVIPC、POSIX mqueue（`main` + `native` 后端） | ✓ |
| `droid_lkm_misc` | 模拟 user namespace（`userns=1`，devtmpfs/xt 关闭） | ✓ |
| `devtmpfs_lkm` | 注册 devtmpfs | config 缺时 |
| `macvlan` | `--net=macvlan` | config 缺时 |
| `ip6table_nat` | IPv6 NAT | config 缺时 |
| `droid_lkm_pids` | cgroup pids 控制器 | config 缺时 |
| `droid_lkm_cpu` | `cpu.max` 时间片限流 | config 缺时 |
| `droid_lkm_vendor` | OPPO 厂商兼容（ghost / DDL） | ✗ 默认不加载 |

加载顺序由 `module/config.conf` 的 `modules=` 决定，例如：

```
modules=droid_lkm droid_lkm_misc devtmpfs_lkm macvlan ip6table_nat droid_lkm_pids droid_lkm_cpu
```

> `droid_lkm_vendor` 在 LineageOS 上 OPPO 驱动是内建的，ghost / DDL 基本不触发，
> 所以默认不加载。`safe_mode` 输入目前只会给版本号加 `-safe` 后缀，内容与普通包
> 基本一致。

---

## 3. 模块怎么用

### 3.1 安装前

1. 保留 fastboot / recovery 回滚手段。
2. 停用其它 namespace 实现（`droidspaces_lkm`、`droidspaces_hummer`、旧 phDroid）：

```sh
su -c 'touch /data/adb/modules/droidspaces_lkm/disable'
su -c 'touch /data/adb/modules/droidspaces_hummer/disable'
```

3. **重启**，让旧的 hook 完全卸载。

### 3.2 安装

KernelSU / APatch 里安装 zip（`phDroid-v2.0.0-hummer+extras.zip`），重启。

包内布局：

```
module.prop  config.conf  build-id.txt  customize.sh  service.sh  uninstall.sh
bin/android15-6.6/*.ko
webroot/                      # WebUI
```

### 3.3 首次：手动加载一次

默认**不会**自动加载（避免没验证就开机自启）：

```sh
su -c 'sh /data/adb/modules/phdroid/service.sh load'
```

成功标志：`/data/adb/phdroid/last_result` 是 `ok: manual`，日志
`/data/adb/phdroid/phdroid.log` 末尾有 `manual load ok`。

### 3.4 常用命令

```sh
# 状态（版本、内核、已加载模块、auto/blocked、参数、日志尾部）
su -c 'sh /data/adb/modules/phdroid/service.sh status'

# 手动加载
su -c 'sh /data/adb/modules/phdroid/service.sh load'

# 清掉 blocked / crash / pending 状态
su -c 'sh /data/adb/modules/phdroid/service.sh reset'

# 复制配置到 /data/adb/phdroid/config.conf 并立即加载
su -c 'sh /data/adb/modules/phdroid/service.sh install'
```

### 3.5 验证

```sh
# 内核模块（7 个：droid_lkm + misc + 5 个 extras；含 vendor 的旧包是 8 个）
su -c 'lsmod | grep -E "droid_lkm|devtmpfs_lkm|macvlan|ip6table_nat"'

# droidspaces 自检（不在默认 PATH）
su -c '/data/local/Droidspaces/bin/droidspaces check'

# 加载日志
su -c 'tail -n 50 /data/adb/phdroid/phdroid.log'

# userns（模拟实现）
su -c 'ls -l /proc/self/ns/user'
su -c 'dmesg | grep -iE "droid_lkm_misc|userns"'
```

`droidspaces check` 应该全绿，包括 `Sandboxing (user namespaces)`。

userns 自检里如果出现 `mount tmpfs ... -13`，那是 SELinux 对 `u:r:kernel:s0` 的
`mounton` 拒绝，**不影响 check 结果**。

### 3.6 打开自动加载

确认手动加载稳定（建议至少重启一次仍正常）后：

```sh
su -c 'touch /data/adb/phdroid/auto'
```

也可以在 WebUI 概览页打开。安全兜底：

- 上次 `insmod` 没返回 → 下次开机写 `blocked`
- 加载后生存窗口内重启 → 写 `blocked`
- `ro.boot.bootreason` 为 panic/watchdog 累计 ≥2 → `blocked`

`blocked` 后自动加载会跳过；手动 `reset` + `load` 可以恢复。

### 3.7 配置（`config.conf`）

`service.sh` 的读取顺序：

1. `/data/adb/phdroid/config.conf`（WebUI 保存到这里）
2. 模块目录的 `config.conf`（没有 `modules=` 时）

可用键：

| 键 | 说明 |
|---|---|
| `modules=` | 要加载的模块及顺序 |
| `kmi_override=` | 默认 `android15-6.6` |
| `oplus=` | 厂商判定开关（默认 1） |
| `droid_lkm_misc=` | 传给它自己的参数，默认 `userns=1 devtmpfs=0 xt=0` |
| `devtmpfs_lkm=` | 默认 `devtmpfs_probe=2` |

改完配置后执行 `service.sh install`（或重启）才会重新加载。

### 3.8 WebUI

KernelSU 模块页点“打开”即可。页面能看状态、开关自动加载、解除 blocked、看日志
和 `/proc/droid_lkm/features`。

注意：**Params 页显示的是 insmod 参数，权限 0444，加载后不能改**；要改就改
`config.conf` 再重新加载。详见 [`webui/README.md`](webui/README.md)。

### 3.9 卸载 / 切换

```sh
su -c 'touch /data/adb/modules/phdroid/remove'
```

重启后卸载。切换到 `droidspaces_lkm` 时同样先停用本模块并重启。

---

## 4. 工作流怎么用

全部是手动 `workflow_dispatch`，不写死 OTA；换版本只改两个 URL。

### 4.1 入口

| Workflow | 文件 | 用途 |
|---|---|---|
| **`[phDroid] Build from OTA + extras (manifest tools)`** | `build-hummer-ota-manifest.yml` | **推荐**：无 DDK、无 magiskboot，工具全部按 manifest 固定 |
| `[phDroid] Build from OTA + extras (check green)` | `build-hummer-ota-full.yml` | DDK 容器版（`ghcr.io/ylarod/ddk-min:android15-6.6-20260313`），兜底 |
| `[phDroid] Build from OTA (upstream _patchHarmony)` | `build-hummer-ota.yml` | 只编核心模块，不带 extras |
| `Build hummer phDroid (upstream 9f65632)` | `build-hummer-upstream.yml` | 固定内核输入（`config/hummer_config.gz`），复现旧环境 |
| `[phDroid] Repackage normal/safe` | `repackage-upstream.yml` | 不重编，只改 `module/` 或 WebUI 后重打包 |
| `Build native PID` | `native.yml` | 只验证 `src/native` 的 PID 后端能否编译 |

### 4.2 输入

| 输入 | 默认 | 说明 |
|---|---|---|
| `boot_img_url` | `.../hummer/20261113/boot.img` | OTA 的 boot.img |
| `manifest_url` | `.../hummer/20261113/build-manifest.xml` | 同一 OTA 的 manifest |
| `safe_mode` | `false` | 只影响版本后缀；`droid_lkm_vendor` 已默认不加载 |
| `publish_release` | `true` | 成功后发 Release |
| `extras_repo` | `Dry-Earth/droidspaces-lkm` | extras 源码仓库 |
| `extras_sha` | `522dc420…` | extras 固定 commit |

> 默认值停在 20261113；构建 20261120 等新 OTA 时手动换成对应的两个 URL。

命令行触发：

```sh
gh workflow run build-hummer-ota-manifest.yml \
  -f boot_img_url=https://mirrorbits.lineageos.org/full/hummer/20261120/boot.img \
  -f manifest_url=https://mirrorbits.lineageos.org/full/hummer/20261120/build-manifest.xml \
  -f publish_release=true
```

### 4.3 流水线做什么

1. 解析 `build-manifest.xml` → kernel / modules / devicetrees / clang / build-tools /
   kernel-build-tools / mkbootimg 的 revision
2. 下载 `boot.img`，用 AOSP `unpack_bootimg.py` 解包
3. 提取 `.config`、完整 `Linux version`、编译器 banner（patched boot 没有
   `based on r…` 时从 `CONFIG_CC_VERSION_TEXT` 回退）
4. 按 manifest revision 检出 kernel / modules / extras
5. 准备工具链（clang、build-tools、kernel-build-tools、pahole；pahole 不可用时
   回退 Ubuntu `dwarves`）
6. 用原厂 config + clang 编精确 KDIR（`make O=out Image modules`）
7. 编 `droid_lkm` / `droid_lkm_misc`（+ `native` 后端）
8. 按 stock config 编缺的 extras，写 `out/<KMI>/extra-modules.list`
9. 改 `module/`：`config.conf` 只列实际编出来的模块，写 `build-id.txt`
10. 打包 `module/webroot` 的原样 WebUI（`index.html` + `main.js`，不做前端构建）
11. 打包 `dist/phDroid-*.zip`，逐个校验“编出来的 `.ko` 都在 zip 里”
12. 上传 artifact，按需发 Release

### 4.4 产物

| Workflow | Artifact / Release tag | 主要文件 |
|---|---|---|
| manifest 版 | `phdroid-ota-manifest-<run_id>` | `phDroid-v2.0.0-hummer+extras.zip`、`build-info-manifest.txt` |
| DDK 版 | `phdroid-ota-full-<run_id>` | 同上 |
| 基础版 | `phdroid-ota-<run_id>` | `phDroid-v2.0.0-hummer.zip` |
| 固定内核版 | `phdroid-upstream-<run_id>` | 同上 |
| 重打包 | `phdroid-upstream-safe-<run_id>` / normal | 按 `safe_mode` 命名 |

`build-info-manifest.txt` 里记录了 boot sha256、kernel/modules/extras commit、各工具
revision、每个 `.ko` 与 zip 的 sha256、每个模块的 vermagic —— 排查“装的是哪一版”
先看它。

### 4.5 什么时候要重跑

- OTA 换了（内核 `uname -r` 变化）→ 必须重跑，否则 preflight 会拒绝加载
- 改了 `src/`、`patches`、`scripts/build_modules` 相关、`ci/*`、`module/*`
  （包括 `module/webroot` 的 WebUI）
- extras 仓库的 pinned commit 变了
- 只改文档 / README → 不用重跑

### 4.6 常见失败

| 现象 | 原因 / 处理 |
|---|---|
| 加载时报 `preflight` 失败 | 内核与 `build-id.txt` 不一致，或某个 `.ko` vermagic 不对 → 换 OTA 重编 |
| `insmod: unknown symbol` | KMI 选错 / 内核已换；看 `build-info-manifest.txt` 的 release 与 vermagic |
| 开机后没有模块 | 默认不自动加载 → `touch /data/adb/phdroid/auto` 或手动 `load` |
| 自动加载被跳过 | `blocked` → `service.sh status` 看原因，`reset` 后 `load` |
| WebUI 白屏 | 包里的 `module/webroot` 被 Vite 产物（ESM）覆盖了；KernelSU 以 `file://` 打开会拒绝 `type="module"`。重新打包，保留 `index.html` + `main.js` |
| WebUI 打不开 | 包内 `webroot/` 是否完整；看 KernelSU 日志 |
| 终端 `exit` 硬复位 | KernelSU LKM 模式 root，见上游 issue #15，与模块无关 |

---

## 5. 已验证状态（2026-11-28）

设备：OnePlus Ace 5 Pro / LineageOS 24

| 版本 | 构建输入 | ZIP sha256 | 状态 |
|---|---|---|---|
| v2.0.0 | `boot-20261120-finasu-v3.img` + 20261120 manifest | `649c1cf99d1fa38a997af2f39843ad6657cb368482250fc6814212feb9e2cd95` | **已在设备验证** |
| v2.0.4 | `boot-20261120-finasu-v3.img` + 20261120 manifest | `27c9d40a4161b51f4071ff9f3da4c3ef7fddc46a686548affef02e9a22253801` | 待设备验证 |
| v2.0.4 | 官方 `20261127/boot.img` + 20261127 manifest | `82899ae06f1d77543e3a12d1b2335bced66607e9ea55d9fc96f87269006929fe` | 待设备验证；`.ko` 与上一行逐字节相同 |

v2.0.0 的设备实测：

- `droidspaces check` **全绿**，含 `Sandboxing (user namespaces)`
- 8 个模块全部加载（该版本仍包含 `droid_lkm_vendor`；之后默认不再加载）
- userns 是模拟实现：`unshare` 成功、`/proc/<pid>/ns/user` 存在，无真实映射
- userns 自检里的 `mount tmpfs -13` 是 SELinux `u:r:kernel:s0` 的 `mounton` 拒绝，不影响 check

v2.0.4 的情况：

- 合并了上游 `687fd3c6`（v2.0.4，`fix 6.1`：IPC namespace 的 kernel-owned adopt 路径 + workqueue 退休 + `DS_HOOK_RECORDS 16`）
- 保留本 fork 的 6.6 版 `ds_slot.c`（不含 5.15 的 `do_exit` 清理钩子）
- 20261127 OTA 的 kernel commit 与 20261120 相同（`01ee97578…`），所以 8 个 `.ko`
  与 20261120 输入编出来的**逐字节相同**；zip sha 不同只因 `build-id.txt` 里记录了新的
  `modules` revision
- 仍需在设备上确认：开机正常、`boot-completed` 清零、容器起停与 `unshare -i` 无异常

---

## 6. 与 `droidspaces_lkm` 的取舍

| | phDroid（本仓库） | droidspaces-lkm |
|---|---|---|
| 模块 ID | `phdroid` | `droidspaces_lkm` |
| userns | 模拟（只为 check 绿） | vendored 真实 `user_namespace` |
| `unshare -Ur` / `uid_map` | ✗ | ✓ |
| 加载器 | 带 crash/blocked/生存窗口兜底 | 上游 service.sh（ko_switch） |
| WebUI | 有 | 上游有 |
| 稳定性 | 已验证 check 全绿 | 已验证真实 userns 可用 |

两者都会抢 namespace hook，**只能启用一个**。

---

## 7. 目录

```
src/            phDroid 源码（上游 + 本 fork 的 6.6 适配）
module/         KernelSU 模块模板（service.sh / config.conf / WebUI）
webui/          上游 React WebUI 源码（未接入发布；发布用 module/webroot）
ci/             构建脚本（KDIR、LKM、extras、打包、manifest 工具）
config/         hummer 内核配置（固定内核构建时兜底）
.github/        workflow
```

---

## 8. 维护

- **上游同步点**：`Dere3046/_patchHarmony@687fd3c6`（v2.0.4）。上游再有 6.1 /
  IPC namespace / PID cache 一类修复时，合并 `src/` 后重跑工作流。
- **不要在 Windows 上直接改 `patches/*.patch`**：CRLF 会让 `git apply` 失败；
  改完先本地按序 `git apply --check`。
- **extras 的 pinned commit**：`extras_sha` 变了就等于换了 extras 源码，需要重编。
- **版本号**：打包脚本写 `v2.0.4-hummer`；有 extras 时追加 `+extras`，`safe_mode`
  时追加 `-safe`。
