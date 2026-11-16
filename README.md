# phDroid for OnePlus Ace 5 Pro (hummer)

[`Dere3046/_patchHarmony`](https://github.com/Dere3046/_patchHarmony) 的 fork，目标设备：

| 项目 | 值 |
|---|---|
| 机型 | 一加 Ace 5 Pro（`hummer`） |
| 系统 | LineageOS 24.0 |
| 内核 | `6.6.144-4k-g01ee97578159` |
| 内核 commit | `01ee97578159bc9cb2a60f559d20510ce33add6a` |
| KMI | `android15-6.6` |
| 原厂编译器 | clang r596125（clang 22.0.2） |

在**不刷内核**的前提下，用可加载模块补上厂商内核裁掉的容器能力。

---

## 构建产物

| 模块 | 内容 |
|---|---|
| `droid_lkm` | PID / IPC namespace、SYSVIPC、POSIX mqueue，`main` + `native` 双 PID 后端 |
| `droid_lkm_misc` | 伪造 user namespace（`userns=1`），devtmpfs / xt 部分默认关闭，避免和 extras 重复注册 |
| `droid_lkm_vendor` | OPPO 厂商兼容修正（safe 包不包含） |
| `devtmpfs_lkm` | 注册 devtmpfs（原厂 `CONFIG_DEVTMPFS=n` 时） |
| `macvlan` | `--net=macvlan` 支持 |
| `ip6table_nat` | IPv6 NAT |
| `droid_lkm_pids` | cgroup pids 控制器 |
| `droid_lkm_cpu` | `cpu.max` 时间片限流 |

extra 模块**按原厂 boot.img 的 config 决定是否编译**：对应 CONFIG 已经是 `y`/`m` 就跳过，不会重复注册。

加载顺序由 `config.conf` 的 `modules=` 决定：

```
droid_lkm → droid_lkm_misc → droid_lkm_vendor → devtmpfs_lkm → macvlan
→ ip6table_nat → droid_lkm_pids → droid_lkm_cpu
```

---

## 构建方式

全部通过 GitHub Actions，手动填 OTA 链接：

### 推荐：manifest 工具版

**Actions → `[phDroid] Build from OTA + extras (manifest tools)`**

`.github/workflows/build-hummer-ota-manifest.yml`

- 不用 DDK 容器
- 不用 Magisk `magiskboot`，用 AOSP `unpack_bootimg.py`
- 所有工具按 `build-manifest.xml` 的 revision 固定：

| 工具 | manifest 项目 |
|---|---|
| clang | `prebuilts/clang/host/linux-x86` |
| GNU make / bison 等 | `prebuilts/build-tools` |
| kernel build tools | `kernel/prebuilts/build-tools` |
| `unpack_bootimg.py` / `bootimg.py` | `system/tools/mkbootimg` |

pahole 优先用 manifest 预编译；不可用时回退 Ubuntu `dwarves`，版本写进 build-info。

### DDK 容器版

**Actions → `[phDroid] Build from OTA + extras (check green)`**

`.github/workflows/build-hummer-ota-full.yml`

- 用 `ghcr.io/ylarod/ddk-min:android15-6.6-20260313` 提供构建环境
- 其余流程与 manifest 版一致

### 其它入口

| Workflow | 用途 |
|---|---|
| `[phDroid] Build from OTA` | 只编核心模块，不带 extras |
| `[phDroid] Build pinned kernel (20261030)` | 固定 20261030 内核输入，不跟随 OTA |
| `[phDroid] Repackage normal/safe` | 不重编内核，只改 `module/` 脚本或 WebUI 后重打包 |

### 公共输入

| 输入 | 说明 |
|---|---|
| `boot_img_url` | OTA 的 `boot.img` |
| `manifest_url` | OTA 的 `build-manifest.xml` |
| `safe_mode` | 不加载 `droid_lkm_vendor` |
| `publish_release` | 成功后发布 Release |
| `extras_repo` / `extras_sha` | extra 模块源码仓库与固定 commit |

默认值指向 20261113 OTA。

---

## 构建流程

1. 解析 `build-manifest.xml` → kernel / modules / devicetrees / clang / build-tools / kernel-build-tools / mkbootimg revision
2. 从 `boot.img` 提取 `.config`、完整 `Linux version`、`based on rXXXXX`
3. 用提取出的 config + 原厂 clang 编 **精确 KDIR**（`make O=out Image modules`）
4. 用同一个 KDIR 编 `droid_lkm` / `droid_lkm_misc` / `droid_lkm_vendor`
5. 按原厂 config 编缺失的 extra 模块
6. 打包成 KernelSU 模块 zip，校验所有 `.ko` 的 vermagic 一致

所有 `.ko` 的 vermagic 都必须是：

```
6.6.144-4k-g01ee97578159 SMP preempt mod_unload modversions aarch64
```

---

## 产物

| Workflow | Artifact / Release |
|---|---|
| manifest 版 | `phdroid-ota-manifest-<run_id>` / `phDroid-*-hummer+extras.zip` |
| DDK 版 | `phdroid-ota-full-<run_id>` / `phDroid-*-hummer+extras.zip` |
| 基础版 | `phdroid-ota-<run_id>` / `phDroid-*-hummer.zip` |
| 固定内核版 | `phdroid-upstream-<run_id>` |
| 重打包 | `phdroid-upstream-safe-<run_id>` 或 normal |

模块 ID 是 `phdroid`，`module.prop` 里的 `versionCode` 为 `7`。

---

## 目录

```
src/            phDroid 源码（上游 + 本 fork 的 6.6 适配）
module/         KernelSU 模块模板（service.sh / config.conf / WebUI）
ci/             构建脚本（KDIR、LKM、extras、打包、manifest 工具）
config/         hummer 内核配置（OTA 解析失败时兜底）
.github/        workflow
```

---

## 状态

- App 终端退出导致整机硬复位的问题仍在上游处理中：
  https://github.com/Dere3046/_patchHarmony/issues/15
- 该问题与 extra 模块、`main`/`native` PID 后端、`dontaudit` 都无关，已逐一排除。
- 不要与其它 namespace 实现（例如 `droidspaces_hummer`）同时启用。
