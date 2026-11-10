# Shikochin Droidspaces-LKM 移植（hummer / 6.6.144）

本目录把 [Shikochin/Droidspaces-LKM](https://github.com/Shikochin/Droidspaces-LKM)
作为**第二套独立实现**引入本项目，目标是一加 Ace 5 Pro（`hummer`）的精确内核：

```text
6.6.144-4k-g6350e8af3f4c
SMP preempt mod_unload modversions aarch64
```

源码固定在：

```text
third_party/shikochin-lkm/          # 上游完整源码（GPL-2.0）
kernelsu-shikochin-hummer/          # 本项目的 KernelSU 打包层
ci/build-shikochin-hummer.sh        # 用精确 KDIR 编译
ci/package-shikochin-hummer.py      # 生成 KernelSU ZIP
.github/workflows/build-hummer-shikochin.yml
```

> 这**不是** phDroid。模块 ID 是 `droidspaces_hummer`，和现有
> `phdroid` 模块不能同时启用；安装器检测到已启用的 phDroid 会直接中止。

---

## 1. 已移植的功能

| 功能 | 来源 | hummer 6.6 状态 |
|---|---|---|
| PID namespace | `src/port66` | 构建并加载（核心） |
| IPC namespace / SysV IPC / POSIX mqueue | `src/port66` | 构建并加载（核心） |
| PID 引用生命周期（perf / FUSE / cgroup-v1 / BPF iterator） | `src/port66` | 随主模块构建 |
| 容器 reboot / memfd namespace 策略 | `src/port66` | 随主模块构建 |
| devtmpfs | `src/devtmpfs` | 可选，默认构建；构建失败自动跳过 |
| USER_NS 沙箱 | `src/userns` | **6.6 核心子集可构建**（可选 `droidspaces_ns_userns.ko`）；mount/super/identity/FUSE 仍为 6.12-only，默认不构建 |
| Docker nftables / xt_addrtype | `src/netfilter` | **上游是 6.12 nf_tables 快照**；6.6 默认不构建 |
| 厂商 PID 引用泄漏修复 | `src/compat` | PLZ110 专用；hummer 未启用 |
| 加载前 ABI / 指纹检查 | `src/abi` + KernelSU 脚本 | 本项目用“精确 KDIR + 完整 release + vermagic + SHA-256”替代 |
| 多 KMI 选择 | `kernelsu/` | hummer 单目标，不做多载荷路由 |

### 为什么 userns / netfilter 在 6.6 上仍有限制

上游的 USER_NS live port 依赖 6.12 的 `statmount` / `listmount`、FUSE 和
mount namespace 内部接口。6.6 版本目前只移植了**核心子集**：

- 已包含：userns/cred/ucounts/utsname、proc uid_map/gid_map、capabilities、
  setuid/setgid/setresuid/setfsuid/setgroups（含 LSM fix-setid 路径）、
  exec/mm 凭据、stat/faccessat/chown、cgroup/time/sysfs、socket/scm/unix/netlink、
  superblock 所有权（alloc_super/sget/destroy）、mount namespace 所有权
  （alloc_mnt_ns/free_mnt_ns/mnt_may_suid）；
- 仍排除：`live-fuse*.c`（FUSE idmapping 内部）和 6.8+ 才有的
  `statmount/listmount` 系统调用。

因此 6.6 的 userns 变体**不是安全边界**：FUSE 和 statmount 仍未接管，
容器内的 FUSE 挂载行为可能与原生 USER_NS 内核不同。需要真正隔离时优先走
原生内核路线（`hummer-lineage-kernel-build` 的 v3+USER_NS boot.img）。

netfilter 仍然直接携带 6.12 的 `nf_tables` 快照，6.6 默认不构建。

所以本移植的策略是：

1. **namespace + devtmpfs 先落地**，这是 Droidspaces rootful 容器真正需要的；
2. userns 核心子集单独构建为 `droidspaces_ns_userns.ko`，默认关闭；
3. 构建成功才打包，失败写 `out-shikochin/build-report.txt`，不会静默假装支持；
4. userns 载荷在 CI 里对**精确 KDIR 的 vmlinux** 做静态预检（符号存在 +
   前 4 条指令可打补丁），运行时 `ds_hooks_prepare()` 再预检一次；任何一项
   不通过都拒绝加载，不写任何补丁；
5. README 和模块简介明确写出当前能力，不把“源码在仓库里”说成“6.6 已可用”。

---

## 2. 和 phDroid 的关系

| 项目 | phDroid（现有） | 本项目新增 |
|---|---|---|
| 源码 | `_patchHarmony` / `src/main` | Shikochin `src/port66` |
| 模块 ID | `phdroid` | `droidspaces_hummer` |
| PID 后端 | upstream native PID | Shikochin 6.6 port |
| devtmpfs | 默认不构建 | 可选构建 |
| USER_NS | 伪造，默认关闭 | 6.6 核心子集（可选 userns 变体），默认关闭 |
| 加载策略 | `auto` 文件 opt-in | `auto` 文件 opt-in + 崩溃保护 |
| 同时启用 | **禁止** | **禁止** |

切换方法：

```sh
# 1. KernelSU 里停用 phDroid，重启
# 2. 确认 droid_lkm 不在内核里
su -c 'grep -E "^droid_lkm" /proc/modules'
# 3. 安装 droidspaces_hummer 的 ZIP
# 4. 手动加载一次
su -c 'sh /data/adb/modules/droidspaces_hummer/service.sh load'
```

---

## 3. 构建

GitHub → **Actions** → **Build hummer Droidspaces-LKM (Shikochin port / OTA)**
→ Run workflow。

默认 `use_ota=true`，和 `build-hummer-ota.yml` 一样只需要两个 URL：

| 参数 | 默认 | 说明 |
|---|---|---|
| `use_ota` | ✅ | 从 OTA 自动解析；关闭则用仓库固定 SHA |
| `boot_img_url` | 20261106 OTA | OTA 的 `boot.img` |
| `manifest_url` | 20261106 OTA | OTA 的 `build-manifest.xml` |
| `publish_release` | ✅ | 成功后自动发 Release |
| `build_devtmpfs` | ✅ | 构建 `droidspaces_devtmpfs.ko` |
| `build_netfilter` | ❌ | 尝试 6.12 nf_tables 快照；6.6 大概率失败 |
| `build_userns` | ❌ | 构建 USER_NS 6.6 核心子集；静态 + 运行时预检不通过则不打包 |

OTA 模式流程（与 phDroid 的 OTA 工作流一致）：

1. 下载 `build-manifest.xml`，解析 kernel / modules / devicetrees / clang 的精确 revision；
2. 下载 `boot.img`，用 `magiskboot unpack` 取出 `Image`；
3. 从 Image 提取 `.config`、完整 `Linux version` 和 `based on rXXXXX` 编译器版本；
4. 按内核 `major.minor` 选 KMI（6.6 → `android15-6.6`）；
5. 下载 manifest 对应的 clang，编出精确 KDIR；
6. 用 `ci/build-shikochin-hummer.sh` 编译 Shikochin 的 `src/port66`；
7. 用 `ci/package-shikochin-hummer.py` 打包。

`use_ota=false` 时退回仓库里固定的
`6.6.144-4k-g6350e8af3f4c` / kernel `6350e8af...` / config `hummer_config.gz`。

产物：

- `Droidspaces-LKM-hummer-v0.1.0-hummer.zip`
- 独立 `.ko`（namespace / devtmpfs / 可选 netfilter / 可选 userns）
- `SHA256SUMS`
- `build-report.txt`（每个载荷 ok / failed / skipped）
- Release tag：`droidspaces-hummer-<run_id>`

---

## 4. 安装与验证

1. KernelSU / KernelSU Next / SUKISU → 模块 → 安装 ZIP。
2. 重启。首次安装**不会自动加载**。
3. 手动加载：

```sh
su -c 'sh /data/adb/modules/droidspaces_hummer/service.sh load'
```

4. 看状态：

```sh
su -c 'sh /data/adb/modules/droidspaces_hummer/service.sh status'
su -c 'cat /data/adb/droidspaces_hummer/load.log'
su -c 'grep -E "^droidspaces_(ns|devtmpfs|netfilter)" /proc/modules'
su -c 'ls -l /proc/self/ns'
su -c 'dmesg | grep -iE "droidspaces|CFI failure|Unknown symbol" | tail -50'
```

5. 启动容器 → 停止 → 再启动，连续 3 次。
6. 稳定后开启自启：

```sh
su -c 'mkdir -p /data/adb/droidspaces_hummer; touch /data/adb/droidspaces_hummer/auto'
```

> 自动加载后有 120 秒存活窗口。加载后 2 分钟内不要重启，否则会被判定为
> “加载后崩溃”并 `blocked`。可改短：
> `echo 30 > /data/adb/droidspaces_hummer/alive_sec`。

### 可选：USER_NS 6.6 变体（实验）

仅在 zip 内包含 `droidspaces_ns_userns.ko` 时可用。它替换的是核心凭据 /
ucounts / proc / capabilities / exec / mm 路径，**仍然不是安全沙箱**。

1. 确认当前是 **stock boot**（`CONFIG_USER_NS=n`）；不要和 v3+USER_NS boot.img
   同时使用。加载器检测到 `/proc/self/uid_map` 已存在会直接拒绝。
2. 把 `config.conf` 的 `userns=1`，保持 `auto` 关闭，重启后手动加载：

```sh
su -c 'sh /data/adb/modules/droidspaces_hummer/service.sh load'
su -c 'cat /data/adb/droidspaces_hummer/load.log'
```

3. 日志应出现：

```text
userns: ... preserves N native entries, adds 4 mapping entries
entry preflight passed: ... functions ...
experimental namespace hooks active
```

如果预检失败，`insmod` 会返回错误且**不会写入任何补丁**；这是预期失败，
保留 `load.log` 和 `dmesg` 即可。
4. 基础验证：

```sh
su -c 'cat /proc/self/uid_map; cat /proc/self/gid_map'
su -c 'unshare -U -r sh -c "id; cat /proc/self/uid_map"'
```

5. 连续启动/停止容器 3 次；出现 panic/卡死时脚本会在两次异常后 `blocked`，
   pstore 会保存在 `/data/adb/droidspaces_hummer/pstore/`。

### 状态含义

| 简介 | 含义 |
|---|---|
| `[待加载]` | 本次开机未加载（默认，或等待 service） |
| `[已加载]` | namespace 激活，可选模块按配置加载 |
| `[部分加载]` | namespace 激活，但 devtmpfs/netfilter 有失败项 |
| `[加载失败]` | insmod / activate 检查失败，或已 blocked |
| `[不兼容]` | 内核 release / vermagic / SHA-256 不匹配，或检测到 phDroid |

### 常用命令

```sh
su -c 'sh /data/adb/modules/droidspaces_hummer/service.sh status'
su -c 'sh /data/adb/modules/droidspaces_hummer/service.sh reset'
su -c 'sh /data/adb/modules/droidspaces_hummer/service.sh load'
su -c 'cat /data/adb/droidspaces_hummer/load.log'
```

已激活的模块**不能热卸载**：

```sh
su -c 'sh /data/adb/modules/droidspaces_hummer/service.sh unload'
# 只会提示：请禁用模块后重启
```

---

## 5. 配置

模块目录：`/data/adb/modules/droidspaces_hummer/config.conf`
数据目录：`/data/adb/droidspaces_hummer/`

```ini
namespace=1    # 主模块（必须）
devtmpfs=1     # 容器 /dev；没有对应 .ko 时打包器会自动改成 0
netfilter=0    # Docker nftables；6.6 默认不构建
userns=0       # USER_NS 变体（需 droidspaces_ns_userns.ko）；默认关闭，不能与原生 USER_NS 内核同时使用
```

修改后重启生效。

---

## 6. 已知限制

- 本移植**还没有在 hummer 真机上验证**；当前只完成源码集成、精确 KDIR 构建链和
  KernelSU 打包。第一次安装请保留手动加载，先看 `load.log`。
- USER_NS 6.6 变体只覆盖核心子集，**不是安全沙箱**：FUSE idmapping 和
  statmount/listmount 仍未接管；不要把不可信进程放进去。
- 原生 USER_NS 内核（v3+USER_NS boot.img）与 LKM userns 变体**不能同时使用**；
  加载器检测到 `/proc/self/uid_map` 已存在会直接拒绝。
- netfilter 是 6.12 `nf_tables` 快照，6.6 默认不构建；需要 Docker NAT/nftables
  时优先用原生内核打开 `CONFIG_NF_TABLES` / `CONFIG_NETFILTER_XT_MATCH_ADDRTYPE`。
- 主模块使用未导出符号和入口替换；**只对完整 release
  `6.6.144-4k-g6350e8af3f4c` 生效**。OTA 后 release 变了会被拒绝加载。
- 不能和 phDroid 同时加载；两套 PID/IPC namespace 钩子会冲突。
- 容器 root 仍然等于宿主 root（没有真正的 USER_NS 隔离）。

---

## 7. 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| `[不兼容]` | 内核 release 不是 `6.6.144-...` | OTA 后需要重跑工作流；不要放宽检查 |
| `vermagic mismatch` | 用了别的 KDIR / 别的机型包 | 用本工作流产出的 ZIP |
| `CFI failure` | clang 与内核不匹配 | 确认构建日志是 r596125 |
| `Unknown symbol` | 6.6.144 与 6.6.127 的未导出符号集合不同 | 看具体符号，可能需要在 `src/port66` 补 shim |
| `[不兼容] phDroid` | 两套 namespace 同时存在 | 停用 phDroid 并重启 |
| 加载后卡死 / 关机 | namespace 退出路径或 vendor 布局不匹配 | 进 KernelSU 安全模式；保留 pstore；先回到 phDroid |
| `droidspaces_devtmpfs` 加载失败 | 内核已有 devtmpfs 或 API 差异 | 把 `devtmpfs=0`，主模块仍可跑容器 |

pstore 会保存在 `/data/adb/droidspaces_hummer/pstore/`，保留最近 3 份。

---

## 8. 来源与许可

- 上游：[Shikochin/Droidspaces-LKM](https://github.com/Shikochin/Droidspaces-LKM)
  （GPL-2.0），完整源码在 `third_party/shikochin-lkm/`，保留原始 `LICENSE`、
  `ORIGIN`、测试与文档。
- 本移植只修改了：
  - `src/gki-target.h`：接受精确 hummer release；
  - `src/devtmpfs/main.c` / `src/netfilter/main.c`：设备检查改为精确 release；
  - `Makefile`：新增 `HUMMER=1` 构建开关；
  - 新增 `src/ds-hummer.h`。
- 上游的 `kernelsu/`、`kernelsu-plz110/` 保留作参考；本项目实际使用的是
  `kernelsu-shikochin-hummer/`。
- KernelSU 模块打包层、构建工作流、中文文档由本项目维护。

上游作者没有参与本移植；真机问题请先在本项目排查，不要直接打扰上游。
