# Distribución con bibliotecas incluidas

El empaquetado ya no depende de que el equipo de destino tenga FreeRDP instalado. Las herramientas del equipo que compila sirven para producir un paquete completo y trasladable.

## Linux

`linux/CMakeLists.txt` ejecuta `tools/packaging/bundle_runtime.py` al montar el bundle, después de instalar el ejecutable Flutter, los plugins y los assets. Se aplica tanto a `fvm flutter run -d linux` como a builds de release. La falta de una biblioteca requerida aborta el build.

Estructura principal:

```text
bundle/
  remina                 lanzador con rutas relativas
  remina.bin             ejecutable Flutter
  lib/                   GTK, GLib, libsecret, EGL/Mesa y cargador ELF
  data/                  assets de Flutter
  runtime/               fuentes, configuración y esquemas GSettings
  rdp/bin/remina-rdp      lanzador del motor incluido
  rdp/bin/freerdp         binario FreeRDP 3
  rdp/lib/               sus bibliotecas y cargador ELF
  rdp/share/cacert.pem    autoridades de confianza
  licenses/              avisos de las bibliotecas copiadas
  runtime-manifest.json  inventario y SHA256 de los archivos distribuidos
```

Se incluye el cierre de dependencias enlazadas de los ejecutables y plugins, además de recursos cargados dinámicamente conocidos: EGL, Mesa, drivers DRI, fuentes, esquemas de configuración y proveedor OpenSSL legacy. Cada lanzador usa un cargador incluido y `--library-path` relativo. No se conservan rutas al sistema donde se compiló ni al motor instalado para el usuario.

Al iniciar con un cargador privado, `/proc/self/exe` señala ese cargador; por eso el runner establece explícitamente las rutas de assets, ICU y AOT. `REMINA_BUNDLE_DIR` identifica el directorio del paquete; no sirve para buscar una instalación externa de FreeRDP.

El verificador comprueba hashes y que las bibliotecas enlazadas se resuelvan dentro de la distribución. El smoke aislado arranca la app en otra ruta y espera una ventana GTK visible, que el runner solo muestra tras recibir el primer frame de Flutter. También inicia el motor RDP con una contraseña ficticia por stdin contra un puerto loopback cerrado.

Se verificaron el motor en contenedores mínimos Ubuntu y Alpine sin FreeRDP instalado, y el render de la app en ambos entornos. El paquete requiere un kernel/escritorio compatible y la misma arquitectura. Incluir bibliotecas no permite ejecutar un binario Linux en macOS/Windows ni sustituye los servicios de pantalla, audio o llavero del sistema. Los dispositivos, impresoras y codecs avanzados no quedaron validados por esta prueba.

## macOS

La fase de Xcode que incluye Flutter ahora ejecuta el empaquetador antes de que Xcode firme la aplicación final. El empaquetador:

1. Copia el helper a `Contents/MacOS/remina-rdp`.
2. Recorre las dependencias Mach-O y copia dylibs no provistas por macOS a `Contents/Frameworks/ReminaRdp`.
3. Reescribe referencias con `@loader_path`, elimina rutas de compilación y rechaza referencias no resueltas o conflictos de bibliotecas.
4. Incluye los proveedores OpenSSL disponibles, certificados y avisos de licencia.
5. Comprueba arquitectura y ajusta `LSMinimumSystemVersion` al mínimo exigido por el código incluido.
6. Firma las bibliotecas y el helper con la identidad del build, o firma ad hoc cuando no hay identidad configurada. Xcode firma después el contenedor exterior.

Release se genera para la arquitectura del equipo que compila. No se anuncia un binario universal cuando el motor solo contiene una arquitectura. Los frameworks de terceros no provistos por macOS se rechazan explícitamente; para esa entrada hay que compilar FreeRDP usando dylibs.

**Pendiente de validación real en macOS:** el entorno de esta sesión es Linux. Las pruebas unitarias validan resolución de rutas Mach-O y errores de empaquetado, pero no sustituyen una compilación, firma y ejecución reales con Xcode. El workflow macOS y `tools/build_macos.sh` ejecutan las verificaciones nativas antes de producir el ZIP.

## Fuentes y límites

El empaquetado se apoya en [las convenciones de bundles de Apple](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle) y [la firma de código anidado](https://developer.apple.com/library/archive/technotes/tn2206/). FreeRDP continúa siendo un helper con ventana separada. Embebido del escritorio en Flutter es trabajo pendiente independiente del empaquetado de bibliotecas.
