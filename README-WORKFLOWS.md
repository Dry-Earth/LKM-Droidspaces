# Workflow 导航：该点哪一个？

本仓库只有一套内核模块实现：

| 实现 | 模块 ID | 源码 | 说明 |
|---|---|---|---|
| **phDroid** | `phdroid` | `src/`（上游 `Dere3046/_patchHarmony` + 本 fork 修改） | 默认同时编入 `main` + `native` 两套 PID 后端 |

---

## 一、最常用的入口

### 手动填 OTA 链接，自动构建（推荐）

**Actions → `[phDroid] Build from OTA (upstream _patchHarmony)`**

- 文件：`.github/workflows/build-hummer-ota.yml`
- 输入：
  - `boot_img_url`：OTA 的 `boot.img`
  - `manifest_url`：OTA 的 `build-manifest.xml`
  - `safe_mode`
  - `publish_release`
- 自动解析 OTA 的 kernel/modules/clang revision，从 boot.img 提取 config/release/clang，然后编 **native + main 双后端**、打包。
- 当前 20261113 OTA 已跑通。

### PID 后端（`pid_impl`）

最近的两个 phDroid 构建（OTA 和 pinned）都带 `DROID_LKM_PID_BOTH=1`：

| 后端 | 说明 | 切换 |
|---|---|---|
| `main` | 旧实现，默认 | 不写 `pid_impl` 即为 `main` |
| `native` | 6.6 新实现 | `config.conf` 写 `droid_lkm=pid_impl=native` |

`pid_impl` 是 **insmod 参数**（加载后不可改），切换需要停容器、`rmmod droid_lkm`、改 config、重新 `service.sh load`。

> 已知问题：App 终端退出时手机会硬重启，`main` / `native` 都复现，`dontaudit` 补丁也不能解决。
> 当前定位在 `__tty_hangup -> tty_signal_session_leader` 的 `tasklist_lock` 死锁：
> https://github.com/Dere3046/_patchHarmony/issues/15

### 只想重新打一个 normal/safe 包（不重编内核）

**Actions → `[phDroid] Repackage normal/safe`**

- 文件：`.github/workflows/repackage-upstream.yml`
- 输入：
  - `run_id`：之前成功的 phDroid 构建 run ID
  - `artifact_prefix`：OTA 构建填 `phdroid-ota`；固定构建填 `phdroid-upstream`
  - `safe_mode`
- 适合只改 `module/` 脚本或 WebUI 时快速出包。

### 上游更新了怎么办

不要自动 sync。自动 sync 会 `git reset --hard` 到上游树，把 fork 里的 6.6 修改全部覆盖掉。

正确做法是：

1. 看上游新提交（例如 `f8bdeddd`）；
2. 只把涉及的源文件合进来，保留 `module/`、`webroot/` 的本地修改；
3. 再跑 `[phDroid] Build from OTA`。

这个 fork 已经按这种方式同步过 `dfae0675` 和 `f8bdeddd`，不需要再跑自动 sync。

> `f8bdeddd` 是 IPC layout/BTF 重构（17 个文件）；`ds_slot.c` 保留 6.6 版本，
> 没有合并 `e9b18854` 里给 5.15 用的 `do_exit` 重复清理钩子（6.6 的
> `exit_task_namespaces` 不是内联的，加了会重复 cleanup）。

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
| `.github/workflows/build.yml.disabled` | 上游通用 GKI 构建 |
| `.github/workflows/module.yml.disabled` | 上游通用 module zip |

如果 Actions 列表里还残留它们的旧 run，忽略即可。

---

## 三、一句话选择

```text
要 phDroid（上游 _patchHarmony）
  ├─ 正常构建 → [phDroid] Build from OTA (upstream _patchHarmony)
  ├─ 只重打包 → [phDroid] Repackage normal/safe
  └─ 固定旧内核 → [phDroid] Build pinned kernel (20261030)

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

安全包只加载 `droid_lkm`，不加载 `droid_lkm_vendor`；
正常包两个都加载。第一次测试建议先装 safe 包。
