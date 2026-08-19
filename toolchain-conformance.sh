#!/usr/bin/env bash
# Per-ABI build-environment conformance guard for dk-distribute.
#
# Runs BEFORE the distribution script so a non-conforming build environment
# produces NO artifact. attest-build-provenance attests only artifacts of
# successful jobs, so a published attestation implies the build environment
# conformed to the ABI's toolchain contract.
#
# Inputs via environment variables:
#   INPUTTARGETABI      action input target-abi
#   INPUTEXECUTIONABI   action input execution-abi
#   INPUTDISTSCRIPT     action input distscript
#   INPUTSKIP           action input skip-toolchain-conformance
#   RUNNER_OS           GitHub default environment variable
#
# Usage: toolchain-conformance.sh [--self-test]
#
# Must stay bash 3.2 compatible (macOS runners): no associative arrays,
# no ${var,,} lowercasing.
set -u

GLIBC_MAX=2.28 # contract: slot artifacts run on glibc >= 2.28, so build on <= 2.28

# ---------- helpers ----------

fail_contract() {
  echo "::error title=toolchain conformance::$1"
  exit 1
}

notice() {
  echo "::notice title=toolchain conformance::$1"
}

# ---------- data table: ONE ROW PER ABI FAMILY ----------
# Format: <glob-pattern>|<space-separated check functions>
# ORDER MATTERS: the first matching row wins (musl before generic Linux).
# Adding an ABI family = adding a row (or extending a pattern), never a new
# script. An ABI matching no row gets an explicit "no conformance checks
# defined" notice, never silence.
CONFORMANCE_TABLE='
Linux_*_musl|check_linux_glibc_host check_linux_gcc_as note_musl_cross_toolchain
Linux_*|check_linux_glibc_host check_linux_gcc_as
Windows_*|check_windows_msvc
Darwin_*|check_darwin_clt
'

find_row() { # $1=abi -> prints the matching row, rc 1 if none
  local abi=$1 row pattern
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    pattern=${row%%|*}
    # shellcheck disable=SC2254  # the pattern must glob-expand in case
    case "$abi" in
      $pattern) printf '%s\n' "$row"; return 0 ;;
    esac
  done <<EOF
$CONFORMANCE_TABLE
EOF
  return 1
}

# ---------- ABI resolution ----------
# target-abi, else execution-abi, else the distscript basename when it names
# an ABI (ex. dist/Windows_x86_64.u -> Windows_x86_64). rc 1 when no ABI is
# declared anywhere (ex. dist/any.u data-only distributions).
resolve_abi() {
  if [ -n "${INPUTTARGETABI:-}" ]; then
    printf '%s\n' "$INPUTTARGETABI"
    return 0
  fi
  if [ -n "${INPUTEXECUTIONABI:-}" ]; then
    printf '%s\n' "$INPUTEXECUTIONABI"
    return 0
  fi
  local base
  base=$(basename "${INPUTDISTSCRIPT:-}")
  base=${base%%.*}
  case "$base" in
    Linux_* | Windows_* | Darwin_*)
      printf '%s\n' "$base"
      return 0
      ;;
  esac
  return 1
}

# ---------- glibc version parsing and comparison ----------

parse_glibc_version() { # $1=raw text -> prints major.minor, rc 1 if unparsable
  local v maj rest
  v=$(printf '%s\n' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | tail -n1)
  [ -n "$v" ] || return 1
  maj=${v%%.*}
  rest=${v#*.}
  printf '%s.%s\n' "$maj" "${rest%%.*}"
}

detect_glibc_version() { # prints major.minor of the host glibc, rc 1 if undetectable
  local raw=""
  if command -v getconf >/dev/null 2>&1; then
    raw=$(getconf GNU_LIBC_VERSION 2>/dev/null || true) # "glibc 2.28"
  fi
  if [ -z "$raw" ] && command -v ldd >/dev/null 2>&1; then
    # "ldd (Ubuntu GLIBC 2.35-0ubuntu3.8) 2.35": the last match on the first
    # line is the real version on every known format.
    raw=$(ldd --version 2>/dev/null | head -n1 || true)
  fi
  parse_glibc_version "$raw"
}

version_le() { # $1 <= $2 for NUMERIC major.minor versions (2.9 <= 2.28 is TRUE)
  local am bm an bn
  am=${1%%.*}; an=${1#*.}; an=${an%%.*}
  bm=${2%%.*}; bn=${2#*.}; bn=${bn%%.*}
  if [ "$am" -lt "$bm" ]; then return 0; fi
  if [ "$am" -gt "$bm" ]; then return 1; fi
  [ "$an" -le "$bn" ]
}

# ---------- per-family checks ----------

check_linux_glibc_host() { # $1=abi
  local found
  if ! found=$(detect_glibc_version); then
    fail_contract "the $1 slot requires a glibc <= $GLIBC_MAX build environment such as quay.io/pypa/manylinux_2_28_x86_64, but the host glibc could not be detected (getconf GNU_LIBC_VERSION and ldd --version are both unavailable or unparsable)"
  fi
  if ! version_le "$found" "$GLIBC_MAX"; then
    fail_contract "the $1 slot requires a glibc <= $GLIBC_MAX build environment such as quay.io/pypa/manylinux_2_28_x86_64 (glibc links are backward-compatible only: building on glibc $found would raise every consumer's runtime floor to $found); found glibc $found"
  fi
  echo "conforms: host glibc $found <= $GLIBC_MAX"
}

check_linux_gcc_as() { # $1=abi
  local t
  for t in gcc as; do
    if ! command -v "$t" >/dev/null 2>&1; then
      fail_contract "the $1 slot requires '$t' on PATH in the build environment (canonical: quay.io/pypa/manylinux_2_28_x86_64, which provides the gcc toolset); '$t' was not found"
    fi
  done
  echo "conforms: gcc and as resolve on PATH"
}

note_musl_cross_toolchain() { # $1=abi
  echo "note: the $1 musl cross toolchain is slot-bundled (fetched by the slot's own build values), so it has no host presence probe yet; refine this row against the slot layout when the musl slot is un-retired. The host checks above still apply: the DkML host tools are glibc-linked and musl builds run in the manylinux_2_28 container."
}

check_windows_msvc() { # $1=abi
  # bash cannot expand ${ProgramFiles(x86)} (parentheses are not valid in an
  # identifier), but printenv reads any environment variable name.
  local pf86 vswhere installdir
  pf86=$(printenv 'ProgramFiles(x86)' 2>/dev/null || true)
  [ -n "$pf86" ] || pf86='C:\Program Files (x86)'
  vswhere="$pf86\\Microsoft Visual Studio\\Installer\\vswhere.exe"
  if [ ! -f "$vswhere" ]; then
    fail_contract "the $1 slot requires a Visual Studio MSVC installation in version range [16.0,19.0) with Microsoft.VisualStudio.Component.VC.Tools.x86.x64 (canonical: a windows-latest GitHub runner); vswhere.exe was not found at '$vswhere'"
  fi
  # Quote '[16.0,19.0)' and '*': unquoted, * glob-expands against the working
  # directory. Mirrors CommonsLang_OCaml/assets/dkml/detect-vsenv.bat exactly.
  installdir=$("$vswhere" -latest -version '[16.0,19.0)' -products '*' \
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
    -property installationPath 2>/dev/null | head -n1 | tr -d '\r' || true)
  if [ -z "$installdir" ]; then
    fail_contract "the $1 slot requires a Visual Studio MSVC installation in version range [16.0,19.0) with Microsoft.VisualStudio.Component.VC.Tools.x86.x64 (canonical: a windows-latest GitHub runner with VS 2019 through VS 18 Build Tools); vswhere found none"
  fi
  echo "conforms: MSVC installation at $installdir"
}

check_darwin_clt() { # $1=abi
  local devdir sdkver
  devdir=$(xcode-select -p 2>/dev/null || true)
  if [ -z "$devdir" ]; then
    fail_contract "the $1 slot requires Xcode Command Line Tools ('xcode-select -p' must succeed; canonical: a macos-latest GitHub runner); no developer directory is selected"
  fi
  if ! /usr/bin/clang --version >/dev/null 2>&1; then
    fail_contract "the $1 slot requires a runnable /usr/bin/clang (Xcode Command Line Tools; canonical: a macos-latest GitHub runner)"
  fi
  sdkver=$(xcrun --show-sdk-version 2>/dev/null || echo unknown)
  echo "conforms: Xcode Command Line Tools at $devdir; SDK version (informational): $sdkver"
}

# ---------- runner-OS cross-check ----------

family_runner_os() { # $1=abi -> prints the RUNNER_OS the family requires
  case "$1" in
    Linux_*) echo Linux ;;
    Windows_*) echo Windows ;;
    Darwin_*) echo macOS ;;
  esac
}

check_runner_family() { # $1=resolved abi; also checks execution-abi when set
  local abi expect
  for abi in "$1" "${INPUTEXECUTIONABI:-}"; do
    [ -n "$abi" ] || continue
    expect=$(family_runner_os "$abi")
    if [ -n "$expect" ] && [ "${RUNNER_OS:-}" != "$expect" ]; then
      fail_contract "the $abi slot must be distributed from a $expect build environment, but this job runs on '${RUNNER_OS:-unknown}'. No dk ABI family is cross-OS today; fix the workflow matrix (runs-on or container) or the target-abi/execution-abi inputs."
    fi
  done
}

# ---------- main ----------

main() {
  if [ "${INPUTSKIP:-false}" = "true" ]; then
    echo "::warning title=toolchain conformance SKIPPED::skip-toolchain-conformance is 'true', so the per-ABI build-environment conformance guard was NOT run. This build's release attestation does NOT imply a conforming build environment."
    exit 0
  fi
  local abi row checks c
  if ! abi=$(resolve_abi); then
    notice "no conformance checks defined (no ABI declared): neither target-abi nor execution-abi is set and distscript '$(basename "${INPUTDISTSCRIPT:-}")' does not name a Linux_/Windows_/Darwin_ ABI. Data-only distributions build on any environment."
    exit 0
  fi
  if ! row=$(find_row "$abi"); then
    notice "no conformance checks defined for ABI '$abi' (no row in the conformance table). Add a row to toolchain-conformance.sh when this ABI family gains a toolchain contract."
    exit 0
  fi
  echo "toolchain conformance: ABI $abi matched row '${row%%|*}'"
  check_runner_family "$abi"
  checks=${row#*|}
  for c in $checks; do
    "$c" "$abi"
  done
  echo "toolchain conformance: PASS for $abi"
}

# ---------- self tests (pure functions only; run anywhere) ----------

TEST_FAILURES=0

t_eq() { # $1=description $2=expected $3=actual
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (expected '$2', got '$3')"
    TEST_FAILURES=1
  fi
}

t_rc() { # $1=description $2=expected rc $3=actual rc
  if [ "$2" -eq "$3" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (expected rc $2, got rc $3)"
    TEST_FAILURES=1
  fi
}

self_test() {
  local out rc

  # parse_glibc_version
  out=$(parse_glibc_version 'glibc 2.28') || true
  t_eq "parse getconf output" "2.28" "$out"
  out=$(parse_glibc_version 'ldd (Ubuntu GLIBC 2.35-0ubuntu3.8) 2.35') || true
  t_eq "parse ubuntu ldd output" "2.35" "$out"
  out=$(parse_glibc_version 'ldd (GNU libc) 2.28') || true
  t_eq "parse GNU ldd output" "2.28" "$out"
  rc=0; parse_glibc_version 'garbage' >/dev/null || rc=$?
  t_rc "parse garbage is rc 1" 1 "$rc"

  # version_le (numeric, never lexicographic)
  rc=0; version_le 2.28 2.28 || rc=$?
  t_rc "2.28 <= 2.28" 0 "$rc"
  rc=0; version_le 2.35 2.28 || rc=$?
  t_rc "2.35 > 2.28" 1 "$rc"
  rc=0; version_le 2.9 2.28 || rc=$?
  t_rc "2.9 <= 2.28 (numeric)" 0 "$rc"
  rc=0; version_le 2.100 2.28 || rc=$?
  t_rc "2.100 > 2.28" 1 "$rc"
  rc=0; version_le 1.99 2.28 || rc=$?
  t_rc "1.99 <= 2.28" 0 "$rc"
  rc=0; version_le 3.0 2.28 || rc=$?
  t_rc "3.0 > 2.28" 1 "$rc"

  # find_row: order and coverage
  out=$(find_row Linux_x86_64_musl) || true
  t_eq "musl row precedes generic Linux" "Linux_*_musl" "${out%%|*}"
  out=$(find_row Linux_arm64) || true
  t_eq "Linux_arm64 matches generic Linux row" "Linux_*" "${out%%|*}"
  out=$(find_row Windows_x86) || true
  t_eq "Windows_x86 matches Windows row" "Windows_*" "${out%%|*}"
  out=$(find_row Darwin_arm64) || true
  t_eq "Darwin_arm64 matches Darwin row" "Darwin_*" "${out%%|*}"
  rc=0; find_row FreeBSD_x86_64 >/dev/null || rc=$?
  t_rc "unknown ABI has no row" 1 "$rc"

  # resolve_abi precedence
  out=$(INPUTTARGETABI=Linux_x86 INPUTEXECUTIONABI=Darwin_arm64 INPUTDISTSCRIPT=dist/any.u; resolve_abi) || true
  t_eq "target-abi wins" "Linux_x86" "$out"
  out=$(INPUTTARGETABI= INPUTEXECUTIONABI=Darwin_arm64 INPUTDISTSCRIPT=dist/any.u; resolve_abi) || true
  t_eq "execution-abi is second" "Darwin_arm64" "$out"
  out=$(INPUTTARGETABI= INPUTEXECUTIONABI= INPUTDISTSCRIPT=dist/Windows_x86_64.u; resolve_abi) || true
  t_eq "distscript basename is third" "Windows_x86_64" "$out"
  rc=0; (INPUTTARGETABI= INPUTEXECUTIONABI= INPUTDISTSCRIPT=dist/any.u; resolve_abi) >/dev/null || rc=$?
  t_rc "dist/any.u with no ABI inputs resolves nothing" 1 "$rc"

  if [ "$TEST_FAILURES" -ne 0 ]; then
    echo "self-test: FAIL"
    exit 1
  fi
  echo "self-test: PASS"
}

case "${1:-}" in
  --self-test) self_test ;;
  *) main ;;
esac
