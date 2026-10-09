#!/usr/bin/env bash
set -euo pipefail
# Testbench IEEE/CAVS do người dùng cung cấp, đã cập nhật cho GHASH x2.
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tool_root=/workspace/.tools/final-prj/root/usr
compiler_args=()
if command -v iverilog >/dev/null && command -v vvp >/dev/null; then
    compiler=$(command -v iverilog)
    simulator=$(command -v vvp)
else
    compiler="$tool_root/bin/iverilog"
    simulator="$tool_root/bin/vvp"
    compiler_args=(-B "$tool_root/lib/x86_64-linux-gnu/ivl")
fi
if [[ ! -x "$compiler" || ! -x "$simulator" ]]; then
    echo 'Icarus Verilog is missing; run bash scripts/setup_sim.sh first.' >&2
    exit 1
fi
build_dir=$(mktemp -d /tmp/final-prj-user-tb.XXXXXX)
trap 'rm -rf -- "$build_dir"' EXIT
cd "$repo_root"
"$compiler" "${compiler_args[@]}" -g2012 -Wall -s tb_aes_xts_top \
    -o "$build_dir/tb.vvp" ./*.v tests/tb_aes_xts_top.v
"$simulator" "$build_dir/tb.vvp"
