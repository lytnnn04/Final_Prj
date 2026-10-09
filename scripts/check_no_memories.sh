#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if command -v yosys >/dev/null; then
    yosys_binary=$(command -v yosys)
else
    yosys_binary=/workspace/.tools/final-prj/root/usr/bin/yosys
fi
if [[ ! -x "$yosys_binary" ]]; then
    echo 'Yosys is missing; run bash scripts/setup_sim.sh first.' >&2
    exit 1
fi
cd "$repo_root"
"$yosys_binary" -T -s scripts/check_no_memories.ys
