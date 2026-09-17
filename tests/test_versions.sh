#!/usr/bin/env bash
# Offline regression checks for version selection and pinned source manifests.
set -Eeuo pipefail
export LC_ALL=C
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_dir"
installer="$repo_dir/install_wrf_wps.sh"
# /tmp may be a small tmpfs; preflight requires 10 GiB on the build filesystem.
mkdir -p "$repo_dir/installations"
test_dir="$(mktemp -d "$repo_dir/installations/.version-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

expect_exit() {
  local expected="$1" rc=0
  shift
  bash "$installer" "$@" >"$test_dir/result.log" 2>&1 || rc=$?
  if ((rc != expected)); then
    cat "$test_dir/result.log" >&2
    echo "Expected $expected, got $rc: $*" >&2
    exit 1
  fi
}

bash ./install_wrf_wps.sh --help >"$test_dir/help"
grep -Fq -- '--wrf-version V' "$test_dir/help"
grep -Fq -- '--list-versions' "$test_dir/help"
bash ./install_wrf_wps.sh --list-versions >"$test_dir/list"
grep -Fxq 'WRF 4.8.0 -> WPS 4.7.0' "$test_dir/list"
grep -Fxq 'WRF 4.5.2 -> WPS 4.5' "$test_dir/list"

awk '
  /^#/ || NF == 0 {next}
  NF != 4 {exit 1}
  $1 !~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/ {exit 1}
  $2 !~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/ {exit 1}
  length($3) != 40 || $3 !~ /^[0-9a-f]+$/ {exit 1}
  length($4) != 40 || $4 !~ /^[0-9a-f]+$/ {exit 1}
  seen[$1]++ {exit 1}
  {count++}
  END {if (count < 1) exit 1}
' versions.tsv
awk '
  /^#/ || NF == 0 {next}
  NF != 2 {exit 1}
  length($1) != 64 || $1 !~ /^[0-9a-f]+$/ {exit 1}
  $2 !~ /^(v[0-9.]+|WPS-[0-9.]+)\.tar\.gz$/ {exit 1}
  seen[$2]++ {exit 1}
  {count++}
  END {if (count < 2) exit 1}
' checksums.sha256
while read -r wrf_version wps_version _ _; do
  [[ -n "$wrf_version" && "$wrf_version" != \#* ]] || continue
  for archive in "v$wrf_version.tar.gz" "WPS-$wps_version.tar.gz"; do
    [[ "$(awk -v name="$archive" '$2 == name {n++} END {print n+0}' checksums.sha256)" == 1 ]]
  done
done <versions.tsv

expect_exit 2 --wrf-version
expect_exit 2 --wrf-version 9.99 --base "$test_dir/must-not-be-created"
grep -Fq 'unsupported or duplicate WRF version' "$test_dir/result.log"
[[ ! -e "$test_dir/must-not-be-created" ]]
expect_exit 2 --jobs 0
expect_exit 2 --source-method unsupported
expect_exit 2 --base "$test_dir/nonexistent"
mkdir "$test_dir/with spaces"
expect_exit 2 --base "$test_dir/with spaces"

# These preflight checks stop before dependency installation or downloads.
for version in 4.8 4.8.0 v4.8.0 V4.8.0; do
  expect_exit 1 --wrf-version "$version" --base "$test_dir" --offline --skip-apt
  grep -Fq 'offline archive mode requires:' "$test_dir/result.log"
  grep -Fq '/v4.8.0.tar.gz' "$test_dir/result.log"
done
expect_exit 1 --wrf-version 4.5.2 --base "$test_dir" --offline --skip-apt
grep -Fq '/v4.5.2.tar.gz' "$test_dir/result.log"

# Exercise runtime catalog failures using an isolated copy of the installer.
mkdir "$test_dir/fixture"
cp install_wrf_wps.sh versions.tsv checksums.sha256 "$test_dir/fixture/"
installer="$test_dir/fixture/install_wrf_wps.sh"
awk '$1 == "4.8.0" {print}' versions.tsv >>"$test_dir/fixture/versions.tsv"
expect_exit 2 --wrf-version 4.8 --base "$test_dir/must-not-be-created"
grep -Fq 'unsupported or duplicate WRF version' "$test_dir/result.log"
[[ ! -e "$test_dir/must-not-be-created" ]]
cp versions.tsv "$test_dir/fixture/versions.tsv"
awk '$2 != "v4.8.0.tar.gz"' checksums.sha256 >"$test_dir/fixture/checksums.sha256"
expect_exit 1 --wrf-version 4.8 --base "$test_dir" --offline --skip-apt
grep -Fq 'invalid or duplicate WRF entry' "$test_dir/result.log"
installer="$repo_dir/install_wrf_wps.sh"

mkdir "$test_dir/WRF"
for version in 4.5.2 4.8.00; do
  printf 'WRF Model Version %s\n' "$version" >"$test_dir/WRF/README"
  expect_exit 1 --wrf-version 4.8.0 --base "$test_dir" --offline --skip-apt --resume
  grep -Fq 'is not WRF 4.8.0' "$test_dir/result.log"
done
printf 'VERSION_REGRESSION_CHECKS_PASSED\n'
