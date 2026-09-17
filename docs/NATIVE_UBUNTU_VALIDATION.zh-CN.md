# WRF 4.5.2 / WPS 4.5 原生 Ubuntu 安装与验证记录

> 本文记录 4.5.2 的历史实测。当前默认版本及安装入口见 [README](../README.md)，
> 新版实测见 [4.8.0 验证记录](WRF_4.8_VALIDATION.zh-CN.md)。

验证日期：2026-09-17 至 2026-09-18（Asia/Shanghai）

最终结果：WRF/WPS 编译、WPS 启动检查及 WRF 双进程理想化积分全部通过。

本轮基于仓库提交 `8ae0db102f26d6de5da77d43420490c6bb336deb` 修改。
保留原有中文 README、单个 Bash 安装器、固定源码版本及校验和清单。

## 环境

| 项目 | 实测值 |
|---|---|
| 操作系统 | 原生 Ubuntu 26.04 LTS，x86_64 |
| 内核 | 7.0.0-31-generic |
| CPU | Intel Core i5-7400，4 逻辑 CPU |
| 内存 / Swap | 7.2 GiB / 4 GiB |
| 开始时可用磁盘 | 约 48 GiB |
| GCC / GFortran | 15.2.0 |
| OpenMPI | 5.0.10 |
| NetCDF-C / Fortran | 4.9.3 / 4.6.2 |
| 编译并行度 | `--jobs 2` |

AMD 硬件没有实测；两类 CPU 共用 GNU x86_64 配置，不引入厂商专属编译器或优化参数。
其他 Ubuntu 版本的完整构建没有在本轮执行。Ubuntu 22.04 / 24.04 的 CI
只检查脚本语法、帮助及清单，不代表完整构建验证。

## 实际发现与修复

1. 删除 WSL 主目录及 `/mnt/<盘符>` 路径假设，目标明确为原生 Ubuntu。
2. 修复 `df -Pk --output=avail`：GNU df 的 `-P` 与 `--output` 不能同时使用。
3. OpenMPI 检测改用 `ompi_info --version`：本机 `mpirun --version` 因系统帮助文件路径问题不输出有效版本，但 MPI 本身可运行。
4. 接受系统 MPI 包使用的 `gfortran-15` 等 GNU 编译器名；清除 `OMPI_*` 编译器覆盖变量。
5. GCC 15 的 C23 默认模式使 WRF 旧 `grib_local_ibm` 声明失败，生成配置显式选用 GNU C17。
6. GCC 14+ 将旧 RSL 通信代码的指针类型诊断升级为错误，以 `-Wno-error=incompatible-pointer-types` 保持旧代码的编译兼容性。其他错误仍由产物和日志检查捕获。
7. 非交互缺依赖且 sudo 需要密码时，给出安装命令并退出，避免等待不可输入的密码。
8. WPS `cio.c` 的旧式隐式返回类型触发 GCC 14+ 错误，通过 `-Wno-error=implicit-int` 兼容。
9. WPS 将 `SCC` 未加引号地传给 GRIB2 子 make；将兼容选项放在生成配置的 `CFLAGS`，保留 `SCC=gcc`，避免参数被误解析成 make 选项。
10. WPS 生成配置追加明确的 `NETCDF` 赋值；后续编译不再因环境变量缺失而访问 `/include`、`/lib`，`int2nc.exe` 等工具也可正常编译。
11. 自动并行度按 CPU、8 任务上限和启动时可用内存共同选择（每 3 GiB 一个任务，至少 1）。本机大型 Fortran 文件优化时单进程占用约 3 GiB，手动 `--jobs 2` 实测完成；该估算不是内存保证。
12. 修正克隆后的目录名，保留旧 WSL 文档并明确标记为历史记录；CI 静态检查增加 Ubuntu 24.04。

## 依赖和静态检查

- `dpkg-query` 确认全部安装依赖已安装；未修改系统软件包。
- 非交互 sudo 需要认证，但本轮不缺构建依赖，因此没有要求用户提供密码。
- ShellCheck 0.11.0 从 Ubuntu 软件包解压到工作目录执行，无需 root 安装。
- `bash -n install_wrf_wps_452.sh`：通过。
- `shellcheck install_wrf_wps_452.sh`：完整检查通过（包括错误、警告和提示）。
- `git diff --check`：通过。
- `--help`：通过。
- 空安装目录下 `--offline`：原生系统和磁盘检查通过，随后按预期因缺少归档停止，不联网。
- `--jobs 0`、`--jobs abc`、缺少 jobs 值、不存在的 base、错误 source-method、未知选项：均正确返回 2。
- WRF/WPS 源码压缩包 SHA-256：与仓库清单一致。
- C/Fortran 混合链接、NetCDF-Fortran 写文件、两进程 MPI：通过。
- MPI 探针产生网卡配对警告，但两进程均完成，未影响该项测试。

## 构建与数值验证

| 验证项 | 结果 |
|---|---|
| WPS 内置 zlib / libpng / JasPer | 编译通过，静态归档非空且包含对象文件 |
| WRF `em_real` | `wrf.exe`、`real.exe`、`ndown.exe`、`tc.exe` 全部通过 ELF、动态依赖与配置检查 |
| WPS 主程序及 `g2print.exe` | 全部编译通过；构建日志无致命编译/链接错误 |
| WPS GRIB2 | PNG/JPEG2000 编译分支、JasPer 与 PNG 符号检查通过 |
| WPS 启动 | geogrid / ungrib / metgrid 均到达缺少 namelist 的预期输入检查；g2print 输出用法 |
| WRF `em_quarter_ss` | 增量编译通过 |
| `ideal.exe` 单进程初始化 | 返回 0，出现 `SUCCESS COMPLETE IDEAL INIT` |
| `wrf.exe` 双进程积分 | 返回 0，出现 `SUCCESS COMPLETE WRF`，积分到模式时间 01:00 |
| NetCDF 输出 | `wrfinput_d01` 与 `wrfout` 可读，输出含 00:00 / 00:30 / 01:00 三个时刻 |
| run 目录保护 | 测试后恢复原有 namelist、input_sounding 与 ideal.exe 布局 |
| 离线重复运行 | 不加 `--resume`，复用 WRF/WPS，重新通过工具链和 WPS 验证 |

WRF `em_real` 构建用时约 31 分钟（2026-09-17 20:06:22 至 20:37:03）。
2026-09-18 05:53:46 的完整执行最终返回 0，并记录 `INSTALLATION_SUCCESS`。
理想化测试运行约 27 秒，是 **60 分钟模式时间**，不是 60 分钟实际等待。
初始化文件 5,562,584 字节，模式输出 13,550,788 字节。

执行命令与重复验证命令：

```bash
bash install_wrf_wps_452.sh --skip-apt --jobs 2 --resume
bash install_wrf_wps_452.sh --offline --skip-apt --skip-smoke
```

第二条在 2026-09-18 05:54:04 返回 0，输出 `WRF_EM_REAL_ALREADY_READY`、
`WPS_ALREADY_READY` 和 `INSTALLATION_SUCCESS`，没有重做构建。
数值测试未在这次重复检查中再次运行，其上一次成功记录和输出保留。

各状态文件均为 `SUCCESS`：

```text
WRF/compile.status
WRF/compile_em_quarter_ss.status
WPS/grib2-build.status
WPS/compile.status
WPS/verification_one_click.status
verification/wrf_em_quarter_ss_smoke.status
```

本轮磁盘占用约 WRF 749 MiB、WPS 75 MiB、验证输出 21 MiB，另有源码归档。
构建日志、二进制、源码树和数值输出保留在本地安装目录，按 `.gitignore`
排除；GitHub 更新包含安装器、CI 配置与说明文档。

## 复现

新目录首次安装、且依赖已经装齐时，在最终安装位置运行：

```bash
bash install_wrf_wps_452.sh --skip-apt --jobs 2
```

仅当已有同版本不完整构建树、确认可以清理生成文件后，使用：

```bash
bash install_wrf_wps_452.sh --skip-apt --jobs 2 --resume
```

`--resume` 会清理不完整组件的构建产物。本轮修改兼容参数后使用此选项重新构建。
成功安装之后重复执行默认命令会验证并复用已完成构建。

真实资料流程仍需要另备 WPS_GEOG、GRIB 气象资料及对应 namelist；本轮不声称完成该流程。

## 兼容性参考

- [GCC 15 迁移说明：默认 C23](https://gcc.gnu.org/gcc-15/porting_to.html)
- [GCC 14 迁移说明：部分 C 诊断升级为错误](https://gcc.gnu.org/gcc-14/porting_to.html)
