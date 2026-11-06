# phDroid (patchHarmony) LKM for OnePlus Ace 5 Pro (hummer)

在**原厂 LineageOS 24.0 内核**上补 Droidspaces / 容器所需的
PID / IPC / SYSVIPC / POSIX mqueue 能力，不刷内核、不改 App。

本仓库是 [`Dere3046/_patchHarmony`](https://github.com/Dere3046/_patchHarmony)
（XiYueSauce 的 phDroid 打包）的 fork，目标改成：

| 项目 | 值 |
|---|---|
| 机型 | 一加 Ace 5 Pro（代号 `hummer`） |
| 系统 | LineageOS 24.0（20261030） |
| 内核 | `6.6.144-4k-g6350e8af3f4c` |
| 内核 commit | `6350e8af3f4c452d087fbd6fe1aabe03cbc0af75` |
| KMI | `android15-6.6` |
| 原厂编译器 | clang r596125（`clang version 22.0.2`） |

---

## ⚠ 停止 / 重启容器时关机：已知问题

### 症状

容器能启动、能进入；但在 App 里点**停止**或**重启**容器时：

1. 整机先卡住，点什么都没反应；
2. 过一会儿黑屏 / 关机（或自动重启）。

这不是普通 App 崩溃，而是内核在**销毁容器命名空间**时挂死，
硬件看门狗随后接管。

### 最可能的原因

旧构建用的是 DDK 自带的 `android15-6.6` KDIR（`6.6.127`）和 clang r510928，
而设备实际运行的是 **`6.6.144` + 原厂 clang r596125**。

即使 `insmod` 能过，模块编译时看到的 `struct` 布局、`Type_info` 锚点、
导出符号集合仍可能和运行内核有差异。容器停止时，模块要释放伪造的
PID/IPC namespace、SysV 对象和 nsproxy 引用；一旦布局/引用计数对不上，
就会踩坏内核内存 → 卡死 → 看门狗关机。

### 本仓库的修复

`.github/workflows/build-hummer-lkm.yml` 不再用 DDK 的通用 KDIR，而是：

1. 检出精确内核 commit `6350e8af...`；
2. 用 `config/hummer_config.gz`（从官方 boot.img 提取的真实 config）
   编出 **6.6.144 的 KDIR**（`Module.symvers` / `System.map` / `utsrelease.h`）；
3. 用**原厂 clang r596125** 编译 `droid_lkm.ko` / `droid_lkm_vendor.ko`；
4. 打包时把 KMI 锁定为 `android15-6.6`，并写入 hummer 专用配置。

这样模块的 vermagic、结构体布局、KCFI 和运行内核一致，是解决
“停止/重启关机”的第一优先级修复。

### 如果新包仍然关机：用 safe_mode 定位

工作流有 `safe_mode` 参数。打开后会生成 `-safe` 包：

```ini
skip_do_exit=1     # 不注册 do_exit kprobe
compat=off         # 不加载 OPPO vendor 兼容模块
```

- **safe 包不再关机** → 问题在 `do_exit` 退出路径或 vendor 钩子，
  可以继续缩小范围。
- **safe 包仍然关机** → 问题在 nsproxy / IPC ns 的释放路径，
  需要抓 pstore 后再改代码。

### 抓崩溃现场

```sh
su -c 'ls -l /sys/fs/pstore/'
su -c 'cat /sys/fs/pstore/console-ramoops* 2>/dev/null | tail -100'
su -c 'dmesg | tail -100'
su -c 'cat /data/adb/modules/phdroid/phdroid.log'
```

把 `console-ramoops` 里最后 100 行发出来，才能判断是
`BUG:`、`Unable to handle kernel paging request`、还是
`watchdog` 超时。

### 上游经验（ai-luo2006）

上游 `droidspaces-6.12-pmb110` 的 README / CHANGELOG 记录过类似问题：

- v1.0.18 在 `kernel_clone` 里换 cred → **两次整机重启**，v1.0.19 删除该路径；
- v1.0.15 增加卸载引用检查，防止 `rmmod` 时 ns 对象被引用 → UAF；
- 6.6 内核在它的支持矩阵里是“**可构建，未真机验证**”，
  6.12 才是真机验证过的。

所以 6.6.144 上的停止/重启关机，首先是**构建目标不匹配**，
其次才可能是核心代码在 6.6 上的 teardown 竞态。

### 不要做的事

| 别做 | 原因 |
|---|---|
| 容器还在跑时 `rmmod droid_lkm` | ns 对象仍被引用，UAF / panic |
| 反复刷不同 KMI 的 ko | vermagic / 布局不匹配，越试越乱 |
| 用 DDK 的 `android15-6.6` KDIR 直接编 | 6.6.127 ≠ 6.6.144 |
| 把 `skip_do_exit=1` 当长期方案 | 命名空间可能泄漏，只用于定位 |

---

## 一键构建

GitHub → **Actions** → **Build hummer phDroid module (LineageOS 24 / 6.6.144)** → Run workflow。

| 参数 | 默认 | 说明 |
|---|---|---|
| `publish_release` | ✅ | 成功后自动发 Release |
| `safe_mode` | ❌ | 打开后生成 `-safe` 包（`skip_do_exit=1` + `compat=off`） |

耗时约 **25–35 分钟**（含精确 KDIR 构建；ccache 命中后会快很多）。

产物：

- Artifacts：`phdroid-hummer-<run_id>`（zip + ko + build-info）
- Release：`phDroid-v1.0.4-hummer.zip` 或 `...-safe.zip`

### 本次构建结果（安全兜底版）

以下两个包是用已经验证过 clang/Kdir 的 ko（run `42223499194`）重新打包的，
只有 `module/` 脚本更新，ko 没变。

**正常包：**

- Release：https://github.com/Dry-Earth/LKM-Droidspaces/releases/tag/phdroid-hummer-safety-42236045133
- zip：`phDroid-v1.0.4-hummer.zip`（2.8 MB）
- sha256：`58677db835dc1bba346c9a487afeeb554e765687a191e7a6482c3ebe31b2776b`

**安全模式包（`skip_do_exit=1` + `compat=off`）：**

- Release：https://github.com/Dry-Earth/LKM-Droidspaces/releases/tag/phdroid-hummer-safety-42236240331
- zip：`phDroid-v1.0.4-hummer-safe.zip`
- sha256：`7d0c67d051f44f9b2b0798a1342ecfcda6beec473bfa6afb62ee6df81d3c5ad2`

两个包的 ko 都是：

```
vermagic=6.6.144-4k-g6350e8af3f4c SMP preempt mod_unload modversions aarch64
```

> 更早的 `phdroid-hummer-42223499194` / `42228372442` 是旧打包脚本，
> 没有 no_boot / 存活窗口 / crash_count，已被这两个 safety 包取代。

### 安全兜底行为

新包的 `service.sh` 增加了这些逻辑：

| 机制 | 行为 |
|---|---|
| `no_boot` | **首次安装默认存在**，开机不自动加载 |
| 手动 load | `PH_ACTION=load sh .../service.sh`，绕过 no_boot/blocked |
| 存活窗口 | 自动加载后等 120 秒；期间没崩才写 `.boot_ok` |
| 上次加载后崩 | `boot_pending` 还在、`.boot_ok` 不在 → 下次开机 `blocked` |
| 崩溃计数 | `ro.boot.bootreason` 为 `watchdog` / `kernel_panic` / `panic` 时 +1；≥2 自动 `blocked` |
| pstore | 每次开机把 `/sys/fs/pstore` 复制到 `.../phdroid/pstore/`，保留最近 3 份 |
| build-id | 记录 release / kernel sha / config sha；OTA 后 release 不匹配直接拒绝加载 |

常用命令：

```sh
# 状态
su -c 'sh /data/adb/modules/phdroid/service.sh status'

# 手动加载一次（首次安装后必须做）
su -c 'PH_ACTION=load sh /data/adb/modules/phdroid/service.sh'

# 清除 blocked / crash_count / boot_pending（确认要重新试时）
su -c 'sh /data/adb/modules/phdroid/service.sh reset'

# 验证稳定后，删掉 no_boot 才会开机自动加载
su -c 'rm /data/adb/modules/phdroid/no_boot'
```

> 自动加载后的存活窗口默认 120 秒。**加载后 2 分钟内不要重启**，
> 否则 `boot_pending` 还在、`.boot_ok` 没写，下次会被误判为“加载后崩溃”。
> 可以把窗口改短：`echo 30 > /data/adb/modules/phdroid/alive_sec`。

WebUI 的「加载」按钮已改成：

```sh
sh service.sh reset; PH_ACTION=load sh service.sh
```

所以安装后可以直接在 WebUI 里手动加载，不需要先删 `no_boot`。

---

## 安装

1. 先卸载/停用旧版 `phDroid`，重启一次（避免两个模块同时加载）。
2. KernelSU / KernelSU Next / SUKISU → 模块 → 安装 zip。
3. **重启**。首次安装会生成 `no_boot`，所以这次**不会自动加载**。
4. 手动加载一次：

```sh
su -c 'PH_ACTION=load sh /data/adb/modules/phdroid/service.sh'
```

   也可以在 WebUI 点「加载」；按钮已经改成 `reset + load`。

5. 看日志：

```sh
su -c 'sh /data/adb/modules/phdroid/service.sh status'
su -c 'cat /data/adb/modules/phdroid/phdroid.log'
su -c 'grep -E "^droid_lkm" /proc/modules'
su -c 'dmesg | grep -iE "droid_lkm|CFI failure|Unknown symbol" | tail -50'
```

6. 启动一个容器，确认能进；再点**停止**、再**启动**，连续 3 次。
7. 如果稳定，再删掉 `no_boot`，下次开机才会自动加载：

```sh
su -c 'rm /data/adb/modules/phdroid/no_boot'
```

> 第一次测试建议先装 **safe 包**：如果 safe 包不关机，再用正常包；
> 这样能把问题范围缩到 `do_exit` / vendor 钩子。
> 手动加载不会走 120 秒存活窗口，所以适合“先试一次”。

---

## 配置

模块目录：`/data/adb/modules/phdroid/`，改完 `config.conf` 后重启生效。

```ini
kmi=android15-6.6
kmi_override=android15-6.6
oplus=1
compat=on          # OPPO vendor 兼容；排查时可改 off
skip_do_exit=0     # 排查时可改 1（不注册 do_exit kprobe）
skip_sysvipc=0
no_fake_ns=0
mqueue=1
nspid=1
nspid_append=1
verbose=0
```

`skip_do_exit=1` 和 `compat=off` 只用于定位，不建议长期使用。

---

## 验证

```sh
# 1. 模块在线
grep -E '^droid_lkm' /proc/modules

# 2. 没有 CFI / Unknown symbol
dmesg | grep -iE 'CFI failure|Unknown symbol'

# 3. 容器能启动、能停止（关键）
#    App 里 start -> stop -> start，连续 3 次

# 4. Droidspaces 自检
su -c 'droidspaces check'
```

`user namespace` 那一项在 6.6 上仍然是红的，属预期；
容器 root 就是宿主 root，不要当安全沙箱。

---

## 回滚 / 卸载

1. KernelSU 里停用模块 → 重启。
2. 确认 `/proc/modules` 里没有 `droid_lkm`。
3. 删除 `/data/adb/modules/phdroid`。

如果开机卡住：KernelSU 安全模式（开机按住音量下），或 recovery 删除该目录。

---

## 目录结构

```
.github/workflows/build-hummer-lkm.yml  # hummer 专用构建
ci/build-kdir.sh                        # 精确 6.6.144 KDIR
ci/build-lkm.sh                         # 编译 droid_lkm / vendor
ci/patch-package.sh                     # 写入 hummer 配置 / safe mode
config/hummer_config.gz                 # 从官方 boot.img 提取的 config
module/                                 # phDroid 打包脚本 / service.sh
src/                                    # patchHarmony 内核模块源码
```

---

## 鸣谢

- **[XiYueSauce](https://github.com/XiYueSauce) / [Dere3046](https://github.com/Dere3046)**
  — `_patchHarmony` / phDroid 的原始实现与打包。
- **[ai-luo2006](https://github.com/ai-luo2006)** —
  `droidspaces-6.12-pmb110` 的 README、CHANGELOG、6.12 真机验证与
  停止/重启问题分析，本仓库的排查思路大量参考了它。
- **[ravindu644](https://github.com/ravindu644)** — Droidspaces 本体与 GKI kABI 补丁。
- **[Ylarod](https://github.com/Ylarod)** — DDK 工具链镜像。
- **LineageOS** — hummer 内核源码与官方 boot.img。

没有这些上游工作，这个 fork 不可能存在。
