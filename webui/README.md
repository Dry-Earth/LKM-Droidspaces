# phDroid WebUI 使用说明

这个页面是 KernelSU / APatch 模块页里的 WebUI，源码在上游 `webui/`，
构建时以 `main-native` flavor 编进 `module/webroot`。

它读写的路径：

| 路径 | 内容 |
|---|---|
| `/data/adb/modules/phdroid` | 模块目录（`bin/<KMI>/*.ko`、`config.conf`、`service.sh`） |
| `/data/adb/phdroid` | 运行状态（`auto`、`blocked`、`phdroid.log`、WebUI 保存的 `config.conf`） |

> 注意：WebUI 保存配置写的是 `/data/adb/phdroid/config.conf`。
> `service.sh` 现在优先读这个文件，其次才读模块目录里的 `config.conf`。

---

## 页面

### 概览（Overview）

- 模块版本、内核 release、KMI
- 已加载的模块（`/proc/modules`）
- 自动加载状态、是否被 blocked、上次加载结果
- 快捷操作：
  - **开启/关闭自动加载** → 写/删 `/data/adb/phdroid/auto`
  - **解除阻断** → 删除 `blocked` / `insmod`

这些操作和 `service.sh` 完全对应，可以放心用。

### 参数（Params）

这里显示的是：

- `/sys/module/droid_lkm/parameters/*`
- `/sys/module/droid_lkm_vendor/parameters/*`

**这些是 insmod 参数，权限是 0444，加载后不能改。**
页面上改了也不会生效，必须：

1. 停掉容器
2. 重启手机（或手动 `rmmod` 后重新 `service.sh load`）

配置本身（`modules=`、`droid_lkm=`、`droid_lkm_misc=` 等）改的是
`/data/adb/phdroid/config.conf`，保存后点 **Install/Apply**，再重启加载。

### 日志（Logs）

读取 `/data/adb/phdroid/phdroid.log`，也就是 `service.sh` 的加载日志。
排查“模块没加载”“insmod 失败”先看这里。

### Features

读取 `/proc/droid_lkm/features`，内容是 `droid_lkm` 的：

- IPC / mqueue / SYSVIPC / compat32 的 owner
- layout 校验结果
- 每个 hook 的路由（text / kprobe / slot）和状态
- PID namespace 后端（`main` / `native` / `both`）

`droid_lkm_misc`（userns）和 extras 不在这个文件里，分别看：

```bash
su -c 'dmesg | grep -iE "droid_lkm_misc|userns"'
su -c 'lsmod | grep -E "devtmpfs|macvlan|ip6table|droid_lkm_pids|droid_lkm_cpu"'
```

---

## 用不到 / 容易误解的地方

| 项目 | 说明 |
|---|---|
| Params 页的输入框 | 参数是加载时固定的，改了不起作用；要改就改 `config.conf` 后重启 |
| PID backend 切换 | 只有包里同时编了 `main` + `native` 才有意义；切换必须重启加载 |
| 开发模拟数据 | `webui/src/api/mock.ts` 只在浏览器调试时用，真机不会走 |
| flavor | 我们固定用 `main-native`，不需要切换 |

---

## 推荐操作顺序

1. **首次**：装 zip → 重启 → 概览页确认“已加载”
2. 要改配置：
   - 停容器
   - Params/Config 页修改并保存
   - 点 Install/Apply（写入 `/data/adb/phdroid/config.conf`）
   - 重启手机
3. 要自动加载：概览页打开“自动加载”
4. 出问题：
   - 看 Logs 页
   - `dmesg | grep -i phdroid`
   - 必要时点“解除阻断”，再手动 `service.sh load`

---

## 和模块脚本的对应关系

| WebUI 操作 | 实际执行 |
|---|---|
| 保存配置 | 写 `/data/adb/phdroid/config.conf` |
| Install/Apply | `service.sh install`（复制配置到 DATA） |
| 开启自动加载 | `touch /data/adb/phdroid/auto` |
| 解除阻断 | `rm -f blocked insmod` |
| 读取状态 | 直接读 `/proc/modules`、sysfs、config、`/proc/droid_lkm/features` |
