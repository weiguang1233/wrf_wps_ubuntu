# WRF 4.5.2 + WPS 4.5 一键安装器

这是一个面向 Ubuntu/WSL 的非官方安装脚本。它安装依赖、获取并校验固定
版本源码、编译 WRF 与 WPS，并运行工具链检查、WPS 启动检查和一个小型
WRF MPI 数值示例。

默认结果会写在仓库目录中：

```text
WRF/
WPS/
netcdf-system/
verification/
wrf_env.sh
install_one_click.log
source_provenance_one_click.txt
```

## 快速开始

先把仓库克隆到 WSL 的 Linux 主目录，而不是 `/mnt/c`、`/mnt/d` 等
Windows 挂载盘：

```bash
cd ~
git clone https://github.com/weiguang1233/wrf_wps_ubuntu.git
cd wrf-wps-installer
bash install_wrf_wps_452.sh
```

脚本需要普通用户运行。缺少 Ubuntu 软件包时，它会单独调用 `sudo` 并
可能询问密码：

```text
不要运行：sudo bash install_wrf_wps_452.sh
```

安装成功后：

```bash
source ./wrf_env.sh
wrf.exe
```

最后一行只是展示程序已进入环境；实际 WRF 个例仍需要相应的
`namelist.input`、初始场和边界场。

## 支持范围

- WRF `4.5.2`
- WPS `4.5`
- GNU `gcc/gfortran`
- OpenMPI，WRF 使用 `dmpar`
- WPS 使用 GNU serial，并启用内置 JasPer、libpng、zlib 的 GRIB2 支持
- 目标平台为 `x86_64` Ubuntu/WSL2

核心构建、链接检查和 `em_quarter_ss` 两进程数值测试已在以下环境实际
通过：

```text
WSL2
Ubuntu 20.04.4 LTS
GCC/GFortran 9.4.0
OpenMPI 4.0.3
NetCDF-C 4.7.3
NetCDF-Fortran 4.5.2
```

这是历史验证环境，不是给新安装选择操作系统版本的推荐。原生 Ubuntu
和其他 Ubuntu 版本会显示“未经完整验证”警告并继续尝试。不同发行版、
CPU 架构、MPI 实现和第三方编译器不在当前脚本的已验证范围内。

## 运行前条件

- 至少约 10 GiB 可用磁盘空间；
- 能使用 `sudo apt-get` 安装缺失依赖，或已经自行装好全部依赖；
- 默认方式需要访问 GitHub；
- 路径不能含空格；
- 必须放在 WSL Linux 文件系统中，例如
  `/home/username/wrf-wps-installer`。

首次编译会占用较长时间，具体取决于 CPU、WSL 资源限制和网络速度。

不要把构建目录放在 `/mnt/c`、`/mnt/d` 等 DrvFS 路径。除了性能明显
较差，Linux 符号链接、权限和时间戳语义也更容易影响旧式构建系统。

## 脚本做什么

1. 检测 Ubuntu 版本、WSL、CPU 架构、CPU 数、内存和磁盘空间；
2. 清除 Conda 和外部编译器/库路径变量对构建的污染；
3. 安装并核对 GNU、OpenMPI、NetCDF-C/Fortran 等依赖；
4. 下载或克隆固定的 WRF/WPS 源码，并验证校验和或 Git 提交；
5. 为 Ubuntu multiarch NetCDF 建立只含符号链接的兼容前缀；
6. 先运行 C、Fortran、NetCDF-Fortran 和两进程 MPI 工具链测试；
7. 编译 WPS 内置 GRIB2 库、WRF `em_real` 和 WPS；
8. 检查 ELF 文件、动态依赖、链接符号、构建日志和成功标志；
9. 检查 WPS 程序能启动并到达预期输入检查；
10. 默认运行 WRF `em_quarter_ss` 的两进程、60 分钟积分测试。

完整的首次安装与排错记录见
[docs/INSTALLATION_NOTES.zh-CN.md](docs/INSTALLATION_NOTES.zh-CN.md)。

## 常用选项

```text
--base DIR
    把源码、构建结果和日志写到指定目录。目录必须已经存在。

--jobs N
    WRF 并行编译任务数。默认使用 min(nproc, 8)。

--skip-apt
    不安装 Ubuntu 软件包；发现缺包时立即停止。

--offline
    完全禁止联网；发现缺包或缺少所需源码压缩包时立即停止。

--source-method archive|git
    archive（默认）：下载或复用固定源码压缩包并核对 SHA-256。
    git：新克隆时核对固定标签和精确提交；WRF 同时初始化全部子模块。
    git 与 --offline 同用时，只能复核已经存在的 WRF/WPS 源码树。

--skip-smoke
    不运行 WRF 数值示例，但仍执行编译、链接和 WPS 启动检查。

--resume
    只对已确认同版本但不完整的源码树继续构建。脚本会先清理该组件
    的构建产物；默认不自动修改这种目录。
```

查看内置帮助：

```bash
bash install_wrf_wps_452.sh --help
```

### 依赖已经安装

```bash
bash install_wrf_wps_452.sh --skip-apt
```

### 完全离线安装

先把下面两个文件放在仓库根目录：

```text
v4.5.2.tar.gz
WPS-4.5.tar.gz
```

然后运行：

```bash
bash install_wrf_wps_452.sh --offline
```

脚本仍会严格核对 [checksums.sha256](checksums.sha256)，不会接受名称相同
但内容不同的压缩包。

### 使用 Git 固定提交

```bash
bash install_wrf_wps_452.sh --source-method git
```

当前固定提交：

```text
WRF v4.5.2  a8eb846859cb39d0acfd1d3297ea9992ce66424a
WPS v4.5    5a2ae63988e632405a4504cfb143ce7f0230a7a0
```

WRF 的默认 URL 是官方发布页提供的自定义 `v4.5.2.tar.gz`，不是 GitHub
自动生成的 “Source code” 压缩包；这样才能包含该版本所需的 NoahMP
子模块内容。WPS 标签压缩包由 GitHub 动态生成，仓库固定的是本项目
验证过的字节级 SHA-256。若上游以后重新生成出不同字节，脚本会安全
停止；可检查差异后使用固定提交的 `git` 方式。

## 已有目录与恢复策略

安装器不会静默覆盖 `WRF/` 或 `WPS/`：

- 找到版本不符的目录：停止；
- 找到同版本完整安装：重新验证并复用；
- 找到同版本但不完整的目录：默认停止；
- 只有显式指定 `--resume` 才清理其构建产物并继续。

对已有源码树，脚本验证 README 版本和构建完整性，但不会把它重新等同于
本轮下载且通过哈希验证的归档，也不会声称已经重新核对 Git HEAD。来源
记录会明确显示本轮已验证获取、以前由安装器获取，或来源未知。

`--resume` 前仍建议备份手工改过的构建文件。脚本会专门保护并恢复
`WRF/run` 中容易被目标构建替换的 `namelist.input`、
`input_sounding` 和 `ideal.exe`。

## 验证边界

脚本的默认验证包含：

- 编译器、NetCDF-Fortran、MPI 小程序；
- 所有要求的 WRF/WPS 可执行文件及动态库；
- WPS 的 JasPer、PNG 和 GRIB2 编译分支；
- `geogrid.exe`、`ungrib.exe`、`metgrid.exe` 的启动路径；
- WRF `em_quarter_ss` 理想化数值示例。

仓库不包含体积很大的 `WPS_GEOG`、GRIB/GRIB2 气象资料或业务个例，
所以不会运行完整的
`geogrid → ungrib → metgrid → real → wrf` 真实资料流程。

## 重要提醒

- 构建配置和部分二进制链接中含有绝对路径。安装完成后不要移动整个
  仓库；要换位置时，请在最终路径重新构建。
- 源码压缩包、构建树、日志和数值输出已由 `.gitignore` 排除，不要把
  它们强制提交到 Git。
- GitHub 普通 Git 仓库会阻止大于 100 MiB 的单个文件；大型地理资料
  和模式输出应放在独立数据存储、Release 资产或合适的大文件服务中。
- 本仓库不是 NCAR、WRF 或 WPS 官方项目。上游源码仍受各自许可证约束；
  本仓库的安装脚本与文档使用 MIT License。
- 科研使用 WRF/WPS 时，请同时遵守上游的许可、注册和引用要求。

## 静态检查

每次推送和拉取请求会运行轻量 CI：

```bash
bash -n install_wrf_wps_452.sh
shellcheck --severity=error install_wrf_wps_452.sh
bash install_wrf_wps_452.sh --help
```

CI 不下载源码，也不执行耗时的完整编译。完整构建是否成功仍取决于目标
Ubuntu/WSL 环境，应以脚本生成的日志和验证状态为准。

## 上游链接

- [WRF 官方 Releases](https://github.com/wrf-model/WRF/releases)
- [WPS 官方 Releases](https://github.com/wrf-model/WPS/releases)
- [WRF 用户指南](https://www2.mmm.ucar.edu/wrf/users/docs/user_guide_v4/contents.html)
- [GitHub 源码压缩包稳定性说明](https://docs.github.com/en/repositories/working-with-files/using-files/downloading-source-code-archives)
