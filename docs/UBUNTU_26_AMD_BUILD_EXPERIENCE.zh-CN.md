# Ubuntu 26.04 / AMD：WRF 4.5.2 与 4.7.1 本地编译经验

实测日期：2026-09-18。使用已下载并解压的源码，在指定目录分别构建
WRF 4.5.2 / WPS 4.5 和 WRF 4.7.1 / WPS 4.7.0。
这份记录补充本地构建经验；安装器可选版本仍以根目录 `versions.tsv` 为准。
本文不表示一键安装器已经增加 `--wrf-version 4.7.1`。

## 实测环境与结果

| 项目 | 实测值 |
|---|---|
| 操作系统 | 原生 Ubuntu 26.04.1 LTS，x86_64 |
| CPU / 内存 | AMD Ryzen 9 9950X，16 核 / 32 线程，约 120 GiB 内存 |
| 编译器 | GCC / GFortran 15.2.0 |
| MPI | Ubuntu OpenMPI 5.0.10 |
| NetCDF | NetCDF-C 4.9.3；NetCDF-Fortran 4.6.2 |
| WRF 配置 | GNU dmpar、基本嵌套，16 个编译任务，NetCDF-4 支持 |
| WPS 配置 | GNU serial，内置 zlib / libpng / JasPer，GRIB2 支持 |

两套版本均生成 WRF 的 `wrf.exe`、`real.exe`、`ndown.exe`、`tc.exe`，
WPS 的 `geogrid.exe`、`ungrib.exe`、`metgrid.exe`，以及八个辅助工具。
动态库检查没有缺库、Anaconda 库或跨版本目录依赖。
两进程工具链测试和 `em_quarter_ss` 的 60 分钟模式时间积分通过；
输出包含 0 / 30 / 60 分钟三个时刻，T、QVAPOR、U、V、W、PH 均为有限数值。
验证在独立构建副本进行，指定安装目录的四个 WRF 主程序哈希保持不变。

机器可读的验证摘要见
[UBUNTU_26_AMD_VALIDATION.json](UBUNTU_26_AMD_VALIDATION.json)。
未添加 `-march=native`、Intel oneAPI、MKL 或 AMD 专用编译选项。
这次 AMD 实测适用于上述两套版本，不将仓库既有的 WRF 4.8.0 验证自动归为 AMD 实测。

## 先核对现有依赖，避免重复安装

先检查 `command -v gcc gfortran mpif90 mpicc nc-config nf-config`、
编译器版本、`nc-config --all`、`nf-config --all`、
`dpkg-query` 的包状态以及磁盘/内存。
本机缺少的顶层依赖由用户安装：

```text
gfortran csh m4 libopenmpi-dev openmpi-bin libnetcdf-dev libnetcdff-dev
```

该清单是本机当时的缺包结果，不是每台机器都应重新安装的固定清单。
后续两套构建没有再安装系统包，没有覆盖系统 NetCDF，也没有引入 Conda 环境。
需要补包时先做 `apt-get -s install ...` 模拟，明确变更范围。

原 shell 的 PATH 中存在 Anaconda。构建及验证使用系统工具，并清除外部库路径与
`OMPI_CC` / `OMPI_FC` 等覆盖变量。单独 source 一个新环境脚本之前，
仍应核对实际编译器和 MPI 来源；不要混用 Conda MPI 与系统 Fortran / NetCDF。
本次实际执行方式如下，其中 `base` 应按所选版本修改：

```bash
base="$HOME/packages/wrf_allversion/wrfv471"
env -i HOME="$HOME" USER="$(id -un)" PATH=/usr/bin:/bin LC_ALL=C \
  /bin/bash -c 'source "$1/wrf_env.sh"; cd "$WRF_DIR"; ./compile -j 16 em_real' \
  bash "$base"
```

这不需要修改 `.bashrc`。16 个任务是本机资源下的选择，低内存机器应减少并发。

## Ubuntu multiarch NetCDF 布局

Ubuntu 的头文件位于 `/usr/include`，库位于 `/usr/lib/x86_64-linux-gnu`。
旧 WRF 构建使用统一的 `$NETCDF/include` 和 `$NETCDF/lib`，因此在各版本目录创建
`netcdf-system/{include,lib,bin}`，其中只有指向系统文件的符号链接：

- `include` 指向 `/usr/include`；
- `bin` 包含 `nc-config`、`nf-config` 的链接；
- `lib` 包含实际存在的 `libnetcdf.so*`、`libnetcdff.so*`、`libnetcdff.a` 的链接。

`NETCDF` 与 `NETCDF_C` 指向该兼容前缀，不复制库，也不修改 `/usr`。
本机没有 NetCDF-C 静态归档，使用系统共享库能够完成构建。
先验证 C / Fortran 联合调用、两进程 MPI collective、NetCDF-4 压缩写入及跨进程读回，
再启动大型 WRF 构建。

## GCC 15 的参数按组件、版本分别处理

[GCC 15 默认 C 标准变为 C23](https://gcc.gnu.org/gcc-15/porting_to.html)。
本次保留上游源码，修改生成的 GNU 配置文件：

| 组件 | 本次使用的 C 兼容参数 |
|---|---|
| WRF 4.5.2 | `-std=gnu17 -Wno-error=incompatible-pointer-types` |
| WRF 4.7.1 | `-std=gnu17 -Wno-error=incompatible-pointer-types` |
| WPS 4.5 | `-std=gnu17 -Wno-error=implicit-int` |
| WPS 4.7.0 | `-std=gnu17` |

WRF 的 `RSL_LITE` 仍有历史通用缓冲区指针接口；对这类已检查的接口，
仅将相应指针诊断保留为警告。WRF 4.7.1 已含上游 C 声明修复，
不能因此推断旧通信接口完全不需要兼容参数，也不应将所有诊断一并关闭。
Fortran 的 `-fallow-argument-mismatch`、`-fallow-invalid-boz` 由上游配置按编译器版本生成。

本次 WRF 生成配置的相关行：

```make
SCC = gcc -std=gnu17 -Wno-error=incompatible-pointer-types
CCOMP = gcc -std=gnu17 -Wno-error=incompatible-pointer-types
DM_FC = mpif90
DM_CC = mpicc -std=gnu17 -Wno-error=incompatible-pointer-types
```

WPS 4.5 的旧 `cio.c` 需要隐式返回类型兼容参数；WPS 4.7.0 已改为显式声明，
本次没有增加该宽松参数。WPS 的 `SCC` 必须保持单独的 `gcc`，兼容参数放在 `CFLAGS`。
其 `ungrib` 子 make 使用未引用的 `CC=$(SCC)`：把带空格的编译器参数放进 `SCC`
会被 make 拆成错误的命令参数，即使同样写法在 WRF 中可用。

## 使用 WPS 自带 GRIB2 库

无需另行全局安装 JasPer / libpng。先在 WPS 目录编译内置库：

```bash
CC='gcc -std=gnu17' make -C external INTERNAL_GRIB2_PATH="$PWD/grib2"
./configure --build-grib2-libs
# 选择当前版本的 GNU serial；核对并调整 configure.wps 后执行：
./compile > compile.log 2>&1
```

配置菜单编号随版本变化，应从当前版本菜单选择 GNU serial 或 GNU dmpar，
并核对生成配置，不将旧版本菜单编号硬编码为通用选择。
重新运行 `configure` 会覆盖生成文件中的兼容修改，需重新应用参数。

## MPI 版本命令异常不等于通信失败

本机 `mpirun --version` 因 Ubuntu OpenMPI / PRRTE 缺少帮助文件而报错；
`ompi_info --version` 能读出版本，实际通信和模式积分成功。
见 [OpenMPI 上游问题](https://github.com/open-mpi/ompi/issues/13886)。

两进程的单机验证采用：

```bash
mpirun --mca btl self,sm -n 2 ./ideal.exe
mpirun --mca btl self,sm -n 2 ./wrf.exe
```

`self,sm` 只用于本次 OpenMPI 5 的单机检查，不写为全局配置，也不直接套用到旧 MPI 或多节点任务。
不要仅因版本帮助命令异常就重装 MPI。

## 编译成功和模式验证要有独立证据

大型动力模块单个 Fortran 文件可能编译数分钟；日志暂时停止增长并不代表卡死。
WRF 4.5.2 本机首次完整构建约 14 分钟，包括兼容参数修复过程。
保留上游 Fortran 优化，不因等待而随意降低优化或更换编译器。

上游旧 make 流程可能忽略部分错误，退出码 0 不足以证明成功。
应检查最终构建日志、要求的所有可执行文件、ELF 和 `ldd`。
同样，WPS 缺输入时可能打印 `ERROR` 但返回 0：本次分别确认它到达
缺少地理资料 `index`、`GRIBFILE.AAA` 和 `geo_em.d01.nc` 的预期步骤。

为保护指定目录的 `em_real` 程序，将完成的 WRF 源码与对象复制到
`verification/ideal-build`，调整该副本配置内的绝对路径并构建 `em_quarter_ss`。
算例只在 `verification/em_quarter_ss` 运行。样例的 `end_minute=120`
仅在验证副本中修正为 `end_hour=1, end_minute=0`，不修改原样例。
运行前后比较主目录四个 WRF 程序 SHA-256；再检查成功标志、输出时间和主要变量有限值。

这验证构建、MPI 运行和输出健康。没有 WPS_GEOG / GRIB 资料，
本次未运行真实资料的 `geogrid → ungrib → metgrid → real → wrf` 全流程，
也未与科研基准进行定量比对。配置使用基本嵌套；上游未找到传统路径的
`rpc/types.h`，移动嵌套未启用。

## 源码身份与版本隔离

WRF 4.7.1 / WPS 4.7.0 构建前分别核对用户本地归档中的 5008 / 1402 个文件，
与解压目录一致，无差异。记录的本地归档 SHA-256：

```text
11186188b033d26332e31769c1f7aff9349406920a7f72eeb256d5881f7223f4  v4.7.1.tar.gz
5232d20d7556338391b66aba45824d4fcd6c42712ebe9325f359f3c6cf043808  WPS-4.7.0.tar.gz
```

这是本地归档与源码一致性的记录；WRF 4.7.1 归档未做独立上游哈希认证。
WPS 4.7.0 归档哈希与本仓库已有固定项一致。
子模块是否完整应按当前源码 `Makefile` / `.gitmodules` 检查；本次 WRF 4.7.1
所需的 NoahMP、MYNN-EDMF 均已包含，不根据后续版本或后来修改的发布页面猜测新增模块。

`wrfv452` 和 `wrfv471` 各自保留 `wrf_env.sh`、`netcdf-system`、
`build_logs`、`verification`，避免 WPS 链接到另一版本 WRF。
构建配置包含绝对路径，完成后不应整体搬移安装目录。

参考：[WRF 4.7.1 发布说明](https://github.com/wrf-model/WRF/releases/tag/v4.7.1)、
[WPS 4.7.0 发布说明](https://github.com/wrf-model/WPS/releases/tag/v4.7.0)。
