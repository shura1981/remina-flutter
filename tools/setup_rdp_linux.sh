#!/usr/bin/env bash
# Prepare a FreeRDP 3 BUILD INPUT for this developer, without root. System
# libraries must already be available (Remmina normally provides them).
set -euo pipefail
if [[ "$(uname -s)" != Linux ]]; then
  echo 'Este script prepara FreeRDP exclusivamente en Linux.' >&2
  exit 1
fi
for task_command in apt-cache apt-get dpkg-deb ldd install; do
  command -v "$task_command" >/dev/null || { echo "Falta $task_command. Usa el gestor de paquetes de tu distribución para instalar FreeRDP 3." >&2; exit 1; }
done
task_package=''
for task_candidate in freerdp-x11 freerdp3-x11; do
  task_version="$(LC_ALL=C apt-cache policy "$task_candidate" | awk '/Candidate:/ {print $2}')"
  if [[ "$task_version" == 3.* ]]; then
    task_package="$task_candidate"
    break
  fi
done
if [[ -z "$task_package" ]]; then
  echo 'No hay un paquete FreeRDP 3 en los índices APT. Actualízalos con sudo apt-get update.' >&2
  exit 1
fi
task_work="$(mktemp -d)"
trap 'rm -rf "$task_work"' EXIT
cd "$task_work"
apt-get download "$task_package"
for task_archive in ./*.deb; do
  dpkg-deb -x "$task_archive" extracted
done
task_binary=''
for task_name in xfreerdp xfreerdp3; do
  if [[ -x "extracted/usr/bin/$task_name" ]]; then
    task_binary="extracted/usr/bin/$task_name"
    break
  fi
done
if [[ -z "$task_binary" ]]; then
  echo "El paquete $task_package no contiene el cliente. Instálalo con sudo apt-get install $task_package para resolver sus dependencias." >&2
  exit 1
fi
task_libraries="$(ldd "$task_binary")"
if [[ "$task_libraries" == *'not found'* ]]; then
  echo "$task_libraries" >&2
  echo "Faltan bibliotecas del sistema. Instala el paquete completo: sudo apt-get install $task_package" >&2
  exit 1
fi
"$task_binary" /version
task_destination="${HOME:?}/.local/share/remina/engines/freerdp"
install -d "$task_destination/bin" "$task_destination/licenses"
install -m 755 "$task_binary" "$task_destination/bin/xfreerdp"
for task_copyright in extracted/usr/share/doc/*/copyright \
  /usr/share/doc/libfreerdp3-3/copyright \
  /usr/share/doc/libfreerdp-client3-3/copyright; do
  if [[ -f "$task_copyright" ]]; then
    install -m 644 "$task_copyright" "$task_destination/licenses/$(basename "$(dirname "$task_copyright")")-copyright"
  fi
done
echo "Motor RDP instalado en $task_destination/bin/xfreerdp"
echo 'Entrada de compilación preparada. CMake copiará el motor y sus bibliotecas al paquete; el equipo de destino no necesita este script.'
