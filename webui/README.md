# phDroid WebUI 使用说明

## 实际发布的是哪个页面

发布包里用的是 **`module/webroot/index.html` + `module/webroot/main.js`**：

- 经典 `<script src="main.js">`，通过 `window.ksu.exec` 调 `service.sh`
- 不依赖任何前端构建，装完就能用

`webui/` 下的 React + Vite 源码**没有接入发布**，原因是 Vite 产物是
`type="module"` 的 ESM + 哈希资源，KernelSU 用 `file://` 打开 WebUI 时 WebView
会按 CORS 拒绝模块脚本，结果就是**白屏**。上游发布包也一直用 `module/webroot`
这一份。

## 页面能做什么

| 区域 | 内容 |
|---|---|
| 状态卡 | `droid_lkm` 状态、内核版本、构建 KMI、设备、一加/OPPO 判定、兼容模块、是否被阻断 |
| 按钮 | **刷新**（重新读状态）、**重试加载**（`service.sh reset` 后 `PH_ACTION=load` 再加载）、**清空日志** |
| 参数 | `service.sh status` 输出里的 `param.*` / `cparam.*` |
| 日志 | `/data/adb/phdroid/phdroid.log` 末尾内容 |

## 它读写的路径

| 路径 | 内容 |
|---|---|
| `/data/adb/modules/phdroid` | 模块目录（`bin/<KMI>/*.ko`、`config.conf`、`service.sh`） |
| `/data/adb/phdroid` | 运行状态（`auto`、`blocked`、`phdroid.log`、WebUI 保存的 `config.conf`） |

> WebUI 保存配置写的是 `/data/adb/phdroid/config.conf`。
> `service.sh` 优先读这个文件，其次才读模块目录里的 `config.conf`。

## 容易误解的地方

| 项目 | 说明 |
|---|---|
| “参数”区 | 显示的是 insmod 参数，权限 0444，**加载后不能改**；改配置要改 `config.conf` 再 `install` / 重启 |
| “重试加载” | 会先 `reset` 清掉 blocked/crash 状态再加载；已经加载的模块不会重复 insmod |
| 日志清空 | 只清 `phdroid.log`，不影响 `dmesg` 里的历史 |
| `webui/` 目录 | React 源码，只用于开发/预览，不会被工作流打包 |

## 推荐操作顺序

1. 首次：装 zip → 重启 → 打开 WebUI 看状态卡是否 `已加载`
2. 改配置：编辑 `/data/adb/phdroid/config.conf` → `service.sh install`（或重启）
3. 出问题：先点“刷新” → 看日志 → 必要时“重试加载”
4. 要自动加载：`touch /data/adb/phdroid/auto`

## 和模块脚本的对应关系

| WebUI 操作 | 实际执行 |
|---|---|
| 刷新 | `sh /data/adb/modules/phdroid/service.sh status` |
| 重试加载 | `sh service.sh reset; PH_ACTION=load sh service.sh` |
| 清空日志 | `: > /data/adb/phdroid/phdroid.log` |
| 保存配置 | 写 `/data/adb/phdroid/config.conf`（React 版才有；发布版直接改文件后 `install`） |
