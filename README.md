# Remina · Personal Edition

Cliente personal para macOS y Linux, escrito en **Flutter 3.47.7** con **FVM**. Biblioteca de conexiones compatible con `.remmina`, editor, grupos, búsqueda, favoritos, conexión rápida y sesiones SSH integradas.

**La distribución incluye el motor RDP y sus bibliotecas. El equipo donde se ejecuta no necesita instalar FreeRDP, Homebrew, Flutter ni dependencias de desarrollo.** El escritorio RDP sigue apareciendo en una ventana propia; integrarlo dentro de la pestaña Flutter continúa pendiente.

![Aplicación en un contenedor limpio, sin FreeRDP instalado](docs/portable-linux.png)

## Usar el paquete compilado

**Linux:** extrae `dist/Remina-linux-x86_64.tar.xz` y ejecuta `bundle/remina`. Copia la carpeta **completa**, no únicamente ese archivo. Incluye FreeRDP 3, GTK/GLib, libsecret, bibliotecas gráficas Mesa/EGL, fuentes, certificados y el cargador ELF. Se necesita un escritorio Linux compatible con la arquitectura del paquete; no es un servidor gráfico ni un controlador del kernel.

**macOS:** el script de compilación produce `dist/Remina-macos.zip`. Extrae y copia `Remina.app` a Aplicaciones. El helper se guarda en `Contents/MacOS` y sus dylibs en `Contents/Frameworks/ReminaRdp`. Las rutas a bibliotecas se reescriben para quedar dentro de la app. El paquete es para la arquitectura del Mac que lo compila; su versión mínima de macOS se ajusta a la exigida por las bibliotecas incluidas. **Este empaquetado aún requiere validación real en un Mac.**

El motor se busca exclusivamente dentro del paquete. La app no toma otra versión de `PATH`, de Homebrew ni del directorio del usuario. Una distribución incompleta se informa antes de pedir la contraseña.

## Compilar desde código fuente

Estas herramientas se necesitan **solo en el equipo de desarrollo**, donde se compila y se arma el paquete; no en los equipos de destino.

### Linux

En Ubuntu/Debian:

```bash
tools/setup_linux.sh
fvm install
fvm flutter pub get
fvm flutter run -d linux
```

CMake incluye automáticamente el motor y las bibliotecas al montar el bundle, tanto en debug como en release. Si falta un recurso necesario, el build falla. La entrada de FreeRDP puede ser el cliente instalado en el equipo de compilación, `REMINA_FREERDP_SOURCE=/ruta/a/xfreerdp` o la copia local que prepara `tools/setup_rdp_linux.sh`. Ninguna de esas rutas se conserva como dependencia en la distribución final.

Para generar el archivo que se puede copiar a otro equipo:

```bash
tools/build_linux.sh
```

Salida: `dist/Remina-linux-<arquitectura>.tar.xz`, con permisos de ejecución preservados. La carpeta `build/linux/<plataforma>/release/bundle` también se puede trasladar completa.

### macOS

Requiere Xcode, Python 3, FVM y una entrada FreeRDP 3 en el equipo de compilación. El script puede preparar esa entrada con Homebrew; también puedes proporcionar `REMINA_FREERDP_SOURCE` de una compilación propia.

```bash
dart pub global activate fvm
tools/build_macos.sh
```

El paso nativo de Xcode copia el helper, recorre y copia las dylibs no provistas por macOS, corrige sus referencias y firma el código incluido. Xcode firma después la app exterior. Las comprobaciones de firma se ejecutan antes de producir el ZIP. La firma para distribución y la notarización dependen de la configuración del desarrollador; el proyecto está destinado al uso personal y tiene App Sandbox desactivado.

## Traer tus conexiones

1. Copia tus archivos `~/.local/share/remmina/*.remmina` desde Linux.
2. Pulsa **Importar** y selecciónalos. En Linux puedes usar **Importar Remmina de este equipo**.
3. Conecta con doble clic y escribe la contraseña. Puedes guardarla en el llavero del nuevo equipo.

La app usa copias propias y conserva los archivos originales, claves desconocidas, comentarios, secciones y escapes GLib. **Exportar .remmina** produce archivos legibles por Remmina. Las rutas de llaves SSH y carpetas compartidas se deben adaptar al nuevo equipo.

`password=.` hace referencia al llavero original; no transfiere su contraseña. Las credenciales cifradas de Remmina se conservan como datos opacos y se vuelven a solicitar al conectar. Las contraseñas nuevas se guardan opcionalmente en el llavero del sistema, nunca como texto plano en `.remmina`. Si el sistema no ofrece un servicio de llavero, la conexión funciona sin guardar contraseñas.

## Funciones y límites

| Función | Estado |
|---|---|
| Biblioteca | Grupos/lista, búsqueda, favoritos, recientes, editar, duplicar y borrar copias |
| SSH | Terminal Flutter, PTY, resize, portapapeles, contraseña/llave y MFA |
| Confianza SSH | Huella SHA256 en primer acceso y rechazo de cambios posteriores; registro propio |
| RDP | Helper incluido con sus bibliotecas; ventana separada y control desde la pestaña |
| Ajustes RDP | Usuario/dominio, resolución, escala, color estándar, seguridad, clipboard, certificados, audio, carpeta, impresora, consola, multimonitor y reconexión |
| Gateway | Mapeo de configuración implementado; falta prueba contra un gateway real |
| Otras configuraciones | Se conservan en los archivos aunque no estén implementadas |
| Pendiente | RDP dentro de Flutter, VNC/SFTP/SPICE, túneles, agente SSH, GSSAPI y canales/dispositivos avanzados |

Los perfiles con túneles o comandos proxy/hooks no implementados se rechazan. `resolution_mode`: `0=personalizada`, `1=cliente`, `2=ventana inicial`; `scale=2` activa la resolución dinámica. `colordepth=99` conserva la negociación de FreeRDP. `cert_ignore=0` exige validación del certificado; `1` respeta la decisión del perfil de omitirla.

La contraseña RDP se pasa por stdin, fuera de los argumentos del proceso. El estado de la pestaña indica si el helper está activo; la autenticación se muestra en su ventana. Cerrar una pestaña desconecta; la salida normal de la app solicita confirmación cuando hay sesiones.

## Verificación del empaquetado

```bash
fvm flutter analyze
fvm flutter test
python3 -m unittest discover -s tools/packaging/tests
python3 tools/packaging/verify_linux_bundle.py build/linux/x64/release/bundle
python3 tools/packaging/verify_linux_bundle.py build/linux/x64/release/bundle --container alpine:latest
```

Para probar también interfaz y arranque RDP en un contenedor limpio (Docker y Xvfb solo en el equipo de pruebas):

```bash
python3 tools/packaging/smoke_isolated_linux.py build/linux/x64/release/bundle --image alpine:latest
```

El smoke usa un puerto loopback cerrado y credenciales ficticias; no se conecta a tus servidores. El manifiesto incluye hashes de los archivos distribuidos. La verificación comprueba que el cargador resuelva las bibliotecas dentro del paquete. [Detalles y límites de validación](docs/VALIDATION.md).

[GitHub Actions](.github/workflows/desktop.yml) prepara builds y comprobaciones para Linux/macOS; no se ha ejecutado remotamente desde esta sesión. Windows todavía no tiene runner ni distribución.

## Ícono e investigación

El ícono combina la identidad de Remmina con un rostro inspirado en Finder. [Assets, master y prompts](assets/branding/README.md).

La investigación original se hizo sobre Remmina 1.4.43 y su plugin RDP mediante REA MCP + Hopper. [Informe](docs/reverse-engineering/REPORT.md) e [índice de evidencias](docs/reverse-engineering/evidence.json). El código Flutter es una implementación nueva. El análisis estático no equivale a observar todas las funciones en ejecución.

Referencias primarias: [FreeRDP](https://github.com/FreeRDP/FreeRDP), [configuración Remmina](https://remmina.gitlab.io/remminadoc.gitlab.io/md__builds__remmina_remmina_ci__remmina_wiki__remmina__config__file__options.html), [ubicación del código dentro de una app de Apple](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle), [firma de código anidado](https://developer.apple.com/library/archive/technotes/tn2206/). Las licencias de las bibliotecas incluidas se conservan en el paquete.
