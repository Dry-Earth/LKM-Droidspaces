# Workflow 导航

完整说明（模块用途、安装、验证、排错）在 **[README.md](README.md)**。
这一页只回答“选哪个 workflow、怎么填、产物叫什么”。

本仓库只有一套实现：phDroid（上游 `Dere3046/_patchHarmony@9f65632` + 本 fork 的
6.6 适配）。

## 选哪个

| 场景 | Workflow | 文件 |
|---|---|---|
| 日常构建（推荐） | `[phDroid] Build from OTA + extras (manifest tools)` | `build-hummer-ota-manifest.yml` |
| manifest 工具链出问题，换 DDK 兜底 | `[phDroid] Build from OTA + extras (check green)` | `build-hummer-ota-full.yml` |
| 只要 namespace，不带 extras | `[phDroid] Build from OTA (upstream _patchHarmony)` | `build-hummer-ota.yml` |
| 复现旧内核环境 | `Build hummer phDroid (upstream 9f65632)` | `build-hummer-upstream.yml` |
| 只改 `module/` 或 WebUI，重打包 | `[phDroid] Repackage normal/safe` | `repackage-upstream.yml` |
| 只验证 `src/native` 能否编译 | `Build native PID` | `native.yml` |

## 输入（manifest / DDK / 基础版共用）

| 输入 | 默认 | 说明 |
|---|---|---|
| `boot_img_url` | `.../hummer/20261113/boot.img` | 同一个 OTA |
| `manifest_url` | `.../hummer/20261113/build-manifest.xml` | 同一个 OTA |
| `safe_mode` | `false` | 只影响版本后缀；`droid_lkm_vendor` 已默认不加载 |
| `publish_release` | `true` | 成功即发 Release |
| `extras_repo` | `Dry-Earth/droidspaces-lkm` | extras 源码 |
| `extras_sha` | `522dc420…` | extras 的固定 commit |

默认值停在 20261113，构建新 OTA 时手动换两个 URL。

```sh
gh workflow run build-hummer-ota-manifest.yml \
  -f boot_img_url=https://mirrorbits.lineageos.org/full/hummer/20261120/boot.img \
  -f manifest_url=https://mirrorbits.lineageos.org/full/hummer/20261120/build-manifest.xml
```

## 产物命名

| Workflow | Artifact / Release tag | zip |
|---|---|---|
| manifest 版 | `phdroid-ota-manifest-<run_id>` | `phDroid-v2.0.0-hummer+extras.zip` |
| DDK 版 | `phdroid-ota-full-<run_id>` | 同上 |
| 基础版 | `phdroid-ota-<run_id>` | `phDroid-v2.0.0-hummer.zip` |
| 固定内核版 | `phdroid-upstream-<run_id>` | 同上 |
| 重打包 | `phdroid-upstream-safe-<run_id>` / normal | 按 `safe_mode` |

有 extras 时版本号追加 `+extras`，`safe_mode=true` 时追加 `-safe`。

每个 Release 都带 `build-info-manifest.txt`：boot sha256、kernel/modules/extras
commit、工具 revision、每个 `.ko` 与 zip 的 sha256、每个模块的 vermagic。

## 构建期硬性检查

- 所有 `.ko` 的 vermagic 必须等于 `uname -r`（`6.6.144-4k-g01ee97578159`）
- 编出来的每个 `.ko` 都必须出现在 zip 里（数量与名字都校验）
- `config.conf` 的 `modules=` 只允许出现实际打包进来的模块

任何一条不满足都会让 workflow 红，不会发出残缺的包。

## 装机后

默认不自动加载：

```sh
su -c 'sh /data/adb/modules/phdroid/service.sh load'
su -c 'sh /data/adb/modules/phdroid/service.sh status'
su -c 'touch /data/adb/phdroid/auto'      # 验证稳定后再开自启
```

详见 [README.md](README.md) 第 3 节。
