#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Linux ]] || { echo 'Se requiere un equipo Linux para compilar.' >&2; exit 1; }
fvm install
fvm flutter pub get
fvm flutter analyze
fvm flutter test
fvm flutter build linux --release
mkdir -p dist
task_arch="$(uname -m)"
python3 tools/packaging/verify_linux_bundle.py build/linux/*/release/bundle
XZ_OPT="${XZ_OPT:--T2 -3}" tar -cJf "dist/Remina-Desktop-linux-${task_arch}.tar.xz" -C build/linux/*/release bundle
echo "Paquete completo: dist/Remina-Desktop-linux-${task_arch}.tar.xz"
