# WRF 4.5.2 / WPS 4.5 在 WSL2 中的安装与验证记录

> **历史记录**：本文描述旧 WSL 安装，不是当前安装指南。当前目标为原生 Ubuntu x86_64，
> 请遵循 [README](../README.md) 和 [原生验证记录](NATIVE_UBUNTU_VALIDATION.zh-CN.md)。

记录日期：2026-07-27（Asia/Shanghai）

> 本文保留第一次在 `/home/lwg/wrfv452` 中实际安装和排错的完整记录。
> 公共仓库版本默认把 `WRF`、`WPS` 和验证产物写在仓库目录中，也可用
> `--base DIR` 指定另一个稳定的 Linux 文件系统目录。

## 1. 最终结果

安装、编译和基础数值验证均已完成。

- WRF：4.5.2，GNU + OpenMPI，`dmpar` 并行构建。
- WPS：4.5，GNU serial 构建。
- WPS GRIB2：已启用，使用源码包内置的 JasPer、libpng 和 zlib。
- WRF 理想化示例：`em_quarter_ss` 已完成 60 分钟积分。
- 所有最终状态文件均为 `SUCCESS`。

安装根目录：

```text
/home/lwg/wrfv452
```

主要目录：

```text
/home/lwg/wrfv452/WRF
/home/lwg/wrfv452/WPS
/home/lwg/wrfv452/WPS/grib2
/home/lwg/wrfv452/netcdf-system
/home/lwg/wrfv452/verification
/home/lwg/wrfv452/wrf_env.sh
```

磁盘占用约为：

```text
WRF           734 MB
WPS            82 MB
verification  164 KB
```

## 2. 系统与工具链

安装前检测结果：

| 项目 | 检测结果 |
|---|---|
| WSL | WSL2 |
| Linux | Ubuntu 20.04.4 LTS |
| 内核 | 6.6.87.2-microsoft-standard-WSL2 |
| 架构 | x86_64 |
| CPU | 16 个逻辑 CPU |
| 内存 | 约 62 GiB |
| 可用磁盘 | 约 896 GiB |
| GCC | 9.4.0 |
| GFortran | 9.4.0 |
| OpenMPI | 4.0.3 |
| NetCDF-C | 4.7.3 |
| NetCDF-Fortran | 4.5.2 |

安装或确认的主要 Ubuntu 软件包：

```text
build-essential     12.8ubuntu1.1
gcc/g++/gfortran    Ubuntu 9.x 包，实际编译器版本 9.4.0
openmpi-bin         4.0.3-0ubuntu1
libopenmpi-dev      4.0.3-0ubuntu1
libnetcdf-dev       4.7.3-1
libnetcdff-dev      4.5.2+ds-1build2
netcdf-bin          4.7.3-1
zlib1g-dev          1.2.11
libpng-dev          1.6.37
csh                 20110502-5
m4                  1.4.18
perl                5.30.0
```

对应安装命令：

```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential gfortran g++ make m4 csh perl git wget curl \
    file pkg-config flex bison cmake \
    openmpi-bin libopenmpi-dev \
    libnetcdf-dev libnetcdff-dev netcdf-bin \
    zlib1g-dev libpng-dev libjpeg-dev
```

Ubuntu 20.04 仓库没有 `libjasper-dev`。本次没有使用不兼容的替代包，而是使用 WPS 4.5 源码自带的 JasPer 1.900.29。

## 3. 使用的源码

使用用户已放在安装目录中的源码包，没有重新下载：

| 源码包 | 用途 | SHA-256 |
|---|---|---|
| `v4.5.2.tar.gz` | WRF 4.5.2 | `408ba6aa60d9cd51d6bad2fa075a3d37000eb581b5d124162885b049c892bbdc` |
| `WPS-4.5.tar.gz` | WPS 4.5 | `3cb29107f85b81af05b7dd494e5d4a13cf1b33b87d7e2911a64a7abc59bf55f3` |

`WPS-4.7.0.tar.gz` 被保留，但没有参与本次构建，以保持 WRF 4.5.2 与 WPS 4.5 同代配套。

源码包完整性检查和解压方式：

```bash
cd /home/lwg/wrfv452

gzip -t v4.5.2.tar.gz
gzip -t WPS-4.5.tar.gz

mkdir WRF WPS
tar -xzf v4.5.2.tar.gz --strip-components=1 -C WRF
tar -xzf WPS-4.5.tar.gz --strip-components=1 -C WPS
```

## 4. Ubuntu multiarch NetCDF 兼容前缀

Ubuntu 将库安装在：

```text
/usr/lib/x86_64-linux-gnu
```

WRF 4.5.2 和 WPS 4.5 的旧配置脚本主要检查 `$NETCDF/lib`。如果直接设置 `NETCDF=/usr`，配置脚本会漏掉 NetCDF-Fortran，最终产生大量错误：

```text
undefined reference to `nf_open_'
undefined reference to `nf_create_'
undefined reference to `nf_get_vara_real_'
```

本次在安装目录建立了一个只包含软链接的兼容前缀：

```bash
mkdir /home/lwg/wrfv452/netcdf-system
ln -s /usr/include \
    /home/lwg/wrfv452/netcdf-system/include
ln -s /usr/lib/x86_64-linux-gnu \
    /home/lwg/wrfv452/netcdf-system/lib
```

该方法不复制、不修改系统库。最终 WRF 链接参数中正确包含：

```text
-L/home/lwg/wrfv452/netcdf-system/lib -lnetcdff -lnetcdf
```

WPS 链接参数也包含同一组库。

## 5. 环境变量

可复用环境脚本：

```text
/home/lwg/wrfv452/wrf_env.sh
```

使用方法：

```bash
source /home/lwg/wrfv452/wrf_env.sh
```

脚本记录的关键变量：

```bash
export WRF_INSTALL="/home/lwg/wrfv452"
export WRF_DIR="$WRF_INSTALL/WRF"
export WPS_DIR="$WRF_INSTALL/WPS"

export NETCDF="$WRF_INSTALL/netcdf-system"
export NETCDF_C="$WRF_INSTALL/netcdf-system"
export WRFIO_NCD_LARGE_FILE_SUPPORT="1"
export NETCDF_classic="1"

export JASPERLIB="$WPS_DIR/grib2/lib"
export JASPERINC="$WPS_DIR/grib2/include"

export OMP_NUM_THREADS="1"
export PATH="$WRF_DIR/main:$WPS_DIR:$PATH"
export LD_LIBRARY_PATH="$JASPERLIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

## 6. 工具链兼容性测试

在正式编译前已实际编译和运行小程序验证：

- C 编译与运行；
- Fortran 编译与运行；
- C/Fortran 混合链接；
- NetCDF-Fortran 创建 NetCDF 文件；
- `ncdump` 读取生成文件；
- 2 进程 OpenMPI Fortran 程序。

最终结果：

```text
C_FORTRAN_OK
NETCDF_FORTRAN_OK
MPI_OK 0 2
MPI_OK 1 2
TOOLCHAIN_TESTS_PASSED
```

## 7. 编译 WRF 4.5.2

配置选择：

```text
34 = GNU (gfortran/gcc), dmpar
1  = basic nesting
```

本次实际配置方式：

```bash
cd /home/lwg/wrfv452/WRF

export NETCDF=/home/lwg/wrfv452/netcdf-system
export NETCDF_C=/home/lwg/wrfv452/netcdf-system
export WRFIO_NCD_LARGE_FILE_SUPPORT=1
export NETCDF_classic=1

# 保持本次实际配置：WRF 自身不构建 GRIB2 I/O；
# 标准流程中的 GRIB2 由 WPS/ungrib 读取。
unset JASPERLIB JASPERINC

printf '34\n1\n' | ./configure > configure.log 2>&1
./compile -j 8 em_real > compile.log 2>&1
```

关键配置：

```text
DESCRIPTION = GNU
DMPARALLEL  = 1
SFC         = gfortran
SCC         = gcc
DM_FC       = mpif90
DM_CC       = mpicc
NETCDFPATH  = /home/lwg/wrfv452/netcdf-system
```

成功标志：

```text
Executables successfully built
```

最终程序：

| 程序 | 大小 |
|---|---:|
| `WRF/main/ideal.exe` | 43,332,208 bytes |
| `WRF/main/wrf.exe` | 49,067,496 bytes |
| `WRF/main/real.exe` | 44,617,408 bytes |
| `WRF/main/ndown.exe` | 44,732,064 bytes |
| `WRF/main/tc.exe` | 44,031,744 bytes |

WRF 自身的 GRIB2 I/O 没有启用；这不影响标准的 WPS → `real.exe` → `wrf.exe` 工作流。WPS 的 GRIB2/JPEG2000/PNG 支持已启用并验证。

## 8. 编译 WPS 4.5 和内置 GRIB2 库

WPS 4.5 源码包自带：

```text
zlib   1.2.11
libpng 1.6.37
JasPer 1.900.29
```

这些库被编译到：

```text
/home/lwg/wrfv452/WPS/grib2
```

实际构建命令：

```bash
cd /home/lwg/wrfv452/WPS

make -C external -j 4 \
    CC=gcc \
    INTERNAL_GRIB2_PATH=/home/lwg/wrfv452/WPS/grib2
```

生成并检查了：

```text
WPS/grib2/lib/libz.a
WPS/grib2/lib/libpng.a
WPS/grib2/lib/libjasper.a
WPS/grib2/include/jasper/jasper.h
```

WPS 配置选择：

```text
1 = Linux x86_64, gfortran, serial
```

配置和编译命令：

```bash
cd /home/lwg/wrfv452/WPS

export NETCDF=/home/lwg/wrfv452/netcdf-system
export WRF_DIR=/home/lwg/wrfv452/WRF

printf '1\n' | ./configure --build-grib2-libs \
    > configure.log 2>&1

./compile > compile.log 2>&1
```

`configure.wps` 中的关键结果：

```text
WRF_DIR             = /home/lwg/wrfv452/WRF
INTERNAL_GRIB2_PATH = /home/lwg/wrfv452/WPS/grib2
FDEFS                = -DUSE_JPEG2000 -DUSE_PNG
COMPRESSION_LIBS     = -ljasper -lpng -lz
SFC                  = gfortran
SCC                  = gcc
```

最终程序：

| 程序 | 大小 |
|---|---:|
| `WPS/geogrid.exe` | 840,592 bytes |
| `WPS/ungrib.exe` | 2,774,536 bytes |
| `WPS/metgrid.exe` | 863,136 bytes |
| `WPS/util/g2print.exe` | 2,497,976 bytes |

注意：WPS 的 `compile` 脚本内部使用会忽略部分错误的构建方式，因此不能只检查退出码。必须确认三个主程序符号链接存在、目标可执行，并检查 `compile.log`。

## 9. WPS 验证结果

验证日志：

```text
/home/lwg/wrfv452/WPS/verification.log
/home/lwg/wrfv452/WPS/verification.status
```

通过项目：

- 三个 WPS 主程序和 `g2print.exe` 均存在且可执行；
- `ldd` 没有 `not found`；
- `ungrib.exe` 包含 GRIB2 编译分支字符串；
- `ungrib.exe` 包含 JasPer 和 libpng 静态符号；
- `g2print.exe` 可正常启动并打印用法；
- `geogrid`、`ungrib`、`metgrid` 在空临时目录中都运行到预期的“缺少 `namelist.wps`”输入检查层，没有加载器错误或段错误。

关键成功标志：

```text
UNGRIB_GRIB2_COMPILE_BRANCH_OK
UNGRIB_JASPER_SYMBOL_OK
UNGRIB_PNG_SYMBOL_OK
G2PRINT_STARTUP_OK
WPS_VERIFICATION_SUCCESS
```

当前没有提供 WPS_GEOG 静态地理资料和真实 GRIB/GRIB2 气象资料，因此没有执行完整的 `geogrid → ungrib → metgrid` 数据链。上述测试验证的是构建、链接、GRIB2 支持和程序启动。

## 10. WRF 理想化数值示例验证

使用不需要外部数据的源码自带案例：

```text
/home/lwg/wrfv452/WRF/test/em_quarter_ss
```

先增量构建该案例：

```bash
cd /home/lwg/wrfv452/WRF
source /home/lwg/wrfv452/wrf_env.sh
./compile -j 8 em_quarter_ss \
    > compile_em_quarter_ss.log 2>&1
```

运行初始化：

```bash
cd /home/lwg/wrfv452/WRF/test/em_quarter_ss
mpirun --bind-to none -np 1 ./ideal.exe
```

结果：

```text
IDEAL_RETURN_CODE=0
wrf: SUCCESS COMPLETE IDEAL INIT
wrfinput_d01 = 5,562,584 bytes
```

随后运行两个 MPI 进程的 60 分钟积分：

```bash
mpirun --bind-to none -np 2 ./wrf.exe
```

结果：

```text
WRF_RETURN_CODE=0
wrf: SUCCESS COMPLETE WRF
wrfout_d01_0001-01-01_00:00:00 = 13,550,788 bytes
最终模拟时次 = 0001-01-01_01:00:00
```

`wrfinput_d01` 和 `wrfout` 均通过 `ncdump -h` 检查。

验证日志：

```text
/home/lwg/wrfv452/verification/wrf_em_quarter_ss_smoke.log
/home/lwg/wrfv452/verification/wrf_em_quarter_ss_smoke.status
/home/lwg/wrfv452/verification/ideal.console.log
/home/lwg/wrfv452/verification/wrf.console.log
/home/lwg/wrfv452/verification/ideal.rsl.error.0000
/home/lwg/wrfv452/verification/rsl.error.0000
/home/lwg/wrfv452/verification/rsl.error.0001
```

## 11. 最终状态文件

以下状态均为 `SUCCESS`：

```text
WPS/grib2-build.status
WPS/compile.status
WPS/verification.status
WRF/compile.status
WRF/compile_em_quarter_ss.status
verification/wrf_em_quarter_ss_smoke.status
```

## 12. 日常使用

每次进入 WSL 后先执行：

```bash
source /home/lwg/wrfv452/wrf_env.sh
```

检查程序：

```bash
ls -lh "$WRF_DIR/main/"*.exe
ls -lh "$WPS_DIR/"{geogrid,ungrib,metgrid}.exe
```

运行真实个例时，仍需另外准备：

- WPS_GEOG 静态地理资料；
- GFS、ERA5 或其他驱动资料；
- 与区域和资料匹配的 `namelist.wps`、`namelist.input` 和 `Vtable`。

基础流程：

```text
geogrid.exe
    ↓
ungrib.exe
    ↓
metgrid.exe
    ↓
real.exe
    ↓
mpirun -np N wrf.exe
```

本次没有启用 HDF5、PnetCDF、parallel NetCDF 或 ADIOS2；它们不是本次 GNU/OpenMPI/NetCDF 基础 `em_real` 构建和测试所必需的功能。

## 13. 本次遇到的问题与解决办法

### 13.1 Ubuntu multiarch 导致 NetCDF-Fortran 链接失败

**现象**

WRF 或 WPS 在最终链接阶段出现：

```text
undefined reference to `nf_open_'
undefined reference to `nf_create_'
undefined reference to `nf_get_vara_real_'
```

**原因**

Ubuntu 20.04 的 NetCDF 头文件位于 `/usr/include`，库文件位于
`/usr/lib/x86_64-linux-gnu`。旧版 WRF/WPS 配置脚本把
`NETCDF=/usr` 理解成 `/usr/include + /usr/lib`，因而漏掉
NetCDF-Fortran 库。

**解决**

建立不复制库文件的兼容前缀：

```text
/home/lwg/wrfv452/netcdf-system/include -> /usr/include
/home/lwg/wrfv452/netcdf-system/lib     -> /usr/lib/x86_64-linux-gnu
```

同时设置：

```bash
export NETCDF=/home/lwg/wrfv452/netcdf-system
export NETCDF_C=/home/lwg/wrfv452/netcdf-system
```

最终链接必须同时包含：

```text
-lnetcdff -lnetcdf
```

一键脚本不会硬编码 `x86_64-linux-gnu`，而是使用 `nf-config`、
`nc-config` 和 `gcc -print-multiarch` 动态探测并验证实际路径。

### 13.2 Ubuntu 20.04 缺少合适的 JasPer 开发包

**现象**

通过系统软件源安装 JasPer 不方便，WPS 的 GRIB2/JPEG2000 支持可能在
配置或链接时失败。

**解决**

使用 WPS 4.5 源码中自带的 zlib 1.2.11、libpng 1.6.37 和
JasPer 1.900.29，离线构建到：

```text
/home/lwg/wrfv452/WPS/grib2
```

除了检查 `.a` 文件存在，一键脚本还会用 `ar t` 检查三个静态库确实
包含目标文件，并验证 `ungrib.exe` 中的 JasPer、PNG 和 GRIB2 分支。

### 13.3 WRF/WPS 的 `compile` 返回 0，但实际链接失败

**现象**

旧版 `compile` 包装脚本可能在日志中已经出现链接错误，却仍返回退出码
0；仅凭 `$?` 会误判安装成功。

**解决**

安装成功必须同时满足：

- 必需的 WRF/WPS 可执行文件均存在、非空、可执行且为 ELF；
- 符号链接能够解析；
- 本轮构建的目标文件时间晚于构建标记；
- 日志包含 WRF 的精确成功标志；
- 日志不含 `undefined reference`、`collect2: error`、
  `cannot find -l` 等致命模式；
- `ldd` 不含 `not found`。

### 13.4 旧可执行文件可能造成“假成功”

**现象**

重新编译失败后，目录里上一次留下的 `wrf.exe` 或 `geogrid.exe`
仍可能通过简单的存在性检查。

**解决**

一键脚本默认采用保守策略：

- 目录不存在时才解压；
- 已有完整安装时只复核，不重编译；
- 已有目录版本不符时立即停止；
- 已有同版本但不完整时默认停止，只有明确指定 `--resume` 才继续；
- 新构建时要求目标文件晚于本轮构建标记。

普通运行不会执行 `clean -a`，也不会删除或覆盖未知目录。只有用户明确
指定 `--resume` 时，脚本才会清理已确认同版本但不完整的组件。

### 13.5 二进制检查中的 `pipefail`/`grep -q` 误判

**现象**

在启用 `set -o pipefail` 后，直接运行
`strings program | grep -q pattern`，`grep` 提前退出可能让上游收到
SIGPIPE，从而把实际匹配成功误判成失败。

**解决**

先把 `strings`、`nm` 和 `ldd` 的结果写入本轮临时目录，再分别检查；
不再依赖容易触发 SIGPIPE 的短路管道。

### 13.6 WPS 启动测试可能掩盖超时或崩溃

**现象**

`timeout command || true` 会把超时、段错误和动态库加载失败都吞掉。

**解决**

一键脚本记录每个程序的真实返回码，拒绝超时、信号退出、加载器错误
和段错误，并要求 `geogrid`、`ungrib`、`metgrid` 确实到达预期的
“缺少 `namelist.wps`”输入检查。

### 13.7 WRF 示例不应覆盖源码目录里的旧结果

**现象**

直接在 `WRF/test/em_quarter_ss` 中运行会覆盖该目录已有的 `rsl.*`、
`wrfinput_d01` 和 `wrfout*`。

**解决**

一键脚本每次在 `/home/lwg/wrfv452/verification` 下创建独立的时间戳
运行目录，复制两个必要输入并链接运行表和程序。`ideal.exe` 与
`wrf.exe` 分别设置 300 秒和 900 秒超时，并检查精确成功标志与
NetCDF 输出。

### 13.8 网络和 sudo

第一次安装使用 `/home/lwg/wrfv452` 中已有的两个源码压缩包。公共仓库
版本会优先复用并校验已有压缩包，缺少时才从固定的上游 URL 下载；
`--offline` 会完全禁止联网，并在依赖或源码包缺失时停止。

脚本必须由普通 WSL 用户运行；只有确实缺少 Ubuntu 软件包时才调用
`sudo apt-get`。不要用 `sudo` 运行整个脚本，也不要把密码写进脚本。
下载先写入当前安装根目录中的进程专属临时文件，完整性和 SHA-256
检查通过后才原子改名；解压也先在同一文件系统的临时目录完成。

### 13.9 GRIB2 支持范围

WRF 本体没有启用其可选的原生 GRIB2 I/O；这是有意配置。常规流程由
启用了 GRIB2 的 WPS 读取外部 GRIB/GRIB2，再生成 WRF 所需中间场。
没有 WPS_GEOG 和真实气象资料时，本次验证只能证明 WPS 构建、链接、
加载和启动正常，不能声称完整的
`geogrid → ungrib → metgrid` 数据链已经跑通。

## 14. 一键安装与复核脚本

仓库克隆到 WSL 的 Linux 文件系统后，可直接运行：

```bash
git clone <repository-url>
cd wrf-wps-installer
bash install_wrf_wps_452.sh
```

默认的 `archive` 方式使用以下文件；存在时复用，不存在时自动下载：

```text
v4.5.2.tar.gz
WPS-4.5.tar.gz
```

两个文件都必须匹配仓库中 `checksums.sha256` 固定的 SHA-256。也可显式
从官方仓库的固定标签克隆并核对提交：

```bash
bash install_wrf_wps_452.sh --source-method git
```

依赖已经安装但仍允许下载源码时：

```bash
bash install_wrf_wps_452.sh --skip-apt
```

依赖和源码压缩包都已经准备好、全程不联网时：

```bash
bash install_wrf_wps_452.sh --offline
```

如果确认已有同版本目录只是上次中断留下的，并接受在其中继续构建：

```bash
bash install_wrf_wps_452.sh --resume
```

`--resume` 会先清理不完整组件的已生成编译产物，再重新配置和构建；
源码文件不会被删除。清理 WRF 前，脚本会先完整保存
`WRF/run/namelist.input`、`input_sounding` 和 `ideal.exe`，并在
`em_real` 重建后立即恢复；异常退出时也会尝试恢复。其他手工修改过的
编译产物仍应事先备份。

只编译和检查、不运行 WRF 数值示例：

```bash
bash install_wrf_wps_452.sh --skip-smoke
```

可用参数：

```text
--base DIR
--jobs N
--skip-apt
--offline
--source-method archive|git
--skip-smoke
--resume
```

若不指定 `--base`，完整输出记录写到当前仓库：

```text
install_one_click.log
source_provenance_one_click.txt
WPS/verification_one_click.log
verification/wrf_em_quarter_ss_smoke.status
verification/em_quarter_ss_run_*/
```

脚本不会覆盖已有的 `wrf_env.sh`。如果该文件指向其他安装目录或关键变量
不匹配，脚本会保留它，并创建 `wrf_env_one_click.sh`；最终输出会明确
提示应当 `source` 哪一个文件。配置文件和二进制中含有绝对路径，因此
构建完成后不要移动仓库；如需改变位置，应在最终位置重新构建。
