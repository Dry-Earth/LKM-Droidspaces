# Droidspaces LKM hummer (6.6)

这是 `third_party/shikochin-lkm` 的 hummer 打包层：把
[Shikochin/Droidspaces-LKM](https://github.com/Shikochin/Droidspaces-LKM)
的 PID/IPC namespace 移植编译到一加 Ace 5 Pro（hummer）的精确内核
`6.6.144-4k-g6350e8af3f4c` 上。

## 默认行为

- 首次安装**不会自动加载**，需要手动：

```sh
su -c 'sh /data/adb/modules/droidspaces_hummer/service.sh load'
```

- 状态：

```sh
su -c 'sh /data/adb/modules/droidspaces_hummer/service.sh status'
su -c 'cat /data/adb/droidspaces_hummer/load.log'
```

- 稳定后开启自启：

```sh
su -c 'mkdir -p /data/adb/droidspaces_hummer; touch /data/adb/droidspaces_hummer/auto'
```

- 清除 blocked / crash：

```sh
su -c 'sh /data/adb/modules/droidspaces_hummer/service.sh reset'
```

## WebUI

模块包含 `webroot/`，在 KernelSU / APatch 的模块页面点 **打开 WebUI** 即可：

- 显示 namespace 是否激活、内核 / 目标 release、USER_NS 变体状态、
  原生 USER_NS 检测、blocked 状态；
- 按钮：刷新、重试加载（reset + load）、清空日志；
- 日志读取 `/data/adb/droidspaces_hummer/load.log`。

WebUI 通过 KernelSU 的 `ksu.exec` 调用 `service.sh`；没有 WebUI API 的
管理器会提示不可用，不影响命令行加载。

## 不能和 phDroid 同时用

两套模块都会接管 PID / IPC namespace。安装器检测到已启用的 phDroid 会直接
中止；如果已经装过，请先在 KernelSU 里停用 phDroid 并重启。

## 载荷

- `droidspaces_ns.ko`：PID / IPC / SYSVIPC / POSIX mqueue（必须）
- `droidspaces_ns_userns.ko`：额外的 USER_NS 沙箱（只有构建成功且 `userns=1` 时使用）
- `droidspaces_devtmpfs.ko`：容器 `/dev` 设备节点（可选）
- `droidspaces_netfilter.ko`：Docker nftables / xt_addrtype（6.12 源码，6.6 默认不构建）

`config.conf` 里可以逐项开关；修改后重启生效。

## 回滚

1. KernelSU 里停用模块 → 重启。
2. 确认 `grep droidspaces_ns /proc/modules` 无输出。
3. 删除 `/data/adb/modules/droidspaces_hummer` 和 `/data/adb/droidspaces_hummer`。

如果开机卡住：KernelSU 安全模式（开机按住音量下），或 recovery 删除上述目录。

## 来源

- 上游源码：`third_party/shikochin-lkm`（GPL-2.0，Shikochin）
- 构建：GitHub Actions `Build hummer Droidspaces-LKM (Shikochin port)`
