#!/usr/bin/env bash
# Install host-side dependencies on AlmaLinux/RHEL-compatible systems.
set -euo pipefail

image="docker.io/efabless/openlane:2023.12.26"
pdk_commit="0fe599b2afb6708d281543108caf8310912f54af"

if ! command -v dnf >/dev/null 2>&1; then
    echo "Script này dành cho AlmaLinux/RHEL có dnf."
    exit 1
fi

sudo dnf install -y \
    podman git python3 python3-pip ripgrep \
    findutils coreutils tar unzip xz

python3 -m pip install --user --upgrade --no-cache-dir volare
export PATH="$HOME/.local/bin:$PATH"

volare enable --pdk sky130 "$pdk_commit"
podman pull "$image"

echo "Đã cài host tools, PDK snapshot và OpenLane image."
podman --version
python3 --version
volare --version

