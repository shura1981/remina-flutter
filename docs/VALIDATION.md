# Validación del paquete con dependencias

Verificación más reciente: análisis Dart sin incidencias, 52 pruebas Flutter aprobadas (1 fixture optativo omitido), 4 pruebas del empaquetador aprobadas. Build Linux debug y release completos. El motor incluido resolvió sus bibliotecas desde el paquete y arrancó en Ubuntu y Alpine sin FreeRDP instalado, en otra ruta y sin red. La interfaz se renderizó en contenedores Ubuntu y Alpine con pantalla Xvfb del equipo de pruebas, sin bibliotecas ni herramientas de desarrollo instaladas dentro del contenedor.

[Captura aislada](portable-linux.png). [Arquitectura del paquete y límites](PORTABLE_PACKAGING.md). También se verificó el archivo `dist/Remina-linux-x86_64.tar.xz` tras extraerlo en una carpeta nueva. `fvm flutter run -d linux --no-resident` pasó en modo debug con el motor empaquetado. El build macOS sigue pendiente de ejecución en un Mac; no se probó autenticación RDP ni gateway contra servidores del usuario.

---

# Validación local

Verificado el 18 de octubre de 2026 en Linux x86_64, usando FVM Flutter 3.47.7 / Dart 3.13.5.

| Comprobación | Resultado | Qué establece |
|---|---|---|
| `fvm flutter analyze` | Sin incidencias | Análisis estático de app, pruebas y utilidades |
| `fvm flutter test` | 49 aprobadas, 1 omitida deliberadamente | Parser, archivos, preferencias, editor, biblioteca, salida y servicios |
| Fixture SSH optativo | 1 prueba aprobada | Protocolo SSH real en localhost: handshake, huella/TOFU, contraseña, MFA, PTY, input, resize y cierre con diálogo abierto |
| Smoke FreeRDP 3.32.1 | Aprobado | El motor acepta los argumentos generados y stdin; intento fallido esperado en puerto localhost cerrado |
| Perfiles del usuario | 4/4 roundtrip exacto | Preservación del archivo y de claves al editar; originales intactos |
| `fvm flutter build linux --release` | Compilado | Binario y bundle Linux generados |
| Arranque nativo Linux | Verificado con display Xvfb aislado | Render de biblioteca y carga de perfiles sintéticos; sin datos del usuario |
| macOS | Pendiente | Se entregan runner, script y CI; este entorno no dispone de macOS/Xcode |

[Vista de la aplicación compilada](preview.png). Todos los equipos visibles en esa captura son de demostración con dominios `.invalid`.

## Repetir SSH de extremo a extremo

La suite normal omite esta prueba para no exigir Python ni abrir un listener en cada ejecución. Para activarla explícitamente:

```bash
python3 -m venv /tmp/remina-ssh-tests
/tmp/remina-ssh-tests/bin/pip install paramiko
REMINA_SSH_FIXTURE_PYTHON=/tmp/remina-ssh-tests/bin/python \
  fvm flutter test test/services/ssh_local_integration_test.dart --timeout 30s
```

El fixture `test/fixtures/ssh_echo_server.py` solo se enlaza a `127.0.0.1` en un puerto aleatorio y usa credenciales sintéticas. Los registros de confianza de prueba se guardan en directorios temporales y se eliminan al terminar. No usa los perfiles reales ni el llavero del usuario.

## Repetir la prueba del motor RDP

Con FreeRDP 3 instalado y una sesión gráfica:

```bash
fvm dart run tools/rdp_smoke.dart /ruta/a/sdl-freerdp
```

En un entorno Linux sin pantalla:

```bash
xvfb-run -a fvm dart run tools/rdp_smoke.dart /ruta/a/xfreerdp
```

El resultado correcto es que FreeRDP intente conectar a un puerto local cerrado y devuelva un fallo de conexión. Esta prueba diferencia un fallo de conexión esperado de argumentos inválidos; **no prueba una sesión RDP, un servidor Windows ni un gateway**.

## Dependencias del build Linux de esta sesión

El equipo tenía GTK y libsecret de ejecución, pero faltaban los headers de libsecret. Se descargaron/extrajeron los paquetes de desarrollo a `/tmp/remina-linux-deps`, sin instalación global. El build se completó con `PKG_CONFIG_PATH` apuntando al prefijo temporal. En una instalación normal basta instalar `libsecret-1-dev` junto a las dependencias de Flutter Linux indicadas en README. Este prefijo temporal no forma parte del código ni es necesario en macOS.

No se publicaron builds ni se ejecutó GitHub Actions desde esta sesión. Los archivos de workflow solo preparan una ruta repetible de compilación.
