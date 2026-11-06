# phDroid (upstream 9f65632) for OnePlus Ace 5 Pro (hummer)

在 **LineageOS 24.0 原厂内核**上补 Droidspaces 所需的
PID / IPC / SYSVIPC / POSIX mqueue 能力，不刷内核、保持 Systemless。

本仓库是 [`Dere3046/_patchHarmony`](https://github.com/Dere3046/_patchHarmony)
的 fork，已同步到上游 **9f65632**（2026-11-05，包含
`fix panic` / `fix pid cache` / native PID），目标设备：

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

> 注意：这是“更可能稳定”的版本，不是绝对保证。仍然建议先手动加载验证。

---

## 产物

### 正常包（启用 OPPO vendor 兼容）

- Release：https://github.com/Dry-Earth/LKM-Droidspaces/releases/tag/phdroid-upstream-42240247134
- zip：`phDroid-v2.0.0-hummer.zip`（3.0 MB）
- sha256：`8e17b93f834d726c6b809ed846f0ad277019dc08338c7ffbc4c9ee28c9a35971`
- 模块：`droid_lkm` + `droid_lkm_vendor`
- ko：
  - `droid_lkm.ko` sha256 `c9ae030797bec7bc69aaf83c0b1ebbb775c101029f8936df979cedc9fae01a57`
  - `droid_lkm_vendor.ko` sha256 `26e1bc8f1b1a28e77dbfe76870cc21709185bf3c1266b8a3f387744b1b557d6b`

### 安全模式包（不加载 vendor）

- Release：https://github.com/Dry-Earth/LKM-Droidspaces/releases/tag/phdroid-upstream-safe-42246001655
- zip：`phDroid-v2.0.0-hummer-safe.zip`
- sha256：`1590e4ac3549d2615c2b9b47bba78da9a9560101d07ab4f068bf38cb7514d988`
- 模块：仅 `droid_lkm`

两个包的 vermagic 都是：

```
vermagic=6.6.144-4k-g6350e8af3f4c SMP preempt mod_unload modversions aarch64
```

> 旧的 `phDroid-v1.0.4-hummer*.zip`（10 月 29 日源码）已被淘汰，不要再用。

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

`.github/workflows/build-hummer-upstream.yml`：

1. 检出精确内核 commit `6350e8af...`；
2. 用 `config/hummer_config.gz`（官方 boot.img 提取）编 KDIR；
3. 用原厂 clang r596125 编译上游 9f65632 的 `droid_lkm`（native PID）；
4. 打包 `module/` + `bin/android15-6.6`。

`.github/workflows/repackage-upstream.yml`：
不重编内核，下载已有 ko 后按 safe/normal 重新打包。

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
