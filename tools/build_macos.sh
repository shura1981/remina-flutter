#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'La compilación macOS requiere un Mac con Xcode.' >&2
  exit 1
fi
command -v fvm >/dev/null || { echo 'Instala FVM antes de continuar: dart pub global activate fvm' >&2; exit 1; }
fvm install
fvm flutter pub get
fvm flutter analyze
fvm flutter test
fvm flutter build macos --release
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent build/macos/Build/Products/Release/Remina.app dist/Remina-macos.zip
echo 'Aplicación: build/macos/Build/Products/Release/Remina.app'
echo 'Paquete: dist/Remina-macos.zip'
echo 'Para RDP, instala FreeRDP 3 en este Mac: brew install freerdp'
