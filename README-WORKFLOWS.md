# Workflow 导航：该点哪一个？

本仓库现在有 **两套独立的内核模块实现**，不要混用：

| 实现 | 模块 ID | 源码 | 说明 |
|---|---|---|---|
| **phDroid** | `phdroid` | `src/`（上游 `Dere3046/_patchHarmony` + 本 fork 修改） | 主力实现，支持 native PID |
| **Shikochin** | `droidspaces_hummer` | `third_party/shikochin-lkm/` | 第二套 6.6 移植，可选 devtmpfs / userns 子集 |

> `phDroid` 和 Shikochin **不能同时启用**。安装器会检测并中止。

---

## 一、最常用的入口

### 想用上游 `_patchHarmony` 构建 phDroid（推荐）

**Actions → `[phDroid] Build from OTA (upstream _patchHarmony)`**

- 文件：`.github/workflows/build-hummer-ota.yml`
- 输入：
  - `boot_img_url`
  - `manifest_url`
  - `safe_mode`
  - `publish_release`
- 它会自动解析 OTA 的 kernel/modules/clang revision，从 boot.img 提取 config/release/clang，然后编 native PID、打包。
- 当前 20261106 OTA 已跑通。

### 只想重新打一个 normal/safe 包（不重编内核）

**Actions → `[phDroid] Repackage normal/safe`**

- 文件：`.github/workflows/repackage-upstream.yml`
- 输入：
  - `run_id`：之前成功的 phDroid 构建 run ID
  - `artifact_prefix`：OTA 构建填 `phdroid-ota`；固定构建填 `phdroid-upstream`
  - `safe_mode`
- 适合只改 `module/` 脚本或 WebUI 时快速出包。

### 用 Shikochin 第二套实现

**Actions → `[Shikochin] Build from OTA`**

- 文件：`.github/workflows/build-hummer-shikochin.yml`
- 输入：
  - `use_ota`、`boot_img_url`、`manifest_url`
  - `build_devtmpfs`（默认 ✅）
  - `build_netfilter`（6.6 默认 ❌）
  - `build_userns`（6.6 实验，默认 ❌）
- 产物模块 ID 是 `droidspaces_hummer`，与 phDroid 互斥。
- 详细限制见 [README-SHIKOCHIN.md](README-SHIKOCHIN.md)。

### 上游更新了怎么办

**不要点自动 sync**。旧的那个 sync workflow 会 `git reset --hard` 到上游树，
会把你 fork 里的 6.6 USER_NS / FUSE / Shikochin / WebUI 修改全部覆盖掉。

正确做法是：

1. 看上游新提交（例如 `dfae0675`）；
2. 只把涉及的源文件合进来，保留 `module/`、`webui/`、`third_party/` 的本地修改；
3. 再跑 `[phDroid] Build from OTA`。

这个 fork 已经按这种方式同步过 `dfae0675`，不需要再跑自动 sync。

### 固定 20261030 内核输入的 phDroid 构建（备用）

**Actions → `[phDroid] Build pinned kernel (20261030)`**

- 文件：`.github/workflows/build-hummer-upstream.yml`
- 当 OTA 解析失败、或想复现旧环境时用。
- 不跟随 OTA，固定 kernel `6350e8af...`、config `config/hummer_config.gz`、clang r596125。

---

## 二、不要点的旧 workflow

这些已经改成 `.disabled`，GitHub 不会执行，只保留作历史参考：

| 文件 | 原用途 |
|---|---|
| `.github/workflows/build-hummer-lkm.yml.disabled` | 旧 phDroid v1/v2 打包 |
| `.github/workflows/repackage-hummer.yml.disabled` | 旧 safety 重打包 |
| `.github/workflows/build.yml.disabled` | 上游通用 GKI 构建 |
| `.github/workflows/module.yml.disabled` | 上游通用 module zip |
| `.github/workflows/sync-upstream.yml.disabled` | 危险的自动 sync（会覆盖本地 6.6 修改） |

如果 Actions 列表里还残留它们的旧 run，忽略即可。

---

## 三、一句话选择

```text
要 phDroid（上游 _patchHarmony）
  ├─ 正常构建 → [phDroid] Build from OTA (upstream _patchHarmony)
  ├─ 只重打包 → [phDroid] Repackage normal/safe
  └─ 固定旧内核 → [phDroid] Build pinned kernel (20261030)

要 Shikochin（第二套实现）
  └─ [Shikochin] Build from OTA

上游更新了
  └─ 手动合并上游源文件，不要跑自动 sync
```

---

## 四、产物命名

| Workflow | Artifact / Release |
|---|---|
| `[phDroid] Build from OTA` | `phdroid-ota-<run_id>` / `phDroid-v2.0.0-hummer.zip` |
| `[phDroid] Build pinned` | `phdroid-upstream-<run_id>` |
| `[phDroid] Repackage` | `phdroid-upstream-safe-<run_id>` 或 normal |
| `[Shikochin] Build from OTA` | `droidspaces-hummer-<run_id>` / `Droidspaces-LKM-hummer-*.zip` |

安全包只加载 `droid_lkm`，不加载 `droid_lkm_vendor`；
正常包两个都加载。第一次测试建议先装 safe 包。
