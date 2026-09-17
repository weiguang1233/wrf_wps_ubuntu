# WRF 4.8.0 / WPS 4.7.0 原生 Ubuntu 验证记录

验证日期：2026-09-18（Asia/Shanghai）。
基于上一轮已验证提交 `bfba8f5dc16fd0a1ad7dc8c8cc50e97094d71202` 更新。

## 版本来源与选择

2026-09-18 查询官方 Releases，最新稳定版为 WRF **4.8.0**（2026-06-08 发布），
而不是名为 `v4.8` 的标签。官方说明指出新版特性应配合 WPS **4.7.0** 或更高版本。
WPS 最新稳定版为 4.7.0（2026-07-06 发布），因此选择此组合。

| 组件 | 官方标签提交 | 完整归档 SHA-256 |
|---|---|---|
| WRF 4.8.0 | `06d4240ae989cc3e50af412bb472df3d9048783c` | `f3b997266379e1719d186c92471a8f44f8185e976244abde82145a7fddeaf418` |
| WPS 4.7.0 | `5feccecd63384381b6942371c7a837f66e4ccb84` | `5232d20d7556338391b66aba45824d4fcd6c42712ebe9325f359f3c6cf043808` |

WRF 使用官方发布资产 `v4.8.0.tar.gz`，哈希同时与 GitHub Release 资产 digest 一致；
不使用上游刻意置空的自动 Source code 归档。完整资产包含 NoahMP、MMM-physics、
MYNN-EDMF、MYNN-SFC、GFL、TEMPO 和 fire_behavior 等版本对应的子模块。
WPS 标签归档下载后计算 SHA-256 并固定到本项目清单。

- [WRF 4.8.0 发布说明](https://github.com/wrf-model/WRF/releases/tag/v4.8.0)
- [WPS 4.7.0 发布说明](https://github.com/wrf-model/WPS/releases/tag/v4.7.0)

## 安装器变化

- 新通用入口 `install_wrf_wps.sh` 默认选择 4.8.0 + 4.7.0。
- `--wrf-version` 指定清单中的 WRF 版本；支持 `4.8` / `4.8.0` / `v4.8.0` / `V4.8.0`。
- `--list-versions` 列出支持的固定组合，不安装或联网。
- `versions.tsv` 固定每个 WRF 版本对应的 WPS 版本与两个精确提交。
- 默认安装到 `installations/wrf-<版本>-wps-<版本>`，避免不同版本的源码、产物和日志混用。
- `--base` 仍可指定已有目录；遇到版本不符的 WRF/WPS 树会停止，`--resume` 不会跨版本清理。
- README 版本匹配改为整行匹配，避免把 4.8.00 等字符串误认为 4.8.0。
- 从官方 configure 菜单识别 GNU dmpar / GNU serial，避免菜单编号跨版本变化。
- 旧入口 `install_wrf_wps_452.sh` 委托通用入口，保持旧版本和仓库根目录的默认行为。
- 保留上一轮原生 Ubuntu 的 GNU、NetCDF、Conda 环境清理及 GCC 15 兼容修正。
- 构建日志检查增加普通 C 编译器 `error:` 模式，防止上游忽略错误后被当作成功。

## 实测环境

| 项目 | 实测值 |
|---|---|
| 系统 | 原生 Ubuntu 26.04 LTS，x86_64，内核 7.0.0-31-generic |
| CPU | Intel Core i5-7400，4 逻辑 CPU |
| 内存 / Swap | 7.2 GiB / 4 GiB |
| 开始时可用磁盘 | 约 46 GiB |
| GCC / GFortran | 15.2.0 |
| OpenMPI | 5.0.10 |
| NetCDF-C / Fortran | 4.9.3 / 4.6.2 |
| 编译并行度 | `--jobs 2` |

全部所需 Ubuntu 构建包已经安装；本轮没有修改系统包。
下载并校验源码归档后，实际编译使用 `--offline --skip-apt`，验证本地归档路径。
AMD 使用相同通用 GNU 配置，但没有 AMD 硬件实测；其他 Ubuntu 版本仅做轻量 CI。

## 实际执行

新版归档放入默认版本目录后：

```bash
bash install_wrf_wps.sh --wrf-version 4.8 --offline --skip-apt --jobs 2
```

旧版兼容入口复核（已通过）：

```bash
bash install_wrf_wps_452.sh --offline --skip-apt --skip-smoke
```

旧入口返回 0，记录 `INSTALLATION_SUCCESS`，复用原 4.5.2 / 4.5 构建，未移动或清理旧安装。

## 静态与回归检查

```bash
for script in install_wrf_wps.sh install_wrf_wps_452.sh tests/test_versions.sh; do
  bash -n "$script"
done
shellcheck install_wrf_wps.sh install_wrf_wps_452.sh tests/test_versions.sh
bash tests/test_versions.sh
git diff --check
```

回归检查覆盖版本列表、清单格式、重复项及每个版本归档的唯一哈希项，
版本别名、无效参数、未知版本在目录创建前停止、离线缺归档及跨版本目录拒绝。
本机 `/tmp` 是约 3.6 GiB tmpfs，因此预检测试目录使用仓库下的本地磁盘，
满足安装器 10 GiB 可用空间检查。

## 编译和运行结果

首次完整运行返回 0，开始于 `2026-09-18T06:04:36+08:00`，
结束于 `2026-09-18T06:56:14+08:00`，总耗时 **51 分 38 秒**。
这包含完整 `em_real` 构建、WPS、理想化目标的增量构建及实际积分，
不是 60 分钟墙钟积分。理想化目标仍会重编译大型动力文件，本轮增量构建约 15 分钟。

| 检查 | 结果 | 成功时间（UTC+8） |
|---|---|---|
| C / Fortran / NetCDF-Fortran / 两进程 MPI 小程序 | 通过 | 构建前 |
| WPS 内置 zlib / libpng / JasPer | `SUCCESS` | 06:05:10 |
| WRF `em_real`（wrf / real / ndown / tc） | `SUCCESS` | 06:40:29 |
| WPS（geogrid / ungrib / metgrid / g2print） | `SUCCESS` | 06:40:56 |
| WPS GRIB2 符号、动态库和启动 | `SUCCESS` | 06:40:57 |
| WRF `em_quarter_ss` | `SUCCESS` | 06:55:49 |
| WRF 双进程理想化积分 | `SUCCESS` | 06:56:14 |

GNU 菜单自动识别实际选中了 WRF dmpar **34**、WPS serial **1**。
编译器/链接错误扫描通过；要求的 ELF 程序与动态依赖检查通过。
WPS 程序在隔离目录运行，正常到达预期的缺少 `namelist.wps` 输入检查；
`G2PRINT_RC`、`GEOGRID_RC`、`UNGRIB_RC`、`METGRID_RC` 均为 0。
启动成功不表示已经处理气象资料。

### 理想化个例

使用上游 `em_quarter_ss` 原始 namelist 和 sounding：
网格配置 `e_we=42`、`e_sn=42`、`e_vert=41`，时间步长 12 秒，
模式积分 60 分钟，每 30 分钟输出一次。

- `ideal.exe`：1 个 MPI 进程，返回 0，找到 `SUCCESS COMPLETE IDEAL INIT`。
- `wrf.exe`：2 个 MPI 进程，返回 0，找到 `SUCCESS COMPLETE WRF`。
- 初始化及积分墙钟时间合计约 25 秒。
- `wrfinput_d01`：**5,569,628 字节**，NetCDF 可读。
- `wrfout_d01_0001-01-01_00:00:00`：**13,571,260 字节**，NetCDF 可读。
- `Times` 包含 `0001-01-01_00:00:00`、`0001-01-01_00:30:00`、
  `0001-01-01_01:00:00`，确认输出覆盖最终模式时间。
- 原 `WRF/run/namelist.input` 已恢复，原先不存在的 `input_sounding` 和 `ideal.exe`
  仍不存在，没有把测试个例留作默认运行配置。

本轮另用 SciPy 读取上述 NetCDF，并用 NumPy 核查全部三个输出时刻的
`T`（位温扰动）、`U`、`V`、`W`、`P`、`PB`：全部数值有限，
无 NaN / Inf；总压力 `P+PB` 全部大于零，范围约 **5,983.621–97,116.438 Pa**。
该辅助检查不是安装器的额外依赖，也不代表所有物理方案已验证。
结果保存在本地个例目录的 `numerical_fields.json`。

### 默认入口离线复用

```bash
bash install_wrf_wps.sh --offline --skip-apt --skip-smoke
```

默认选择 4.8.0 + 4.7.0，无需重新指定版本；返回 0，
在 `2026-09-18T06:56:30+08:00` 再次记录 `INSTALLATION_SUCCESS`。
日志包含 `WPS_GRIB2_LIBRARIES_ALREADY_READY`、`WRF_EM_REAL_ALREADY_READY`、
`WPS_ALREADY_READY`，确认没有重建完整组件。
工具链和 WPS 启动检查再次通过；保留原数值测试成功状态，没有重复积分。

本地状态文件位于 `installations/wrf-4.8.0-wps-4.7.0/`：

```text
WRF/compile.status
WRF/compile_em_quarter_ss.status
WPS/grib2-build.status
WPS/compile.status
WPS/verification_one_click.status
verification/wrf_em_quarter_ss_smoke.status
```

以上状态均为 `SUCCESS`。数值运行日志位于
`verification/em_quarter_ss_run_20260918T064057-78760/smoke.log`。
本机空间占用约 WRF 868 MiB、WPS 75 MiB、verification 21 MiB（不含源码归档）。

构建树、归档和日志按 `.gitignore` 保留在本地，仓库仅提交脚本、固定来源清单和文档。

## 验证边界

没有另备 WPS_GEOG、GRIB 气象资料或真实业务 namelist，因此不声称完成
`geogrid → ungrib → metgrid → real → wrf` 真实资料流程。
本轮未替旧版重新运行数值积分，旧版已有成功结果见
[4.5.2 验证记录](NATIVE_UBUNTU_VALIDATION.zh-CN.md)。

## 真实个例升级时的官方已知问题

本轮构建固定使用原始发布归档，没有将额外物理方案补丁混入源码。
截至本轮检查，官方已知问题包括重力波拖曳输入/非静力选项、ShinHong/YSU
选项迁移以及 NoahMP `opt_runsrf=5` 的重启问题。
`em_quarter_ss` 使用 `bl_pbl_physics=0`、`sf_surface_physics=0`，不能检验这些方案。
真实个例升级前应按 [官方已知问题](https://github.com/wrf-model/WRF/wiki/WRF-V4.8.0-Known-Problems)
检查对应 namelist 与输入资料。
