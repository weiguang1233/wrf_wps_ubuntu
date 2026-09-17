#!/usr/bin/env bash
#
# One-click WRF 4.5.2 + WPS 4.5 installer for native Ubuntu x86_64 (Intel or AMD).
#
# Source archives may be supplied in BASE_DIR:
#   v4.5.2.tar.gz
#   WPS-4.5.tar.gz
# If an archive is absent, the installer downloads the pinned upstream
# release archive and verifies it against checksums.sha256.
#
# The script is intentionally conservative:
# - every downloaded or locally supplied source archive is checksum-verified;
# - it never overwrites a source directory from another version;
# - it verifies a complete matching installation, and only resumes an
#   incomplete matching tree when --resume is explicitly supplied;
# - it treats executable files and success markers as authoritative because
#   the legacy WRF/WPS compile wrappers can return zero after link failures.

set -Eeuo pipefail
export LC_ALL=C
export LANG=C

usage() {
  cat <<'EOF'
Usage:
  bash install_wrf_wps_452.sh [options]

Options:
  --base DIR       Installation/source-archive directory.
                   Default: directory containing this script.
  --jobs N         Parallel WRF build jobs. Default: min(nproc, 8), further
                   limited to one job per 3 GiB available RAM (at least 1).
  --skip-apt       Do not install Ubuntu packages; fail if any are missing.
  --offline        Never access the network. Missing Ubuntu packages cause
                   a stop, and any needed archives must already be in
                   BASE_DIR.
  --source-method METHOD
                   Source acquisition method: archive (default) or git.
                   New git clones verify pinned upstream commit IDs.
  --skip-smoke     Do not run the em_quarter_ss MPI numerical smoke test.
  --resume         Continue an explicitly accepted incomplete matching tree.
                   Without this option, incomplete pre-existing WRF/WPS
                   directories cause a safe stop. With it, generated build
                   products in the incomplete component are cleaned first;
                   source files are retained.
  -h, --help       Show this help.

Recommended:
  git clone https://github.com/weiguang1233/wrf_wps_ubuntu.git
  cd wrf_wps_ubuntu
  bash install_wrf_wps_452.sh

If dependencies and source archives are already available:
  bash install_wrf_wps_452.sh --skip-apt --offline

If only the dependencies are already installed:
  bash install_wrf_wps_452.sh --skip-apt
EOF
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
checksums_file="$script_dir/checksums.sha256"
base_dir="$script_dir"
detected_cpus="$(nproc 2>/dev/null || echo 2)"
if (( detected_cpus > 8 )); then
  jobs=8
else
  jobs="$detected_cpus"
fi
# Large WRF Fortran units can consume about 3 GiB per compiler process.
# This is a conservative default, not a memory guarantee; --jobs overrides it.
available_memory_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
if [[ "$available_memory_kib" =~ ^[0-9]+$ ]]; then
  memory_jobs=$((available_memory_kib / (3 * 1024 * 1024)))
  ((memory_jobs >= 1)) || memory_jobs=1
  if ((jobs > memory_jobs)); then
    jobs="$memory_jobs"
  fi
fi
skip_apt=0
skip_smoke=0
offline=0
resume=0
source_method="archive"

while (($#)); do
  case "$1" in
    --base)
      (($# >= 2)) || { echo "ERROR: --base requires a directory" >&2; exit 2; }
      base_dir="$2"
      shift 2
      ;;
    --jobs)
      (($# >= 2)) || { echo "ERROR: --jobs requires a number" >&2; exit 2; }
      jobs="$2"
      shift 2
      ;;
    --skip-apt)
      skip_apt=1
      shift
      ;;
    --offline)
      offline=1
      shift
      ;;
    --source-method)
      (($# >= 2)) \
        || { echo "ERROR: --source-method requires archive or git" >&2; exit 2; }
      source_method="$2"
      shift 2
      ;;
    --skip-smoke)
      skip_smoke=1
      shift
      ;;
    --resume)
      resume=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$jobs" =~ ^[1-9][0-9]*$ ]] \
  || { echo "ERROR: --jobs must be a positive integer" >&2; exit 2; }
[[ "$source_method" == "archive" || "$source_method" == "git" ]] \
  || { echo "ERROR: --source-method must be archive or git" >&2; exit 2; }
[[ -d "$base_dir" ]] \
  || { echo "ERROR: base directory does not exist: $base_dir" >&2; exit 2; }
base_dir="$(cd -- "$base_dir" && pwd -P)"
if [[ "$base_dir" =~ [[:space:]] ]]; then
  echo "ERROR: WRF/WPS build paths must not contain whitespace: $base_dir" >&2
  exit 2
fi

wrf_dir="$base_dir/WRF"
wps_dir="$base_dir/WPS"
netcdf_prefix="$base_dir/netcdf-system"
verify_dir="$base_dir/verification"
install_log="$base_dir/install_one_click.log"
env_file="$base_dir/wrf_env.sh"
provenance_file="$base_dir/source_provenance_one_click.txt"
wrf_archive="$base_dir/v4.5.2.tar.gz"
wps_archive="$base_dir/WPS-4.5.tar.gz"
wrf_archive_url="https://github.com/wrf-model/WRF/releases/download/v4.5.2/v4.5.2.tar.gz"
wps_archive_url="https://github.com/wrf-model/WPS/archive/refs/tags/v4.5.tar.gz"
wrf_git_url="https://github.com/wrf-model/WRF.git"
wps_git_url="https://github.com/wrf-model/WPS.git"
wrf_git_commit="a8eb846859cb39d0acfd1d3297ea9992ce66424a"
wps_git_commit="5a2ae63988e632405a4504cfb143ce7f0230a7a0"
wrf_source_marker="$wrf_dir/.wrf_wps_installer_source"
wps_source_marker="$wps_dir/.wrf_wps_installer_source"

for bootstrap_command in mkdir touch tee mktemp flock; do
  command -v "$bootstrap_command" >/dev/null 2>&1 \
    || {
      echo "ERROR: required Ubuntu bootstrap command not found: $bootstrap_command" >&2
      echo "Install the base Ubuntu coreutils/util-linux packages first." >&2
      exit 1
    }
done

mkdir -p "$verify_dir"
touch "$install_log"
exec > >(tee -a "$install_log") 2>&1

active_status_file=""
active_status_context=""

mark_active_failure() {
  local message="$1"
  local status_tmp
  if [[ -n "${active_status_file:-}" ]]; then
    status_tmp="$active_status_file.tmp.$$"
    {
      printf 'FAILED %s %s\n' "$(date -Is)" "$message"
      if [[ -n "${active_status_context:-}" ]]; then
        printf '%s\n' "$active_status_context"
      fi
    } >"$status_tmp"
    mv "$status_tmp" "$active_status_file"
  fi
}

fail() {
  mark_active_failure "$*"
  echo "ERROR: $*" >&2
  exit 1
}

all_executable() {
  local path resolved kind
  for path in "$@"; do
    resolved="$(readlink -e "$path")" || return 1
    [[ -x "$resolved" && -s "$resolved" ]] || return 1
    kind="$(file -Lb "$resolved")"
    [[ "$kind" == *ELF* ]] || return 1
  done
}

all_newer_than() {
  local marker="$1"
  shift
  local path resolved
  for path in "$@"; do
    resolved="$(readlink -e "$path")" || return 1
    [[ "$resolved" -nt "$marker" ]] || return 1
  done
}

all_dependencies_found() {
  local path name
  for path in "$@"; do
    name="$(basename "$path")"
    ldd "$path" >"$temp_dir/readiness-ldd.$name" 2>&1 || return 1
    if grep -Fq "not found" "$temp_dir/readiness-ldd.$name"; then
      return 1
    fi
  done
}

on_error() {
  local rc=$?
  local line="$1"
  mark_active_failure "rc=$rc line=$line"
  echo "INSTALLATION_FAILED rc=$rc line=$line $(date -Is)" >&2
  echo "See: $install_log" >&2
  exit "$rc"
}
trap 'on_error "$LINENO"' ERR

temp_dir="$(mktemp -d /tmp/wrf452-install.XXXXXX)"
download_part_files=()
extract_stage_dirs=()
wrf_run_restore_active=0
wrf_run_restore_dir=""
wrf_run_restore_names=(namelist.input input_sounding ideal.exe)

wrf_run_path_is_build_generated() {
  local name="$1"
  local target="$wrf_dir/run/$name"
  local expected
  local expected_paths=()
  case "$name" in
    namelist.input)
      expected_paths=(
        "$wrf_dir/test/em_real/namelist.input"
        "$wrf_dir/test/em_quarter_ss/namelist.input"
      )
      ;;
    input_sounding)
      expected_paths=("$wrf_dir/test/em_quarter_ss/input_sounding")
      ;;
    ideal.exe)
      expected_paths=("$wrf_dir/main/ideal.exe")
      ;;
    *)
      return 1
      ;;
  esac

  for expected in "${expected_paths[@]}"; do
    if [[ -L "$target" ]] \
       && [[ "$(readlink -m "$target")" == "$(readlink -m "$expected")" ]]; then
      return 0
    fi
    if [[ -f "$target" && ! -L "$target" && -f "$expected" ]] \
       && cmp -s "$target" "$expected"; then
      return 0
    fi
  done
  return 1
}

wrf_run_path_matches_snapshot() {
  local name="$1"
  local target="$wrf_dir/run/$name"
  local snapshot="$wrf_run_restore_dir/$name"

  if [[ -L "$target" && -L "$snapshot" ]]; then
    [[ "$(readlink "$target")" == "$(readlink "$snapshot")" ]]
  elif [[ -f "$target" && -f "$snapshot" \
          && ! -L "$target" && ! -L "$snapshot" ]]; then
    cmp -s "$target" "$snapshot"
  else
    return 1
  fi
}

restore_wrf_run_layout() {
  local name target marker
  ((wrf_run_restore_active)) || return 0

  # Validate every destination before changing any of them.
  for name in "${wrf_run_restore_names[@]}"; do
    target="$wrf_dir/run/$name"
    marker="$wrf_run_restore_dir/.present-$name"
    if [[ -e "$target" && ! -f "$target" && ! -L "$target" ]]; then
      echo "ERROR: refusing to replace unexpected run path: $target" >&2
      return 1
    fi
    if [[ -e "$target" || -L "$target" ]]; then
      wrf_run_path_matches_snapshot "$name" \
        || wrf_run_path_is_build_generated "$name" \
        || {
          echo "ERROR: refusing to remove a changed run path: $target" >&2
          return 1
        }
    fi
    if [[ -f "$marker" \
          && ! -e "$wrf_run_restore_dir/$name" \
          && ! -L "$wrf_run_restore_dir/$name" ]]; then
      echo "ERROR: missing WRF run recovery snapshot: $name" >&2
      return 1
    fi
  done

  for name in "${wrf_run_restore_names[@]}"; do
    target="$wrf_dir/run/$name"
    marker="$wrf_run_restore_dir/.present-$name"
    rm -f -- "$target" || return 1
    if [[ -f "$marker" ]]; then
      cp -a "$wrf_run_restore_dir/$name" "$target" || return 1
      [[ -e "$target" || -L "$target" ]] || return 1
    else
      [[ ! -e "$target" && ! -L "$target" ]] || return 1
    fi
  done
  wrf_run_restore_active=0
  echo "WRF_RUN_LAYOUT_RESTORED"
}

begin_wrf_run_layout_protection() {
  local snapshot_dir="$1"
  local name source_path

  ((wrf_run_restore_active == 0)) \
    || fail "a WRF run-layout recovery snapshot is already active"
  [[ ! -e "$snapshot_dir" ]] \
    || fail "WRF run-layout snapshot path already exists: $snapshot_dir"

  wrf_run_restore_dir="$snapshot_dir"
  mkdir "$wrf_run_restore_dir"

  # Snapshot user-replaceable run entries before a WRF clean or target build.
  for name in "${wrf_run_restore_names[@]}"; do
    source_path="$wrf_dir/run/$name"
    if [[ -e "$source_path" || -L "$source_path" ]]; then
      if [[ ! -f "$source_path" && ! -L "$source_path" ]]; then
        fail "unexpected non-file WRF run path: $source_path"
      fi
      cp -a "$source_path" "$wrf_run_restore_dir/$name" \
        || fail "could not snapshot WRF run path: $source_path"
      : >"$wrf_run_restore_dir/.present-$name"
    fi
  done
  wrf_run_restore_active=1
  echo "WRF_RUN_LAYOUT_PROTECTED: $wrf_run_restore_dir"
}

cleanup_temp() {
  local restore_ok=1
  local path
  if ((wrf_run_restore_active)); then
    if ! restore_wrf_run_layout; then
      restore_ok=0
      echo "WARNING: could not fully restore the WRF run layout" >&2
      echo "Recovery snapshot preserved in: $wrf_run_restore_dir" >&2
    fi
  fi
  for path in "${download_part_files[@]}"; do
    if [[ "$(dirname -- "$path")" == "$base_dir" \
          && "$(basename -- "$path")" == .wrf-wps-download-* \
          && -f "$path" && ! -L "$path" ]]; then
      rm -f -- "$path" || restore_ok=0
    fi
  done
  for path in "${extract_stage_dirs[@]}"; do
    if [[ "$(dirname -- "$path")" == "$base_dir" \
          && "$(basename -- "$path")" == .wrf-wps-extract-* \
          && -d "$path" && ! -L "$path" ]]; then
      rm -rf -- "$path" || restore_ok=0
    fi
  done
  if ((restore_ok)) \
     && [[ -n "${temp_dir:-}" \
        && "$temp_dir" == /tmp/wrf452-install.* \
        && -d "$temp_dir" ]]; then
    rm -rf -- "$temp_dir"
  fi
}
trap cleanup_temp EXIT

exec 9>"$base_dir/.install_wrf_wps_452.lock"
flock -n 9 || fail "another installer process is already using $base_dir"
((EUID != 0)) \
  || fail "run this installer as a normal Ubuntu user, not with sudo"

shopt -s nullglob
stale_acquisition_paths=(
  "$base_dir"/.wrf-wps-download-*
  "$base_dir"/.wrf-wps-extract-*
)
shopt -u nullglob
if ((${#stale_acquisition_paths[@]} > 0)); then
  echo "WARNING: previous acquisition temporary paths were found."
  echo "They are not removed automatically; inspect them before manual cleanup:"
  printf '  %s\n' "${stale_acquisition_paths[@]}"
fi

environment_override_vars=(
  CONDA_PREFIX CONDA_DEFAULT_ENV CONDA_SHLVL
  CC CXX FC F77 F90 OMPI_CC OMPI_CXX OMPI_FC OMPI_F77 OMPI_F90
  CPPFLAGS CFLAGS CXXFLAGS FFLAGS FCFLAGS LDFLAGS
  LD_LIBRARY_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH
  PKG_CONFIG_PATH CMAKE_PREFIX_PATH
  NETCDF NETCDF_C JASPERLIB JASPERINC
  MPI_HOME PNETCDF PHDF5 HDF5 HDF5_DIR
  WRF_INSTALL WRF_DIR WPS_DIR
  WRF_EM_CORE WRF_NMM_CORE WRF_CHEM WRF_KPP WRF_DA_CORE
  WRFIO_NCD_LARGE_FILE_SUPPORT NETCDF_classic
)
cleared_environment_vars=()
for variable_name in "${environment_override_vars[@]}"; do
  if [[ -n "${!variable_name-}" ]]; then
    cleared_environment_vars+=("$variable_name")
  fi
  unset "$variable_name"
done
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
hash -r

echo "============================================================"
echo "WRF 4.5.2 / WPS 4.5 one-click installer"
echo "Started:  $(date -Is)"
echo "Base:     $base_dir"
echo "Jobs:     $jobs"
echo "Source:   $source_method"
echo "Log:      $install_log"
echo "============================================================"

[[ -r /etc/os-release ]] || fail "/etc/os-release is unavailable"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] \
  || fail "this installer supports Ubuntu only (detected ID=${ID:-unknown})"
if grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease; then
  fail "use native Ubuntu x86_64; WSL is outside this installer's target platform"
fi

if ((${#cleared_environment_vars[@]} > 0)); then
  echo "SANITIZED_ENVIRONMENT: ${cleared_environment_vars[*]}"
fi

echo "SYSTEM: ${PRETTY_NAME:-unknown Ubuntu}"
echo "KERNEL: $(uname -r)"
echo "ARCH:   $(uname -m)"
echo "PLATFORM: native Ubuntu; GNU toolchain for Intel and AMD"
echo "CPUS:   $(nproc)"
if command -v free >/dev/null 2>&1; then
  free -h
else
  echo "MEMORY: free(1) is not installed yet"
fi
df -h "$base_dir"
[[ "$(uname -m)" == "x86_64" ]] \
  || fail "this tested installer currently supports x86_64 only"

available_kib="$(df -k --output=avail "$base_dir" | tail -n 1 | tr -d '[:space:]')"
[[ "$available_kib" =~ ^[0-9]+$ ]] \
  || fail "could not determine available disk space for $base_dir"
minimum_free_kib=$((10 * 1024 * 1024))
((available_kib >= minimum_free_kib)) \
  || fail "at least 10 GiB free is required in $base_dir"

[[ -r "$checksums_file" ]] \
  || fail "checksum manifest not found: $checksums_file"
expected_wrf_sha="$(
  awk '$2 == "v4.5.2.tar.gz" {print $1}' "$checksums_file"
)"
expected_wps_sha="$(
  awk '$2 == "WPS-4.5.tar.gz" {print $1}' "$checksums_file"
)"
[[ "$expected_wrf_sha" =~ ^[0-9a-f]{64}$ ]] \
  || fail "invalid or duplicate WRF entry in $checksums_file"
[[ "$expected_wps_sha" =~ ^[0-9a-f]{64}$ ]] \
  || fail "invalid or duplicate WPS entry in $checksums_file"
echo "CHECKSUM_MANIFEST_OK: $checksums_file"

wrf_preexisting=0
wps_preexisting=0
wrf_force_clean=0
wps_force_clean=0
archive_download_needed=0
git_clone_needed=0
wrf_source_actual="preexisting-unknown"
wps_source_actual="preexisting-unknown"

if [[ -L "$wrf_dir" ]]; then
  fail "WRF target must not be a symlink: $wrf_dir"
elif [[ -e "$wrf_dir" && ! -d "$wrf_dir" ]]; then
  fail "WRF target exists but is not a directory: $wrf_dir"
elif [[ -d "$wrf_dir" ]]; then
  wrf_preexisting=1
  [[ -r "$wrf_dir/README" ]] \
    || fail "pre-existing WRF tree has no readable README: $wrf_dir"
  grep -Fq "WRF Model Version 4.5.2" "$wrf_dir/README" \
    || fail "$wrf_dir is not WRF 4.5.2"
fi

if [[ -L "$wps_dir" ]]; then
  fail "WPS target must not be a symlink: $wps_dir"
elif [[ -e "$wps_dir" && ! -d "$wps_dir" ]]; then
  fail "WPS target exists but is not a directory: $wps_dir"
elif [[ -d "$wps_dir" ]]; then
  wps_preexisting=1
  [[ -r "$wps_dir/README" ]] \
    || fail "pre-existing WPS tree has no readable README: $wps_dir"
  grep -Fq "WRF Pre-Processing System Version 4.5" "$wps_dir/README" \
    || fail "$wps_dir is not WPS 4.5"
fi

if [[ "$source_method" == "archive" ]]; then
  if ((wrf_preexisting == 0)); then
    if [[ -L "$wrf_archive" && ! -e "$wrf_archive" ]]; then
      fail "WRF archive path is a broken symlink: $wrf_archive"
    elif [[ -e "$wrf_archive" && ! -f "$wrf_archive" ]]; then
      fail "WRF archive path is not a regular file: $wrf_archive"
    elif [[ ! -f "$wrf_archive" ]]; then
      ((offline == 0)) \
        || fail "offline archive mode requires: $wrf_archive"
      archive_download_needed=1
    fi
  fi
  if ((wps_preexisting == 0)); then
    if [[ -L "$wps_archive" && ! -e "$wps_archive" ]]; then
      fail "WPS archive path is a broken symlink: $wps_archive"
    elif [[ -e "$wps_archive" && ! -f "$wps_archive" ]]; then
      fail "WPS archive path is not a regular file: $wps_archive"
    elif [[ ! -f "$wps_archive" ]]; then
      ((offline == 0)) \
        || fail "offline archive mode requires: $wps_archive"
      archive_download_needed=1
    fi
  fi
elif ((wrf_preexisting == 0 || wps_preexisting == 0)); then
  ((offline == 0)) \
    || fail "offline git mode requires both existing WRF and WPS trees"
  git_clone_needed=1
fi

required_packages=(
  build-essential
  gfortran
  g++
  make
  m4
  csh
  perl
  file
  pkg-config
  flex
  bison
  cmake
  time
  binutils
  util-linux
  openmpi-bin
  libopenmpi-dev
  libnetcdf-dev
  libnetcdff-dev
  netcdf-bin
  zlib1g-dev
  libpng-dev
  libjpeg-dev
  libtirpc-dev
)

if ((git_clone_needed)); then
  required_packages+=(ca-certificates git)
fi
if ((archive_download_needed)); then
  required_packages+=(ca-certificates)
  if ! command -v curl >/dev/null 2>&1 \
     && ! command -v wget >/dev/null 2>&1; then
    required_packages+=(curl)
  fi
fi

install_dependencies() {
  local missing=()
  local package status

  for package in "${required_packages[@]}"; do
    status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
    if [[ "$status" != "install ok installed" ]]; then
      missing+=("$package")
    fi
  done

  if ((${#missing[@]} == 0)); then
    echo "DEPENDENCIES_OK: all required Ubuntu packages are installed"
    return
  fi

  echo "Missing packages: ${missing[*]}"
  if ((skip_apt || offline)); then
    fail "missing packages remain but package installation is disabled"
  fi

  command -v sudo >/dev/null \
    || fail "sudo is required to install missing packages"
  if [[ ! -t 0 ]] && ! sudo -n true 2>/dev/null; then
    printf 'Install missing packages in a terminal: sudo apt-get install'
    printf ' %q' "${missing[@]}"
    echo
    fail "package installation requires interactive sudo authentication"
  fi
  echo "sudo may ask for your Ubuntu user password."
  sudo -v
  sudo apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y "${required_packages[@]}"
}

install_dependencies

for command_name in \
  gcc g++ gfortran make m4 csh perl mpicc mpif90 mpirun ompi_info \
  nc-config nf-config ncdump tar gzip sha256sum file ldd nm strings ar \
  readlink stat flock timeout cmp awk tail tr dpkg-query apt-get; do
  command -v "$command_name" >/dev/null \
    || fail "required command not found: $command_name"
done
if ((git_clone_needed)); then
  command -v git >/dev/null \
    || fail "git is required to acquire the missing source trees"
fi
if ((archive_download_needed)); then
  command -v curl >/dev/null 2>&1 \
    || command -v wget >/dev/null 2>&1 \
    || fail "curl or wget is required to download the missing archives"
fi

gcc --version >"$temp_dir/gcc.version"
gfortran --version >"$temp_dir/gfortran.version"
ompi_info --version >"$temp_dir/mpirun.version"
sed -n '1p' "$temp_dir/gcc.version"
sed -n '1p' "$temp_dir/gfortran.version"
sed -n '1p' "$temp_dir/mpirun.version"
grep -Fqi "Open MPI" "$temp_dir/mpirun.version" \
  || fail "the supported MPI implementation is OpenMPI"
mpicc --showme:command >"$temp_dir/mpicc.command"
mpif90 --showme:command >"$temp_dir/mpif90.command"
grep -Eq '(^|/|[[:space:]])gcc(-[0-9]+)?([[:space:]]|$)' "$temp_dir/mpicc.command" \
  || fail "OpenMPI mpicc is not backed by gcc"
grep -Eq '(^|/|[[:space:]])gfortran(-[0-9]+)?([[:space:]]|$)' \
  "$temp_dir/mpif90.command" \
  || fail "OpenMPI mpif90 is not backed by gfortran"
echo "MPICC_BACKEND:  $(<"$temp_dir/mpicc.command")"
echo "MPIF90_BACKEND: $(<"$temp_dir/mpif90.command")"
nc-config --version
nf-config --version

check_archive() {
  local archive="$1"
  local expected_sha="$2"
  local actual_sha

  [[ -f "$archive" ]] || fail "source archive not found: $archive"
  actual_sha="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] \
    || fail "checksum mismatch for $archive: $actual_sha"
  gzip -t "$archive" || fail "gzip integrity check failed: $archive"
  echo "ARCHIVE_OK: $(basename "$archive") $actual_sha"
}

ensure_archive() {
  local archive="$1"
  local url="$2"
  local expected_sha="$3"
  local part

  if [[ -L "$archive" && ! -e "$archive" ]]; then
    fail "archive path is a broken symlink: $archive"
  fi
  if [[ -e "$archive" && ! -f "$archive" ]]; then
    fail "archive path exists but is not a regular file: $archive"
  fi
  if [[ -f "$archive" ]]; then
    check_archive "$archive" "$expected_sha"
    echo "ARCHIVE_CACHE_REUSED: $archive"
    return
  fi
  ((offline == 0)) \
    || fail "offline mode requires the archive: $archive"
  part="$(mktemp -p "$base_dir" \
    ".wrf-wps-download-$(basename "$archive").XXXXXX")" \
    || fail "could not create an atomic download file in $base_dir"
  download_part_files+=("$part")

  echo "Downloading: $url"
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --proto-redir '=https' \
      -fL --retry 5 --retry-delay 2 --connect-timeout 30 \
      -o "$part" "$url" \
      || fail "download failed: $url"
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only --tries=5 --timeout=30 \
      -O "$part" "$url" \
      || fail "download failed: $url"
  else
    fail "curl or wget is required to download source archives"
  fi

  check_archive "$part" "$expected_sha"
  [[ ! -e "$archive" && ! -L "$archive" ]] \
    || fail "archive appeared while downloading; refusing to overwrite: $archive"
  mv -- "$part" "$archive"
  echo "ARCHIVE_DOWNLOADED: $archive"
}

extract_archive_source() {
  local archive="$1"
  local target="$2"
  local expected_readme_text="$3"
  local stage

  [[ ! -e "$target" && ! -L "$target" ]] \
    || fail "source target appeared unexpectedly: $target"
  stage="$(mktemp -d -p "$base_dir" \
    ".wrf-wps-extract-$(basename "$target").XXXXXX")" \
    || fail "could not create an atomic extraction directory in $base_dir"
  extract_stage_dirs+=("$stage")
  tar -xzf "$archive" --strip-components=1 -C "$stage" \
    || fail "could not extract: $archive"
  grep -Fq "$expected_readme_text" "$stage/README" \
    || fail "extracted source version check failed: $archive"
  [[ ! -e "$target" && ! -L "$target" ]] \
    || fail "source target appeared during extraction: $target"
  mv -- "$stage" "$target"
  echo "EXTRACTED: $target"
}

clone_git_source() {
  local repository="$1"
  local tag="$2"
  local expected_commit="$3"
  local target="$4"
  local expected_readme_text="$5"
  local with_submodules="$6"
  local stage
  local actual_commit submodule_status

  ((offline == 0)) \
    || fail "offline mode cannot clone missing source tree: $target"
  [[ ! -e "$target" && ! -L "$target" ]] \
    || fail "source target appeared unexpectedly: $target"
  stage="$(mktemp -d -p "$base_dir" \
    ".wrf-wps-extract-$(basename "$target").XXXXXX")" \
    || fail "could not create an atomic clone directory in $base_dir"
  extract_stage_dirs+=("$stage")

  git clone --depth 1 --single-branch --branch "$tag" \
    "$repository" "$stage" \
    || fail "git clone failed: $repository tag $tag"
  actual_commit="$(git -C "$stage" rev-parse HEAD)"
  [[ "$actual_commit" == "$expected_commit" ]] \
    || fail "unexpected commit for $repository: $actual_commit"

  if ((with_submodules)); then
    [[ -f "$stage/.gitmodules" ]] \
      || fail "WRF checkout is missing its submodule manifest"
    git -C "$stage" submodule sync --recursive
    git -C "$stage" submodule update --init --recursive \
      || fail "WRF submodule checkout failed"
    submodule_status="$(git -C "$stage" submodule status --recursive)"
    [[ -n "$submodule_status" ]] \
      || fail "WRF checkout did not report any initialized submodules"
    if grep -Eq '^[+-U]' <<<"$submodule_status"; then
      fail "WRF submodule status is incomplete or inconsistent"
    fi
  fi

  grep -Fq "$expected_readme_text" "$stage/README" \
    || fail "cloned source version check failed: $repository"
  [[ ! -e "$target" && ! -L "$target" ]] \
    || fail "source target appeared during git clone: $target"
  mv -- "$stage" "$target"
  echo "GIT_SOURCE_READY: $target $actual_commit"
}

write_source_marker() {
  local marker="$1"
  local component="$2"
  local method="$3"
  local version="$4"
  local url="$5"
  local associated_tag_commit="$6"
  local pinned_sha="$7"
  local marker_tmp="$marker.tmp.$$"

  [[ ! -e "$marker" && ! -L "$marker" ]] \
    || fail "refusing to overwrite a source marker: $marker"
  [[ ! -e "$marker_tmp" && ! -L "$marker_tmp" ]] \
    || fail "temporary source marker path already exists: $marker_tmp"
  {
    echo "FORMAT=1"
    echo "COMPONENT=$component"
    echo "SOURCE_TYPE=$method"
    echo "VERSION=$version"
    echo "UPSTREAM_URL=$url"
    echo "ASSOCIATED_TAG_COMMIT=$associated_tag_commit"
    echo "PROJECT_PINNED_SHA256=$pinned_sha"
    echo "ACQUIRED_AT=$(date -Is)"
  } >"$marker_tmp"
  mv -- "$marker_tmp" "$marker"
}

describe_preexisting_source() {
  local marker="$1"
  local expected_component="$2"
  local expected_version="$3"
  local marker_type

  if [[ -f "$marker" && ! -L "$marker" ]] \
     && grep -Fxq "FORMAT=1" "$marker" \
     && grep -Fxq "COMPONENT=$expected_component" "$marker" \
     && grep -Fxq "VERSION=$expected_version" "$marker"; then
    marker_type="$(awk -F= '$1 == "SOURCE_TYPE" {print $2}' "$marker")"
    if [[ "$marker_type" == "archive" || "$marker_type" == "git" ]]; then
      printf 'preexisting-installer-marker:%s\n' "$marker_type"
      return
    fi
  fi
  printf 'preexisting-unknown\n'
}

wrf_targets=(
  "$wrf_dir/main/wrf.exe"
  "$wrf_dir/main/real.exe"
  "$wrf_dir/main/ndown.exe"
  "$wrf_dir/main/tc.exe"
)

wps_targets=(
  "$wps_dir/geogrid.exe"
  "$wps_dir/ungrib.exe"
  "$wps_dir/metgrid.exe"
  "$wps_dir/util/g2print.exe"
)

archive_has_member() {
  local listing
  listing="$(ar t "$1")" || return 1
  [[ -n "$listing" ]]
}

grib2_libs_ready() {
  [[ -s "$wps_dir/grib2/lib/libz.a" \
     && -s "$wps_dir/grib2/lib/libpng.a" \
     && -s "$wps_dir/grib2/lib/libjasper.a" \
     && -f "$wps_dir/grib2/include/jasper/jasper.h" ]] \
    || return 1
  archive_has_member "$wps_dir/grib2/lib/libz.a" || return 1
  archive_has_member "$wps_dir/grib2/lib/libpng.a" || return 1
  archive_has_member "$wps_dir/grib2/lib/libjasper.a" || return 1
}

wrf_install_ready() {
  all_executable "${wrf_targets[@]}" || return 1
  all_dependencies_found "${wrf_targets[@]}" || return 1
  [[ -s "$wrf_dir/configure.wrf" ]] || return 1
  grep -Eq -- '-lnetcdff[[:space:]]+-lnetcdf' \
    "$wrf_dir/configure.wrf" || return 1
  grep -Eq '^[[:space:]]*DMPARALLEL[[:space:]]*=[[:space:]]*1' \
    "$wrf_dir/configure.wrf" || return 1
  grep -Eq '^[[:space:]]*DM_FC[[:space:]]*=[[:space:]]*mpif90' \
    "$wrf_dir/configure.wrf" || return 1
  grep -Eq '^[[:space:]]*DM_CC[[:space:]]*=[[:space:]]*mpicc' \
    "$wrf_dir/configure.wrf" || return 1
  grep -Fq "$netcdf_prefix" "$wrf_dir/configure.wrf" || return 1
}

wps_install_ready() {
  all_executable "${wps_targets[@]}" || return 1
  all_dependencies_found "${wps_targets[@]}" || return 1
  grib2_libs_ready || return 1
  [[ -s "$wps_dir/configure.wps" ]] || return 1
  grep -Fq -- "-DUSE_JPEG2000 -DUSE_PNG" \
    "$wps_dir/configure.wps" || return 1
  grep -Eq -- '-lnetcdff[[:space:]]+-lnetcdf' \
    "$wps_dir/configure.wps" || return 1
  grep -Eq '^[[:space:]]*SFC[[:space:]]*=[[:space:]]*gfortran' \
    "$wps_dir/configure.wps" || return 1
  grep -Eq '^[[:space:]]*SCC[[:space:]]*=[[:space:]]*gcc' \
    "$wps_dir/configure.wps" || return 1
  grep -Fq "$wps_dir/grib2" "$wps_dir/configure.wps" || return 1
  grep -Fq "$wrf_dir" "$wps_dir/configure.wps" || return 1
  strings "$wps_dir/ungrib.exe" >"$temp_dir/ungrib.precheck.strings"
  grep -Fq \
    "Linked in png and jpeg libraries for Grib Edition 2" \
    "$temp_dir/ungrib.precheck.strings"
}

if ((wrf_preexisting)); then
  wrf_source_actual="$(
    describe_preexisting_source "$wrf_source_marker" WRF 4.5.2
  )"
  if ! wrf_install_ready; then
    if ((resume == 0)); then
      fail "$wrf_dir is an incomplete pre-existing WRF tree; inspect it or rerun with --resume"
    fi
    wrf_force_clean=1
  fi
fi

if ((wps_preexisting)); then
  wps_source_actual="$(
    describe_preexisting_source "$wps_source_marker" WPS 4.5
  )"
  if ! wps_install_ready; then
    if ((resume == 0)); then
      fail "$wps_dir is an incomplete pre-existing WPS tree; inspect it or rerun with --resume"
    fi
    wps_force_clean=1
  fi
fi

if ((wrf_preexisting == 0)); then
  if [[ "$source_method" == "archive" ]]; then
    ensure_archive "$wrf_archive" "$wrf_archive_url" "$expected_wrf_sha"
    extract_archive_source \
      "$wrf_archive" "$wrf_dir" "WRF Model Version 4.5.2"
    write_source_marker \
      "$wrf_source_marker" WRF archive 4.5.2 \
      "$wrf_archive_url" "$wrf_git_commit" "$expected_wrf_sha"
    wrf_source_actual="archive-verified"
  else
    clone_git_source \
      "$wrf_git_url" v4.5.2 "$wrf_git_commit" \
      "$wrf_dir" "WRF Model Version 4.5.2" 1
    write_source_marker \
      "$wrf_source_marker" WRF git 4.5.2 \
      "$wrf_git_url" "$wrf_git_commit" "not-applicable"
    wrf_source_actual="git-verified"
  fi
fi

if ((wps_preexisting == 0)); then
  if [[ "$source_method" == "archive" ]]; then
    ensure_archive "$wps_archive" "$wps_archive_url" "$expected_wps_sha"
    extract_archive_source \
      "$wps_archive" "$wps_dir" "WRF Pre-Processing System Version 4.5"
    write_source_marker \
      "$wps_source_marker" WPS archive 4.5 \
      "$wps_archive_url" "$wps_git_commit" "$expected_wps_sha"
    wps_source_actual="archive-verified"
  else
    clone_git_source \
      "$wps_git_url" v4.5 "$wps_git_commit" \
      "$wps_dir" "WRF Pre-Processing System Version 4.5" 0
    write_source_marker \
      "$wps_source_marker" WPS git 4.5 \
      "$wps_git_url" "$wps_git_commit" "not-applicable"
    wps_source_actual="git-verified"
  fi
fi

grep -Fq "WRF Model Version 4.5.2" "$wrf_dir/README" \
  || fail "$wrf_dir is not WRF 4.5.2"
grep -Fq "WRF Pre-Processing System Version 4.5" "$wps_dir/README" \
  || fail "$wps_dir is not WPS 4.5"
echo "SOURCE_TREES_OK: WRF 4.5.2 + WPS 4.5"

{
  echo "RECORDED_AT=$(date -Is)"
  echo "SOURCE_METHOD_REQUESTED=$source_method"
  echo "WRF_VERSION=4.5.2"
  echo "WRF_SOURCE_ACTUAL=$wrf_source_actual"
  echo "WRF_TAG=v4.5.2"
  echo "WRF_PINNED_COMMIT=$wrf_git_commit"
  echo "WRF_ARCHIVE_URL=$wrf_archive_url"
  echo "WRF_PROJECT_PINNED_SHA256=$expected_wrf_sha"
  if [[ -f "$wrf_archive" ]]; then
    echo "WRF_LOCAL_ARCHIVE_SHA256=$(sha256sum "$wrf_archive" | awk '{print $1}')"
  else
    echo "WRF_LOCAL_ARCHIVE_SHA256=not-present"
  fi
  echo "WPS_VERSION=4.5"
  echo "WPS_SOURCE_ACTUAL=$wps_source_actual"
  echo "WPS_TAG=v4.5"
  echo "WPS_PINNED_COMMIT=$wps_git_commit"
  echo "WPS_ARCHIVE_URL=$wps_archive_url"
  echo "WPS_PROJECT_PINNED_SHA256=$expected_wps_sha"
  if [[ -f "$wps_archive" ]]; then
    echo "WPS_LOCAL_ARCHIVE_SHA256=$(sha256sum "$wps_archive" | awk '{print $1}')"
  else
    echo "WPS_LOCAL_ARCHIVE_SHA256=not-present"
  fi
} >"$temp_dir/source_provenance.txt"
mv "$temp_dir/source_provenance.txt" "$provenance_file"
echo "SOURCE_PROVENANCE: $provenance_file"

multiarch="$(gcc -print-multiarch)"
system_include_dir="$(nf-config --includedir)"
system_lib_dir="$(nc-config --libdir)"
system_include_dir="$(readlink -f "$system_include_dir")"
system_lib_dir="$(readlink -f "$system_lib_dir")"
[[ -d "$system_include_dir" ]] \
  || fail "NetCDF include directory not found: $system_include_dir"
[[ -d "$system_lib_dir" ]] \
  || fail "NetCDF library directory not found: $system_lib_dir"
[[ -e "$system_lib_dir/libnetcdf.so" ]] \
  || fail "NetCDF-C library not found in $system_lib_dir"
[[ -e "$system_lib_dir/libnetcdff.a" \
   || -e "$system_lib_dir/libnetcdff.so" ]] \
  || fail "NetCDF-Fortran library not found in $system_lib_dir"
nf-config --flibs >"$temp_dir/netcdff.flibs"
grep -Eq '(^|[[:space:]])-lnetcdff([[:space:]]|$)' \
  "$temp_dir/netcdff.flibs" \
  || fail "nf-config --flibs does not contain -lnetcdff"
echo "NETCDF_INCLUDE: $system_include_dir"
echo "NETCDF_LIB:     $system_lib_dir"
echo "MULTIARCH:      $multiarch"

mkdir -p "$netcdf_prefix"

ensure_directory_link() {
  local target="$1"
  local link_path="$2"
  local resolved_target resolved_link

  resolved_target="$(readlink -f "$target")"
  if [[ -L "$link_path" ]]; then
    resolved_link="$(readlink -f "$link_path")"
    [[ "$resolved_link" == "$resolved_target" ]] \
      || fail "unexpected existing symlink: $link_path -> $resolved_link"
  elif [[ -e "$link_path" ]]; then
    fail "refusing to replace existing non-symlink path: $link_path"
  else
    ln -s "$target" "$link_path"
  fi
}

ensure_directory_link "$system_include_dir" "$netcdf_prefix/include"
ensure_directory_link "$system_lib_dir" "$netcdf_prefix/lib"
echo "NETCDF_MULTIARCH_PREFIX_OK: $netcdf_prefix"

env_assignment_ok() {
  local file="$1"
  local variable="$2"
  shift 2
  local value
  for value in "$@"; do
    if grep -Fxq "export $variable=\"$value\"" "$file" \
       || grep -Fxq "export $variable='$value'" "$file" \
       || grep -Fxq "export $variable=$value" "$file"; then
      return 0
    fi
  done
  return 1
}

# Compare literal shell assignments; do not expand variables from the caller.
# shellcheck disable=SC2016
environment_file_matches() {
  local file="$1"
  bash -n "$file" || return 1
  env_assignment_ok "$file" WRF_INSTALL "$base_dir" || return 1
  env_assignment_ok "$file" WRF_DIR '$WRF_INSTALL/WRF' "$wrf_dir" \
    || return 1
  env_assignment_ok "$file" WPS_DIR '$WRF_INSTALL/WPS' "$wps_dir" \
    || return 1
  env_assignment_ok "$file" NETCDF '$WRF_INSTALL/netcdf-system' \
    "$netcdf_prefix" || return 1
  env_assignment_ok "$file" NETCDF_C '$WRF_INSTALL/netcdf-system' \
    '$NETCDF' "$netcdf_prefix" || return 1
}

write_environment_file() {
  local target="$1"
  [[ ! -e "$target" ]] \
    || fail "refusing to overwrite existing environment file: $target"
  cat >"$target" <<EOF
#!/usr/bin/env bash
export WRF_INSTALL="$base_dir"
export WRF_DIR="\$WRF_INSTALL/WRF"
export WPS_DIR="\$WRF_INSTALL/WPS"
export NETCDF="\$WRF_INSTALL/netcdf-system"
export NETCDF_C="\$WRF_INSTALL/netcdf-system"
export WRFIO_NCD_LARGE_FILE_SUPPORT="1"
export NETCDF_classic="1"
export JASPERLIB="\$WPS_DIR/grib2/lib"
export JASPERINC="\$WPS_DIR/grib2/include"
export OMP_NUM_THREADS="1"
case ":\$PATH:" in
  *":\$WRF_DIR/main:"*) ;;
  *) PATH="\$WRF_DIR/main:\$PATH" ;;
esac
case ":\$PATH:" in
  *":\$WPS_DIR:"*) ;;
  *) PATH="\$WPS_DIR:\$PATH" ;;
esac
export PATH
case ":\${LD_LIBRARY_PATH:-}:" in
  *":\$JASPERLIB:"*) ;;
  *) LD_LIBRARY_PATH="\$JASPERLIB\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" ;;
esac
export LD_LIBRARY_PATH
EOF
  chmod 0644 "$target"
}

if [[ ! -e "$env_file" ]]; then
  write_environment_file "$env_file"
  echo "CREATED_ENVIRONMENT_FILE: $env_file"
elif environment_file_matches "$env_file"; then
  echo "EXISTING_ENVIRONMENT_FILE_RETAINED: $env_file"
else
  echo "WARNING: retaining incompatible existing environment file: $env_file"
  env_file="$base_dir/wrf_env_one_click.sh"
  if [[ ! -e "$env_file" ]]; then
    write_environment_file "$env_file"
    echo "CREATED_ALTERNATE_ENVIRONMENT_FILE: $env_file"
  elif environment_file_matches "$env_file"; then
    echo "EXISTING_ALTERNATE_ENVIRONMENT_FILE_RETAINED: $env_file"
  else
    fail "alternate environment file is also incompatible: $env_file"
  fi
fi
bash -n "$env_file"

toolchain_test() {
  cat >"$temp_dir/c_answer.c" <<'EOF'
int c_answer(void) { return 42; }
EOF

  cat >"$temp_dir/c_fortran_test.f90" <<'EOF'
program c_fortran_test
  use iso_c_binding
  implicit none
  interface
    integer(c_int) function c_answer() bind(C)
      use iso_c_binding
    end function c_answer
  end interface
  if (c_answer() /= 42) stop 1
  print *, "C_FORTRAN_OK"
end program c_fortran_test
EOF

  gcc -c "$temp_dir/c_answer.c" -o "$temp_dir/c_answer.o"
  gfortran "$temp_dir/c_fortran_test.f90" "$temp_dir/c_answer.o" \
    -o "$temp_dir/c_fortran_test"
  "$temp_dir/c_fortran_test"

  cat >"$temp_dir/netcdf_test.f90" <<EOF
program netcdf_test
  use netcdf
  implicit none
  integer :: ncid, status
  status = nf90_create("$temp_dir/netcdf_test.nc", NF90_CLOBBER, ncid)
  if (status /= nf90_noerr) stop 2
  status = nf90_close(ncid)
  if (status /= nf90_noerr) stop 3
  print *, "NETCDF_FORTRAN_OK"
end program netcdf_test
EOF

  gfortran "$temp_dir/netcdf_test.f90" \
    -I"$netcdf_prefix/include" \
    -L"$netcdf_prefix/lib" -lnetcdff -lnetcdf \
    -o "$temp_dir/netcdf_test"
  "$temp_dir/netcdf_test"
  ncdump -h "$temp_dir/netcdf_test.nc" >/dev/null

  cat >"$temp_dir/mpi_test.f90" <<'EOF'
program wrf_mpi_probe
  use mpi
  implicit none
  integer :: ierr, rank, nprocs
  call MPI_Init(ierr)
  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)
  call MPI_Comm_size(MPI_COMM_WORLD, nprocs, ierr)
  write(*,*) "MPI_OK", rank, nprocs
  call MPI_Finalize(ierr)
end program wrf_mpi_probe
EOF

  mpif90 "$temp_dir/mpi_test.f90" -o "$temp_dir/mpi_test"
  mpirun --bind-to none --oversubscribe -np 2 \
    "$temp_dir/mpi_test"
  echo "TOOLCHAIN_TESTS_PASSED"
}

toolchain_test

fatal_build_regex='undefined reference|collect2: error|ld returned [0-9]+ exit status|cannot find -l|No rule to make target|compilation terminated|fatal error:'

if ((wrf_force_clean)); then
  begin_wrf_run_layout_protection "$temp_dir/wrf-run-layout-resume"
  echo "Cleaning generated WRF build products for explicit --resume..."
  if (
    cd "$wrf_dir"
    ./clean -a
  ) >"$wrf_dir/clean_resume.log" 2>&1; then
    wrf_clean_rc=0
  else
    wrf_clean_rc=$?
  fi
  ((wrf_clean_rc == 0)) \
    || fail "WRF clean failed; see $wrf_dir/clean_resume.log"
fi

if ((wps_force_clean)); then
  echo "Cleaning generated WPS build products for explicit --resume..."
  if (
    cd "$wps_dir"
    ./clean -a
  ) >"$wps_dir/clean_resume.log" 2>&1; then
    wps_clean_rc=0
  else
    wps_clean_rc=$?
  fi
  ((wps_clean_rc == 0)) \
    || fail "WPS clean failed; see $wps_dir/clean_resume.log"
fi

if grib2_libs_ready; then
  echo "WPS_GRIB2_LIBRARIES_ALREADY_READY"
else
  echo "Building WPS-bundled zlib/libpng/JasPer..."
  if make -C "$wps_dir/external" -j "$jobs" \
      CC=gcc INTERNAL_GRIB2_PATH="$wps_dir/grib2" \
      >"$wps_dir/grib2-build.log" 2>&1; then
    grib2_rc=0
  else
    grib2_rc=$?
  fi
  if ((grib2_rc != 0)) || ! grib2_libs_ready; then
    fail "WPS GRIB2 libraries failed (rc=$grib2_rc); see $wps_dir/grib2-build.log"
  fi
  printf 'SUCCESS %s\n' "$(date -Is)" >"$wps_dir/grib2-build.status"
  echo "WPS_GRIB2_LIBRARIES_BUILT"
fi

if wrf_install_ready; then
  echo "WRF_EM_REAL_ALREADY_READY"
else
  echo "Configuring WRF: GNU dmpar (34), basic nesting (1)..."
  (
    cd "$wrf_dir"
    printf '34\n1\n' \
      | env -u JASPERLIB -u JASPERINC \
          NETCDF="$netcdf_prefix" \
          NETCDF_C="$netcdf_prefix" \
          WRFIO_NCD_LARGE_FILE_SUPPORT=1 \
          NETCDF_classic=1 \
          ./configure
  ) >"$wrf_dir/configure.log" 2>&1

  [[ -s "$wrf_dir/configure.wrf" ]] \
    || fail "WRF configure.wrf was not created"
  # GCC 15 defaults to C23; WRF 4.5.2 still uses pre-C23 declarations.
  # GCC 14+ also promotes legacy RSL pointer diagnostics to errors.
  # Apply only to generated GNU configuration, never to upstream source.
  sed -i -E \
    '/^(SCC|CCOMP|DM_CC)[[:space:]]*=/ s/$/ -std=gnu17 -Wno-error=incompatible-pointer-types/' \
    "$wrf_dir/configure.wrf"
  grep -Eq -- '-lnetcdff[[:space:]]+-lnetcdf' \
    "$wrf_dir/configure.wrf" \
    || fail "WRF configure omitted NetCDF-C/Fortran libraries"
  grep -Eq '^[[:space:]]*DMPARALLEL[[:space:]]*=[[:space:]]*1' \
    "$wrf_dir/configure.wrf" \
    || fail "WRF configure is not dmpar"
  grep -Eq '^[[:space:]]*DM_FC[[:space:]]*=[[:space:]]*mpif90' \
    "$wrf_dir/configure.wrf" \
    || fail "WRF configure does not use mpif90"
  grep -Eq '^[[:space:]]*DM_CC[[:space:]]*=[[:space:]]*mpicc' \
    "$wrf_dir/configure.wrf" \
    || fail "WRF configure does not use mpicc"
  grep -Fq "$netcdf_prefix" "$wrf_dir/configure.wrf" \
    || fail "WRF configure does not contain the compatibility NetCDF prefix"

  echo "Compiling WRF em_real with $jobs jobs..."
  wrf_build_marker="$temp_dir/wrf-em_real-build.marker"
  touch "$wrf_build_marker"
  if (
    cd "$wrf_dir"
    ./compile -j "$jobs" em_real
  ) >"$wrf_dir/compile.log" 2>&1; then
    wrf_compile_rc=0
  else
    wrf_compile_rc=$?
  fi

  wrf_targets_fresh=1
  if ((wrf_preexisting == 0 || wrf_force_clean == 1)) \
     && ! all_newer_than "$wrf_build_marker" "${wrf_targets[@]}"; then
    wrf_targets_fresh=0
  fi
  if ((wrf_compile_rc != 0)) \
     || ! all_executable "${wrf_targets[@]}" \
     || ((wrf_targets_fresh == 0)) \
     || ! wrf_install_ready \
     || ! grep -Fq "Executables successfully built" "$wrf_dir/compile.log"; then
    printf 'FAILED rc=%s %s\n' "$wrf_compile_rc" "$(date -Is)" \
      >"$wrf_dir/compile.status"
    fail "WRF build failed; see $wrf_dir/compile.log"
  fi
  if grep -Eiq "$fatal_build_regex" "$wrf_dir/compile.log"; then
    printf 'FAILED rc=%s %s\n' "$wrf_compile_rc" "$(date -Is)" \
      >"$wrf_dir/compile.status"
    fail "WRF compile log contains a fatal compiler/linker pattern"
  fi
  printf 'SUCCESS %s\n' "$(date -Is)" >"$wrf_dir/compile.status"
  echo "WRF_EM_REAL_BUILD_SUCCESS"
fi

if ((wrf_run_restore_active)) \
   && [[ "$wrf_run_restore_dir" == "$temp_dir/wrf-run-layout-resume" ]]; then
  restore_wrf_run_layout \
    || fail "could not restore the pre-resume WRF run layout"
fi

wps_ready=0
if wps_install_ready; then
  wps_ready=1
fi

if ((wps_ready)); then
  echo "WPS_ALREADY_READY"
else
  echo "Configuring WPS: GNU serial (1), internal GRIB2 libraries..."
  (
    cd "$wps_dir"
    printf '1\n' \
      | env NETCDF="$netcdf_prefix" \
          WRF_DIR="$wrf_dir" \
          ./configure --build-grib2-libs
  ) >"$wps_dir/configure.log" 2>&1

  [[ -s "$wps_dir/configure.wps" ]] \
    || fail "WPS configure.wps was not created"
  # WPS Makefiles pass SCC unquoted to the bundled-library submake.
  # Keep SCC as gcc, put compatibility switches in CFLAGS, and persist the
  # NetCDF prefix because later make invocations also need this variable.
  {
    printf '\n# Native Ubuntu GNU compatibility settings\n'
    printf 'NETCDF = %s\n' "$netcdf_prefix"
    printf 'CFLAGS += -std=gnu17 -Wno-error=incompatible-pointer-types -Wno-error=implicit-int\n'
  } >>"$wps_dir/configure.wps"
  grep -Fq -- "-DUSE_JPEG2000 -DUSE_PNG" "$wps_dir/configure.wps" \
    || fail "WPS configure omitted GRIB2 PNG/JPEG2000 flags"
  grep -Eq -- '-lnetcdff[[:space:]]+-lnetcdf' "$wps_dir/configure.wps" \
    || fail "WPS configure omitted NetCDF-C/Fortran libraries"
  grep -Eq '^[[:space:]]*SFC[[:space:]]*=[[:space:]]*gfortran' \
    "$wps_dir/configure.wps" \
    || fail "WPS configure does not use gfortran"
  grep -Eq '^[[:space:]]*SCC[[:space:]]*=[[:space:]]*gcc' \
    "$wps_dir/configure.wps" \
    || fail "WPS configure does not use gcc"
  grep -Fq "$wps_dir/grib2" "$wps_dir/configure.wps" \
    || fail "WPS configure does not contain the bundled GRIB2 path"
  grep -Fq "$wrf_dir" "$wps_dir/configure.wps" \
    || fail "WPS configure does not contain the current WRF directory"

  echo "Compiling WPS..."
  wps_build_marker="$temp_dir/wps-build.marker"
  touch "$wps_build_marker"
  if (
    cd "$wps_dir"
    ./compile
  ) >"$wps_dir/compile.log" 2>&1; then
    wps_compile_rc=0
  else
    wps_compile_rc=$?
  fi

  wps_targets_fresh=1
  if ((wps_preexisting == 0 || wps_force_clean == 1)) \
     && ! all_newer_than "$wps_build_marker" "${wps_targets[@]}"; then
    wps_targets_fresh=0
  fi
  if ((wps_compile_rc != 0)) \
     || ! all_executable "${wps_targets[@]}" \
     || ((wps_targets_fresh == 0)) \
     || ! wps_install_ready; then
    printf 'FAILED rc=%s %s\n' "$wps_compile_rc" "$(date -Is)" \
      >"$wps_dir/compile.status"
    fail "WPS build failed; see $wps_dir/compile.log"
  fi
  if grep -Eiq "$fatal_build_regex" "$wps_dir/compile.log"; then
    printf 'FAILED rc=%s %s\n' "$wps_compile_rc" "$(date -Is)" \
      >"$wps_dir/compile.status"
    fail "WPS compile log contains a fatal compiler/linker pattern"
  fi
  printf 'SUCCESS %s\n' "$(date -Is)" >"$wps_dir/compile.status"
  echo "WPS_BUILD_SUCCESS"
fi

verify_wps() {
  local executable name rc run_dir startup_summary=""
  local startup_files=()
  local verification_dir
  verification_dir="$verify_dir/wps_startup_$(date +%Y%m%dT%H%M%S)-$$"
  local verification_status="$wps_dir/verification_one_click.status"
  local status_tmp="$verification_status.tmp.$$"

  mkdir "$verification_dir"
  printf 'RUNNING %s\n' "$(date -Is)" >"$status_tmp"
  mv "$status_tmp" "$verification_status"
  active_status_file="$verification_status"
  active_status_context="OUTPUT_DIR=$verification_dir"

  for executable in "${wps_targets[@]}"; do
    name="$(basename "$executable")"
    [[ -x "$executable" ]] || fail "missing WPS executable: $executable"
    ldd "$executable" >"$verification_dir/ldd.$name" 2>&1
    if grep -Fq "not found" "$verification_dir/ldd.$name"; then
      fail "missing dynamic dependency for $executable"
    fi
  done

  strings "$wps_dir/ungrib.exe" >"$verification_dir/ungrib.strings"
  grep -Fq \
    "Linked in png and jpeg libraries for Grib Edition 2" \
    "$verification_dir/ungrib.strings" \
    || fail "ungrib.exe does not contain the GRIB2 build branch"

  nm "$wps_dir/ungrib.exe" >"$verification_dir/ungrib.symbols"
  grep -Eq "jas_stream_memopen" "$verification_dir/ungrib.symbols" \
    || fail "ungrib.exe does not contain a JasPer symbol"
  grep -Eq "png_create_read_struct" "$verification_dir/ungrib.symbols" \
    || fail "ungrib.exe does not contain a libpng symbol"

  run_dir="$verification_dir/g2print"
  mkdir "$run_dir"
  if (
    cd "$run_dir"
    timeout 10 "$wps_dir/util/g2print.exe" >g2print.out 2>&1
  ); then
    rc=0
  else
    rc=$?
  fi
  case "$rc" in
    124|125|126|127|137|139)
      fail "g2print.exe abnormal startup return code: $rc"
      ;;
  esac
  ((rc < 128)) || fail "g2print.exe terminated by a signal: rc=$rc"
  grep -Fq "Usage:" "$run_dir/g2print.out" \
    || fail "g2print.exe startup check failed"
  printf -v startup_summary '%sG2PRINT_RC=%s\n' "$startup_summary" "$rc"

  for name in geogrid ungrib metgrid; do
    run_dir="$verification_dir/$name"
    mkdir "$run_dir"
    if (
      cd "$run_dir"
      timeout 15 "$wps_dir/$name.exe" >"$name.out" 2>&1
    ); then
      rc=0
    else
      rc=$?
    fi
    case "$rc" in
      124|125|126|127|137|139)
        fail "$name.exe abnormal startup return code: $rc"
        ;;
    esac
    ((rc < 128)) || fail "$name.exe terminated by a signal: rc=$rc"

    shopt -s nullglob
    startup_files=("$run_dir/$name.out" "$run_dir"/*.log)
    shopt -u nullglob
    if grep -Eiq \
        "error while loading shared libraries|segmentation fault|symbol lookup error" \
        "${startup_files[@]}"; then
      fail "$name.exe failed before reaching its input checks"
    fi
    grep -Eiq \
      'error opening.*namelist\.wps|could not open.*namelist\.wps|namelist\.wps.*(not found|does not exist|cannot be opened)' \
      "${startup_files[@]}" \
      || fail "$name.exe did not reach the expected missing-namelist input check"
    printf -v startup_summary '%s%s_RC=%s\n' \
      "$startup_summary" "${name^^}" "$rc"
  done

  printf 'SUCCESS %s\n' "$(date -Is)" >"$status_tmp"
  mv "$status_tmp" "$verification_status"
  {
    echo "WPS_VERIFICATION_SUCCESS $(date -Is)"
    echo "GRIB2 compile branch, JasPer, PNG, loader and startup checks passed."
    printf '%s' "$startup_summary"
    echo "OUTPUT_DIR=$verification_dir"
    echo "Full geogrid->ungrib->metgrid data processing was not run."
  } >"$wps_dir/verification_one_click.log"
  active_status_file=""
  active_status_context=""
  echo "WPS_VERIFICATION_SUCCESS"
}

verify_wps

run_wrf_smoke() {
  local smoke_status="$verify_dir/wrf_em_quarter_ss_smoke.status"
  local case_dir="$wrf_dir/test/em_quarter_ss"
  local run_dir
  run_dir="$verify_dir/em_quarter_ss_run_$(date +%Y%m%dT%H%M%S)-$$"
  local smoke_log="$run_dir/smoke.log"
  local entry entry_name wrfout_file
  local final_wrfout=""
  local final_time="0001-01-01_01:00:00"
  local output_index=0
  local ideal_rc=0
  local wrf_rc=0
  local quarter_compile_rc=0
  local status_tmp="$smoke_status.tmp.$$"
  local support_names=(
    bulkdens.asc_s_0_03_0_9
    bulkradii.asc_s_0_03_0_9
    capacity.asc
    coeff_p.asc
    coeff_q.asc
    constants.asc
    kernels.asc_s_0_03_0_9
    kernels_z.asc
    masses.asc
    termvels.asc
  )
  local quarter_targets=(
    "$wrf_dir/main/ideal.exe"
    "$wrf_dir/main/wrf.exe"
    "$case_dir/ideal.exe"
    "$case_dir/wrf.exe"
  )
  local wrfout_files=()

  printf 'RUNNING %s\n' "$(date -Is)" >"$status_tmp"
  mv "$status_tmp" "$smoke_status"
  active_status_file="$smoke_status"
  active_status_context="RUN_DIR=$run_dir"

  begin_wrf_run_layout_protection "$temp_dir/wrf-run-layout-smoke"

  echo "Building WRF em_quarter_ss incrementally..."
  if (
    cd "$wrf_dir"
    ./compile -j "$jobs" em_quarter_ss
  ) >"$wrf_dir/compile_em_quarter_ss.log" 2>&1; then
    quarter_compile_rc=0
  else
    quarter_compile_rc=$?
  fi

  if ((quarter_compile_rc != 0)) \
     || ! all_executable "${quarter_targets[@]}" \
     || ! grep -Fq "Executables successfully built" \
        "$wrf_dir/compile_em_quarter_ss.log"; then
    printf 'FAILED rc=%s %s\n' "$quarter_compile_rc" "$(date -Is)" \
      >"$wrf_dir/compile_em_quarter_ss.status"
    fail "em_quarter_ss build failed; see $wrf_dir/compile_em_quarter_ss.log"
  fi
  if grep -Eiq "$fatal_build_regex" \
      "$wrf_dir/compile_em_quarter_ss.log"; then
    printf 'FAILED rc=%s %s\n' "$quarter_compile_rc" "$(date -Is)" \
      >"$wrf_dir/compile_em_quarter_ss.status"
    fail "em_quarter_ss compile log contains a fatal compiler/linker pattern"
  fi
  printf 'SUCCESS %s\n' "$(date -Is)" \
    >"$wrf_dir/compile_em_quarter_ss.status"

  mkdir "$run_dir"
  cp -L "$case_dir/namelist.input" "$case_dir/input_sounding" "$run_dir/"

  for entry_name in "${support_names[@]}"; do
    entry="$case_dir/$entry_name"
    [[ -f "$entry" ]] \
      || fail "missing em_quarter_ss support table: $entry"
    cp -L "$entry" "$run_dir/$entry_name"
  done
  ln -s "$wrf_dir/main/ideal.exe" "$run_dir/ideal.exe"
  ln -s "$wrf_dir/main/wrf.exe" "$run_dir/wrf.exe"

  : >"$smoke_log"
  echo "WRF smoke started: $(date -Is)" >>"$smoke_log"
  echo "RUN_DIR=$run_dir" >>"$smoke_log"
  cd "$run_dir"

  if timeout 300 mpirun --bind-to none --oversubscribe -np 1 ./ideal.exe \
      >ideal.console.log 2>&1; then
    ideal_rc=0
  else
    ideal_rc=$?
  fi
  echo "IDEAL_RETURN_CODE=$ideal_rc" >>"$smoke_log"

  [[ "$ideal_rc" -eq 0 ]] \
    || fail "ideal.exe returned $ideal_rc; see $run_dir/ideal.console.log"
  grep -Fq "SUCCESS COMPLETE IDEAL INIT" \
    rsl.error.0000 rsl.out.0000 \
    || fail "ideal.exe success marker not found"
  [[ -s wrfinput_d01 ]] || fail "ideal.exe did not create wrfinput_d01"
  ncdump -h wrfinput_d01 >/dev/null \
    || fail "wrfinput_d01 is not readable NetCDF"
  echo "IDEAL_SUCCESS wrfinput_d01=$(stat -c %s wrfinput_d01) bytes" \
    >>"$smoke_log"

  mv rsl.error.0000 ideal.rsl.error.0000
  mv rsl.out.0000 ideal.rsl.out.0000

  if timeout 900 mpirun --bind-to none --oversubscribe -np 2 ./wrf.exe \
      >wrf.console.log 2>&1; then
    wrf_rc=0
  else
    wrf_rc=$?
  fi
  echo "WRF_RETURN_CODE=$wrf_rc" >>"$smoke_log"

  [[ "$wrf_rc" -eq 0 ]] \
    || fail "wrf.exe returned $wrf_rc; see $run_dir/wrf.console.log"
  grep -Fq "SUCCESS COMPLETE WRF" rsl.error.0000 rsl.out.0000 \
    || fail "wrf.exe success marker not found"
  grep -Fq "$final_time" rsl.error.0000 rsl.out.0000 \
    || fail "WRF did not report the expected final model time: $final_time"

  shopt -s nullglob
  wrfout_files=("$run_dir"/wrfout_d01_*)
  shopt -u nullglob
  ((${#wrfout_files[@]} > 0)) || fail "wrf.exe did not create a wrfout file"

  for wrfout_file in "${wrfout_files[@]}"; do
    [[ -s "$wrfout_file" ]] || fail "wrfout file is empty: $wrfout_file"
    ncdump -h "$wrfout_file" >/dev/null \
      || fail "wrfout file is not readable NetCDF: $wrfout_file"
    output_index=$((output_index + 1))
    ncdump -v Times "$wrfout_file" \
      >"$run_dir/wrfout_times_$output_index.txt"
    if grep -Fq "$final_time" \
        "$run_dir/wrfout_times_$output_index.txt"; then
      final_wrfout="$wrfout_file"
    fi
  done
  [[ -n "$final_wrfout" ]] \
    || fail "no wrfout file contains the expected final time: $final_time"
  wrfout_file="$final_wrfout"

  echo "WRF_SUCCESS $wrfout_file=$(stat -c %s "$wrfout_file") bytes" \
    >>"$smoke_log"
  echo "WRF_SMOKE_SUCCESS $(date -Is)" >>"$smoke_log"
  restore_wrf_run_layout \
    || fail "could not restore the original WRF run layout"
  {
    printf 'SUCCESS %s\n' "$(date -Is)"
    printf 'RUN_DIR=%s\n' "$run_dir"
  } >"$status_tmp"
  mv "$status_tmp" "$smoke_status"
  active_status_file=""
  active_status_context=""
  echo "WRF_NUMERICAL_SMOKE_SUCCESS"
}

if ((skip_smoke)); then
  echo "WRF_NUMERICAL_SMOKE_SKIPPED"
else
  run_wrf_smoke
fi

echo "============================================================"
echo "INSTALLATION_SUCCESS $(date -Is)"
echo "Environment: source $env_file"
echo "WRF:         $wrf_dir"
echo "WPS:         $wps_dir"
echo "Verification:$verify_dir"
echo "Log:         $install_log"
echo "============================================================"
