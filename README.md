# phDroid (upstream dfae0675) for OnePlus Ace 5 Pro (hummer)

在 **LineageOS 24.0 原厂内核**上补 Droidspaces 所需的
PID / IPC / SYSVIPC / POSIX mqueue 能力，不刷内核、保持 Systemless。

本仓库是 [`Dere3046/_patchHarmony`](https://github.com/Dere3046/_patchHarmony)
的 fork，已同步到上游 **dfae0675**（2026-11-11，`fix 6.12 6.18`，
包含 `fix panic` / `fix pid cache` / native PID / ipcns offset 修复），目标设备：

> **新增：Shikochin 移植**
>
> 仓库现在同时包含 [Shikochin/Droidspaces-LKM](https://github.com/Shikochin/Droidspaces-LKM)
> 的第二套 6.6 实现（PID/IPC namespace + 可选 devtmpfs），源码在
> `third_party/shikochin-lkm/`，构建入口是
> `.github/workflows/build-hummer-shikochin.yml`（支持 OTA 自动解析，
> 也可以关闭 `use_ota` 用固定 SHA）。
> 模块 ID 为 `droidspaces_hummer`，**不能和 phDroid 同时启用**。
> 说明、限制和安装步骤见 [README-SHIKOCHIN.md](README-SHIKOCHIN.md)。

| 项目 | 值 |
|---|---|
| 机型 | 一加 Ace 5 Pro（`hummer`） |
| 系统 | LineageOS 24.0（20261030） |
| 内核 | `6.6.144-4k-g6350e8af3f4c` |
| 内核 commit | `6350e8af3f4c452d087fbd6fe1aabe03cbc0af75` |
| KMI | `android15-6.6` |
| 原厂编译器 | clang r596125（`clang version 22.0.2`） |
| PID 后端 | **native**（`DROID_LKM_NATIVE_PID=1`） |

---

## 为什么之前停止/重启容器会关机

旧 fork 停留在 **2026-10-29** 的上游代码，缺少之后的关键提交：

| 提交 | 内容 |
|---|---|
| `58eb199` | **fix panic**：nsproxy / pid_namespace 释放路径 |
| `f92bb3d` | **fix pid cache**：pidns 缓存、ds_slot、nsproxy 引用 |
| `f2e00ec` | add native：native PID / IPC 实现 |
| `9f65632` | one mod：打包收尾 |

停止容器时，内核要释放伪造的 PID/IPC namespace 和 nsproxy 引用；
旧代码在 6.6 上存在布局/引用计数问题，容易内存踩坏 → 卡死 → 看门狗关机。
本仓库现在用上游修复后的源码 + **精确 6.6.144 KDIR** + **原厂 clang r596125**
重新编译，并启用 native PID 后端。

### 2026-11-11 上游 `dfae0675`（fix 6.12 6.18）修了什么

这次主分支只新增了一个提交 `dfae0675`，改 8 个文件：

- `ipcns` 字段偏移：
  - 模块自己创建的 namespace 用**编译期布局**；
  - 内核自己分配的 namespace 用**运行期布局**；
  - 新增 `droid_lkm_ipcns_off()`，修掉 6.12 上“用 build offset 拼 set 指针”导致的崩溃；
  - 缺 `user_ns` 时打印警告，方便定位。
- `check_unshare_flags`：
  - 内核没导出、也没取地址，BTI 下不能直接 indirect call；
  - 改成“return 进入函数”的调用方式；
  - 同时检查目标地址是否落在内核 text 范围内，越界就不调用。
- vendor ghost 的 `task_struct.usage` 初值从 `1000` 改成 `0x40000000`。
- `ds_ti` 增加 `droid_lkm_layout_build_off()`。

这对 6.6 的 native PID 也有意义：`ipcns` 的 build/runtime offset 分离
同样适用于我们的 6.6.144 精确 KDIR。

> 注意：这是“更可能稳定”的版本，不是绝对保证。仍然建议先手动加载验证。

---

## 产物

### 最新：20261106 OTA + 上游 dfae0675（带 WebUI）

**正常包：**

- Release：https://github.com/Dry-Earth/LKM-Droidspaces/releases/tag/phdroid-ota-43028111848
- zip：`phDroid-v2.0.0-hummer.zip`
- sha256：`d60ba311680ea9baf5fc143a1a2fec46303777f68860ce68ac1f2e75125c8579`
- 模块：`droid_lkm` + `droid_lkm_vendor`
- ko：
  - `droid_lkm.ko` sha256 `ae2fe3967647bbbfde4f559f4ce175be7b8ebb871d1d018ad07652ecdc512024`
  - `droid_lkm_vendor.ko` sha256 `ae8a75b4e37725a661c6032a1620957beebbdd6197bb55a8def48dd9da0a428e`

**安全模式包（只加载 droid_lkm）：**

- Release：https://github.com/Dry-Earth/LKM-Droidspaces/releases/tag/phdroid-upstream-safe-43033226466
- zip：`phDroid-v2.0.0-hummer-safe.zip`
- sha256：`4da1693ab0ac232e874b8a5a489f65c4490c57409d19d6c2d78bfc5737f937dd`

两个包的 vermagic 都是：

```
vermagic=6.6.144-4k-g6350e8af3f4c SMP preempt mod_unload modversions aarch64
```

20261106 OTA 的 boot sha256：

```
0af12a32e476b40752da27344f05198161cd84de977d8f4c58bc649809904456
```

> 20261106 仍是 kernel `6350e8af...` / modules `e05c031c...` /
> release `6.6.144-4k-g6350e8af3f4c` / clang `r596125`，和 20261030 相同；
> 新包的主要变化是上游 `dfae0675` 的 ipcns/BTI 修复。

### 旧包（20261030，保留作回退）

- 正常包：https://github.com/Dry-Earth/LKM-Droidspaces/releases/tag/phdroid-upstream-42248909106
  - sha256 `d386395d8f7b18d203f312daf7a81ea02aca40c9c061ff90dece61020d35a21d`
- 安全包：https://github.com/Dry-Earth/LKM-Droidspaces/releases/tag/phdroid-upstream-safe-42249159170
  - sha256 `31061178f52a57400d676e5d48f21eb93b01069ea46f7639ade2153faed67ca8`

> 旧包 `phdroid-upstream-42240247134` / `phdroid-upstream-safe-42246001655`
> 没有 WebUI；请使用带 WebUI 的版本。

### WebUI 已恢复

上游 `9f65632` 的 `fix mod` 删掉了 `module/webroot` 和 `webui/`，
所以最初同步后的包没有 WebUI。本 fork 已把旧 WebUI 恢复，并适配新 `service.sh`：

- `webroot/index.html` + `webroot/main.js` 已放回模块；
- `customize.sh` 会解包 `webroot/*`（因为 `SKIPUNZIP=1`）；
- WebUI 按钮：
  - **刷新** → `service.sh status`
  - **重试加载** → `service.sh reset; PH_ACTION=load service.sh`
  - **清空日志** → `/data/adb/phdroid/phdroid.log`
- `service.sh status` 补回了 WebUI 需要的
  `kmi` / `manager` / `brand` / `model` / `oplus` / `compat` /
  `compat_wanted` / `param.*` / `cparam.*` / `last` 字段。

> 注意：WebUI 仍需要 KernelSU/APatch 的 WebUI API；KSU LKM 模式支持。

---

## 安全兜底（新）

所有状态在 `/data/adb/phdroid/`：

| 文件/机制 | 行为 |
|---|---|
| `auto` | **不存在时默认不自动加载**；验证稳定后 `touch` 它才开机加载 |
| `insmod` | insmod 前写；下次开还在 → `blocked` |
| `blocked` | 自动加载跳过；`service.sh load` 可手动绕过 |
| `boot_pending` / `.boot_ok` | 自动加载后 120 秒存活窗口；中途崩 → 下次 `blocked` |
| `crash_count` | `ro.boot.bootreason` 为 watchdog/kernel_panic/panic 时 +1；≥2 → `blocked` |
| `pstore/` | 每次开机自动保存 `/sys/fs/pstore`，保留最近 3 份 |
| `build-id.txt` | 记录 release / kernel sha / config sha；OTA 后 release 不匹配拒绝加载 |

常用命令（模块目录 `/data/adb/modules/phdroid`）：

```sh
# 状态
su -c 'sh /data/adb/modules/phdroid/service.sh status'

# 手动加载一次（首次安装必须做）
su -c 'sh /data/adb/modules/phdroid/service.sh load'

# 清除 blocked / crash_count / boot_pending
su -c 'sh /data/adb/modules/phdroid/service.sh reset'

# 验证稳定后，开启开机自动加载
su -c 'mkdir -p /data/adb/phdroid; touch /data/adb/phdroid/auto'
```

> 自动加载后有 120 秒存活窗口，**加载后 2 分钟内不要重启**，
> 否则会被误判为“加载后崩溃”。
> 可改短：`echo 30 > /data/adb/phdroid/alive_sec`。

---

## 安装

1. 先卸载/停用旧 phDroid，重启一次。
2. KernelSU → 模块 → 安装 zip。
3. 重启。首次安装 `customize.sh` 会删除 `auto`，所以**不会自动加载**。
4. 手动加载：

```sh
su -c 'sh /data/adb/modules/phdroid/service.sh load'
```

5. 启动容器 → 停止 → 再启动，连续 3 次。
6. 稳定后再开自启：

```sh
su -c 'mkdir -p /data/adb/phdroid; touch /data/adb/phdroid/auto'
```

> 第一次建议先装 **safe 包**（只加载 `droid_lkm`，不加载 OPPO vendor）。
> 如果 safe 包稳定，再试正常包；这样能把问题缩到 vendor 模块。

---

## 验证

```sh
su -c 'sh /data/adb/modules/phdroid/service.sh status'
su -c 'grep -E "^droid_lkm" /proc/modules'
su -c 'dmesg | grep -iE "droid_lkm|CFI failure|Unknown symbol" | tail -50'
su -c 'droidspaces check'
```

`user namespace` 那一项在 6.6 上仍然是红的，属预期。
容器 root 就是宿主 root，不要当安全沙箱。

---

## 崩溃现场

如果仍然关机：

```sh
su -c 'sh /data/adb/modules/phdroid/service.sh status'
su -c 'ls -l /data/adb/phdroid/pstore/'
su -c 'cat /data/adb/phdroid/pstore/*/console-ramoops* | tail -120'
su -c 'cat /data/adb/phdroid/phdroid.log'
```

把 `console-ramoops` 最后 120 行发出来，才能判断是
`nsproxy` / `ipcns` 释放、`do_exit`、还是 vendor 钩子。

---

## 构建

### 固定当前版本

`.github/workflows/build-hummer-upstream.yml`：

1. 检出精确内核 commit `6350e8af...`；
2. 用 `config/hummer_config.gz`（官方 boot.img 提取）编 KDIR；
3. 用原厂 clang r596125 编译上游 9f65632 的 `droid_lkm`（native PID）；
4. 打包 `module/` + `bin/android15-6.6`。

### OTA 自动构建（推荐以后用）

`.github/workflows/build-hummer-ota.yml` 只需要两个输入：

- `boot_img_url`：OTA 的 `boot.img`
- `manifest_url`：OTA 的 `build-manifest.xml`

流程：

1. 下载 manifest，用 `ci/parse-manifest.py` 解析
   kernel / modules / devicetrees / clang prebuilt 的精确 revision；
2. 下载 `boot.img`，`magiskboot unpack`；
3. 从 Image 提取：
   - `.config`（`extract-ikconfig`）
   - `Linux version ...` → `KERNELRELEASE`
   - `based on rXXXXX` → 原厂 clang 版本
4. 按 kernel `major.minor` 自动选 KMI（6.6 → `android15-6.6`）；
5. 从 manifest 的 clang prebuilt revision 下载对应 clang；
6. 编 KDIR、编 native PID、打包（normal/safe）。

20261106 已实测：manifest 解析结果仍是
`6350e8af` / `e05c031c` / `6.6.144` / `r596125`，
所以模块和上一版兼容；boot.img sha 变成 `0af12a32...`。

### 重新打包

`.github/workflows/repackage-upstream.yml`：
不重编内核，下载已有 ko 后按 normal/safe 重新打包。

---

## USER_NS 和可选功能

### USER_NS：不建议开

- Droidspaces 跑 rootful 容器**不需要** `CONFIG_USER_NS`；
- 原厂 6.6 内核没开，LKM 只能“伪造”，不是真的 uid 隔离；
- 上游作者也把 `misc`（devtmpfs + userns）称为“软脚”；
- 伪造 userns 要在 cred / RCU / fork 路径做 hook，正是最容易导致整机重启的部分。

结论：**保持关闭**。如果确实要 rootless / 真正 uid 隔离，唯一安全路线是
原生内核 `CONFIG_USER_NS=y` + 全量重编 vendor 模块，不是 LKM。

### 当前已支持 / 未支持

| 能力 | 状态 |
|---|---|
| PID / IPC / SYSVIPC / POSIX mqueue | ✅ `droid_lkm`（native PID） |
| OPPO vendor 兼容 | ⚙️ `droid_lkm_vendor`，safe 包可关 |
| devtmpfs / 硬件 `/dev` | ❌ 未构建（`misc` 被上游注释，作者称“软脚”） |
| USER_NS | ❌ 不支持，不建议伪造 |
| pids / cfs / memory 限制 | ❌ 当前 LKM 没有，需原生内核 |
| macvlan / IPv6 NAT | ❌ 当前上游没有，旧 fork 的 6.12 模块需移植 |
| overlayfs / seccomp / netns / cgroups | ✅ 原厂内核已开 |

> 主模块没有更多“子开关”需要打开；`pid_impl=native` 是默认值，
> `nsproxy=0` 也保持默认，不要为了“更多功能”去改这些高风险参数。

### WebUI 开关建议

已经可用且安全的开关：

- **自动加载**（`/data/adb/phdroid/auto`）
- **vendor 兼容**（`modules` 里是否包含 `droid_lkm_vendor`）
- **重试加载 / reset / 清空日志**

不建议做成“一键开启”的：

- **硬件完全访问**（devtmpfs + 全量 `/dev`）：容器 root = 宿主 root，
  能碰块设备；如果一定要，应该单独构建 `misc` 作为可选 KO，
  默认关闭、手动加载、每次加载前警告，绝不能自动加载。
- **USER_NS**：不要提供开关，避免用户误以为有隔离。
- **网络隔离**：需要单独移植 macvlan/ip6nat 并验证 6.6，默认关闭。

更安全的做法是：**LKM 只做命名空间/IPC 这一层**；
硬件访问、cgroup 限制、网络隔离走原生 boot.img，而不是继续给 LKM 加高风险钩子。

---

## 鸣谢

- **[Dere3046](https://github.com/Dere3046) / [XiYueSauce](https://github.com/XiYueSauce)**
  — `_patchHarmony` / phDroid 的原始实现、`fix panic` / `fix pid cache` / native PID。
- **[ravindu644](https://github.com/ravindu644)** — Droidspaces 本体与 GKI kABI 补丁。
- **[Ylarod](https://github.com/Ylarod)** — DDK 工具链镜像。
- **LineageOS** — hummer 内核源码与官方 boot.img。
- 酷安帖 [74877414](https://www.coolapk.com/feed/74877414) — 上游作者对
  KallRecon / _patchHarmony 的说明，本仓库据此同步到 9f65632。

没有这些上游工作，这个 fork 不可能存在。
