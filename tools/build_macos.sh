#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'La compilación macOS requiere un Mac con Xcode.' >&2
  exit 1
fi
command -v fvm >/dev/null || { echo 'Instala FVM antes de continuar: dart pub global activate fvm' >&2; exit 1; }
# Build-machine input only; the resulting .app includes all non-system dylibs.
if [[ -z "${REMINA_FREERDP_SOURCE:-}" ]] && ! command -v sdl-freerdp >/dev/null && ! command -v sdl-freerdp3 >/dev/null; then
  command -v brew >/dev/null || { echo 'El empaquetado requiere FreeRDP 3 en el Mac de compilación (Homebrew o REMINA_FREERDP_SOURCE).' >&2; exit 1; }
  brew install freerdp
fi
fvm install
fvm flutter pub get
fvm flutter analyze
fvm flutter test
python3 -m unittest discover -s tools/packaging/tests
fvm flutter build macos --release
codesign --verify --deep --strict build/macos/Build/Products/Release/Remina.app
build/macos/Build/Products/Release/Remina.app/Contents/MacOS/remina-rdp /version
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent build/macos/Build/Products/Release/Remina.app dist/Remina-macos.zip
echo 'Paquete completo: dist/Remina-macos.zip'
echo 'El paquete incluye el motor RDP y sus dylibs; el equipo de destino no necesita Homebrew.' 
