#!/usr/bin/env bash
# Installs the native build dependencies for Flutter and secure storage.
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
  echo 'Este script prepara exclusivamente el entorno Linux.' >&2
  exit 1
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --check ) ]]; then
  echo 'Uso: tools/setup_linux.sh [--check]' >&2
  exit 2
fi

check_dependencies() {
  local task_missing=0
  for task_command in clang cmake ninja pkg-config g++ python3 readelf; do
    if ! command -v "$task_command" >/dev/null; then
      echo "Falta herramienta: $task_command" >&2
      task_missing=1
    fi
  done
  if command -v pkg-config >/dev/null; then
    for task_module in 'gtk+-3.0' 'libsecret-1 >= 0.18.4'; do
      if ! pkg-config --exists "$task_module"; then
        echo "Falta dependencia de desarrollo: $task_module" >&2
        task_missing=1
      fi
    done
  fi
  if ! command -v xfreerdp3 >/dev/null && ! command -v xfreerdp >/dev/null && [[ ! -x "${HOME}/.local/share/remina/engines/freerdp/bin/xfreerdp" && -z "${REMINA_FREERDP_SOURCE:-}" ]]; then
    echo 'Falta FreeRDP 3 como entrada de compilación (se incluirá en el paquete final).' >&2
    task_missing=1
  fi
  for task_runtime in /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf /usr/share/glib-2.0/schemas/gschemas.compiled; do
    if [[ ! -f "$task_runtime" ]]; then
      echo "Falta recurso de compilación: $task_runtime" >&2
      task_missing=1
    fi
  done
  return "$task_missing"
}

if check_dependencies; then
  echo 'Dependencias Linux disponibles. Ejecuta: fvm flutter run -d linux'
  exit 0
fi

if [[ "${1:-}" == --check ]]; then
  echo 'En Ubuntu/Debian ejecuta tools/setup_linux.sh para instalarlas.' >&2
  exit 1
fi
if ! command -v apt-get >/dev/null; then
  echo 'Instala clang, CMake, Ninja, pkg-config, GTK 3 y los headers de libsecret con el gestor de tu distribución.' >&2
  exit 1
fi

task_privilege=()
if [[ "$(id -u)" != 0 ]]; then
  command -v sudo >/dev/null || { echo 'La instalación requiere root o sudo.' >&2; exit 1; }
  task_privilege=(sudo)
fi
"${task_privilege[@]}" apt-get update
"${task_privilege[@]}" apt-get install -y \
  python3 binutils clang cmake ninja-build pkg-config g++ libgtk-3-dev libsecret-1-dev libegl1 libgles2 libgl1-mesa-dri fonts-dejavu-core ca-certificates gsettings-desktop-schemas freerdp3-x11
check_dependencies
echo 'Preparación completa. Ejecuta: fvm flutter run -d linux'
