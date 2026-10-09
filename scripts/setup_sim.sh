#!/usr/bin/env bash
set -euo pipefail
# Local tools; preserve repository sources and the system package database.
tool_root=/workspace/.tools/final-prj
mkdir -p "$tool_root"/apt/{lists/partial,archives/partial,parts} "$tool_root/downloads" "$tool_root/root"
if ! command -v iverilog >/dev/null && [[ ! -x "$tool_root/root/usr/bin/iverilog" ]]; then
  test -r /usr/share/keyrings/debian-archive-keyring.gpg
  cat > "$tool_root/apt/sources.list" <<'EOF'
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian trixie main
EOF
  cat > "$tool_root/apt/apt.conf" <<EOF
Dir::Etc::Parts "$tool_root/apt/parts";
Dir::Etc::sourcelist "$tool_root/apt/sources.list";
Dir::Etc::sourceparts "$tool_root/apt/parts";
Dir::State::lists "$tool_root/apt/lists";
Dir::Cache::archives "$tool_root/apt/archives";
APT::Get::List-Cleanup "0";
EOF
  APT_CONFIG="$tool_root/apt/apt.conf" /usr/bin/apt-get update
  (cd "$tool_root/downloads"
   APT_CONFIG="$tool_root/apt/apt.conf" /usr/bin/apt-get download iverilog=12.0-2+b1
   dpkg-deb -x iverilog_12.0-2+b1_amd64.deb "$tool_root/root")
fi
if [[ ! -x "$tool_root/venv/bin/python" ]]; then
  python3 -m venv "$tool_root/venv"
fi
"$tool_root/venv/bin/python" -m pip install --disable-pip-version-check --no-cache-dir cryptography==50.0.0 cffi==2.1.1 pycparser==3.1
"$tool_root/venv/bin/python" -c 'from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes; print("Python AES reference ready")'
