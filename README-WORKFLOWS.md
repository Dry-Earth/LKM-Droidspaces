# Workflow 导航

本仓库只有一套实现：phDroid（上游 `Dere3046/_patchHarmony` + 本 fork 的 6.6 适配）。

## 模块

| 模块 | 用途 |
|---|---|
| `droid_lkm` | PID / IPC namespace、SYSVIPC、mqueue（`main` + `native` 双后端） |
| `droid_lkm_misc` | 伪造 user namespace（`userns=1`，devtmpfs/xt 关闭） |
| `droid_lkm_vendor` | OPPO 厂商修正（safe 包不加载） |
| `devtmpfs_lkm` | devtmpfs |
| `macvlan` | macvlan |
| `ip6table_nat` | IPv6 NAT |
| `droid_lkm_pids` | cgroup pids |
| `droid_lkm_cpu` | `cpu.max` |

后 5 个是 extra：构建时读原厂 `stock.config`，对应 CONFIG 已启用就跳过。

---

## 常用入口

### 1. manifest 工具版（推荐）

**Actions → `[phDroid] Build from OTA + extras (manifest tools)`**

- 文件：`.github/workflows/build-hummer-ota-manifest.yml`
- 不用 DDK 容器，不用 magiskboot
- clang / build-tools / kernel-build-tools / mkbootimg 全部按 `build-manifest.xml` 固定
- 输入：`boot_img_url`、`manifest_url`、`safe_mode`、`publish_release`、`extras_repo`、`extras_sha`

### 2. DDK 容器版

**Actions → `[phDroid] Build from OTA + extras (check green)`**

- 文件：`.github/workflows/build-hummer-ota-full.yml`
- 构建环境来自 `ghcr.io/ylarod/ddk-min:android15-6.6-20260313`
- 其余与 manifest 版一致

### 3. 只编核心模块

**Actions → `[phDroid] Build from OTA (upstream _patchHarmony)`**

- 文件：`.github/workflows/build-hummer-ota.yml`
- 不带 extra 模块；日常只需要 namespace 时用这个

### 4. 固定内核输入

**Actions → `[phDroid] Build pinned kernel (20261030)`**

- 文件：`.github/workflows/build-hummer-upstream.yml`
- 固定 kernel `6350e8af...` + `config/hummer_config.gz`，用于复现旧环境

### 5. 只重打包

**Actions → `[phDroid] Repackage normal/safe`**

- 文件：`.github/workflows/repackage-upstream.yml`
- 输入：`run_id`、`artifact_prefix`（`phdroid-ota` / `phdroid-manifest` / `phdroid-upstream`）、`safe_mode`
- 不重编内核，适合只改 `module/` 脚本或 WebUI

---

## 公共说明

- 所有 workflow 都手动 `workflow_dispatch`，不写死 OTA；换版本只改两个 URL
- `safe_mode=true` 时不加载 `droid_lkm_vendor`
- `droid_lkm_misc` 只有在 KDIR 支持时才会被编译；`config.conf` 只列实际存在的 `.ko`
- 所有 `.ko` 必须带同一个 vermagic：`6.6.144-4k-g01ee97578159 SMP preempt mod_unload modversions aarch64`

## 产物命名

| Workflow | Artifact / Release |
|---|---|
| manifest 版 | `phdroid-ota-manifest-<run_id>` |
| DDK 版 | `phdroid-ota-full-<run_id>` |
| 基础版 | `phdroid-ota-<run_id>` |
| 固定内核版 | `phdroid-upstream-<run_id>` |
| 重打包 | `phdroid-upstream-safe-<run_id>` 或 normal |

默认不自动加载；装好后用模块 WebUI 或 `service.sh load` 手动加载一次。
