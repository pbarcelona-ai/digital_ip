#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# install_tools.sh - install the EDA tools used by the CI workflow (and usable
# on a developer machine).
#
# Usage: tools/ci/install_tools.sh <component> [<component> ...]
#   components: iverilog  verilator  yosys  sv2v
#
#   Linux (Debian/Ubuntu): apt packages; sv2v from the GitHub release.
#     On Ubuntu 24.04 apt provides Icarus Verilog 12.0, Verilator 5.020 and
#     Yosys 0.33 - the versions this repository was developed and tested with.
#   macOS: Homebrew (icarus-verilog, verilator, yosys, sv2v). Homebrew's Yosys
#     is much newer than 0.33; see README, "macOS".
#
# Environment: SV2V_VERSION (default v0.0.12), SV2V_DIR (install dir on Linux,
#              default /usr/local/bin), SV2V_FORCE=1 (reinstall even if found).
# Works with bash 3.2. Prints the installed versions at the end.
# -----------------------------------------------------------------------------
set -euo pipefail

SV2V_VERSION="${SV2V_VERSION:-v0.0.12}"
SV2V_DIR="${SV2V_DIR:-/usr/local/bin}"
[ $# -gt 0 ] || { sed -n '3,18p' "$0"; exit 2; }

SUDO=""
if [ "$(id -u)" != 0 ] && command -v sudo >/dev/null 2>&1; then SUDO=sudo; fi

pkgs=""; want_sv2v=0
for c in "$@"; do
  case "$c" in
    iverilog)  pkgs="$pkgs iverilog" ;;
    verilator) pkgs="$pkgs verilator" ;;
    yosys)     pkgs="$pkgs yosys" ;;
    sv2v)      want_sv2v=1 ;;
    *) echo "install_tools.sh: unknown component '$c'" >&2; exit 2 ;;
  esac
done

case "$(uname -s)" in
  Linux)
    if [ -n "$pkgs" ]; then
      $SUDO apt-get update -qq
      # shellcheck disable=SC2086
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs
    fi
    if [ $want_sv2v = 1 ]; then
      have=""; command -v sv2v >/dev/null 2>&1 && have="$(sv2v --version 2>&1 | head -1)"
      if [ "${SV2V_FORCE:-0}" != 1 ] && [ "$have" = "sv2v $SV2V_VERSION" ]; then
        echo "install_tools.sh: sv2v $SV2V_VERSION already installed"
      else
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/sv2v.XXXXXX")"
        url="https://github.com/zachjs/sv2v/releases/download/$SV2V_VERSION/sv2v-Linux.zip"
        echo "install_tools.sh: downloading $url"
        curl -fsSL -o "$tmp/sv2v.zip" "$url"
        unzip -q -o "$tmp/sv2v.zip" -d "$tmp"
        $SUDO mkdir -p "$SV2V_DIR"
        $SUDO install -m 0755 "$tmp/sv2v-Linux/sv2v" "$SV2V_DIR/sv2v"
        rm -rf "$tmp"
      fi
    fi
    ;;
  Darwin)
    command -v brew >/dev/null 2>&1 || { echo "install_tools.sh: Homebrew not found" >&2; exit 1; }
    brew_pkgs=""
    for p in $pkgs; do
      case "$p" in iverilog) brew_pkgs="$brew_pkgs icarus-verilog" ;; *) brew_pkgs="$brew_pkgs $p" ;; esac
    done
    [ $want_sv2v = 1 ] && brew_pkgs="$brew_pkgs sv2v"
    # shellcheck disable=SC2086
    [ -z "$brew_pkgs" ] || HOMEBREW_NO_AUTO_UPDATE=1 brew install $brew_pkgs
    ;;
  *) echo "install_tools.sh: unsupported OS $(uname -s)" >&2; exit 1 ;;
esac

# first line of a command's output; never fails (a pipe into "head" would trip
# "set -o pipefail" when the command is still writing)
first_line() {
  local out
  out="$("$@" 2>&1 || true)"
  printf '%s\n' "${out%%$'\n'*}"
}

echo "---- installed tool versions"
for c in "$@"; do
  case "$c" in
    iverilog)  first_line iverilog -V ;;
    verilator) first_line verilator --version ;;
    yosys)     first_line yosys -V ;;
    sv2v)      first_line sv2v --version ;;
  esac
done
