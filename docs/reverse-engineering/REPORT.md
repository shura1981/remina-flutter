# Investigación de Remmina

Fecha: 18 de octubre de 2026. Alcance: reconstruir el flujo de gestión de conexiones y recuperar compatibilidad con los cuatro perfiles del usuario, tres RDP y uno SSH. Se analizaron artefactos instalados mediante REA MCP, no una descarga de código como sustituto del análisis del binario.

## Identidad y método

- Ejecutable: `/usr/bin/remmina`, ELF x86_64, Remmina 1.4.43.
- SHA256: `66135e6da91f99a7f09c8088c52012856cb847f191b6867f40b87f39a47a5f78`.
- Plugin RDP: `/usr/lib/x86_64-linux-gnu/remmina/plugins/remmina-plugin-rdp.so`.
- SHA256 del plugin: `c42c82730e5625581e023691b2767f664752fa6e2b5001f7f72178f65ce98b57`.
- REA seleccionó Hopper. Su inventario devolvió 3181 procedimientos y 2007 cadenas del ejecutable.
- Se inspeccionaron los recursos GTK compilados con `gresource`, usando un parser XML para enumerar controles, columnas y acciones. Esta fue evidencia de recursos, no observación de interacción con la UI.
- `remmina --full-version` informó plugin RDP 1.4.43, compilado con FreeRDP 3.30.0 y enlazado en ejecución con 3.32.1; también plugins VNC y glibsecret.

Las referencias `ev_…` de esta tabla se conservan completas en [evidence.json](evidence.json). Son identificadores de la sesión REA, no enlaces web.

## Registro de hallazgos

| Pregunta | Observación / evidencia | Estado y aplicación |
|---|---|---|
| ¿Qué binario es? | `binary_overview`, `ev_f11dd176…`; hash obtenido por `open_binary` | Respondida; identidad del artefacto fijada |
| ¿Cómo se gestionan los perfiles? | `search_procedures remmina_file_`, `ev_e69326a3…`; funciones de carga/guardado/duplicación/borrado | Respondida para los flujos reconstruidos |
| ¿Qué formato se lee? | Descompilación `remmina_file_load` en `0x2f890`, `ev_705842a0…`: GLib `g_key_file_*`, sección `remmina`, claves por nombre | Respondida; parser de keyfiles compatible con escapes y extensiones desconocidas |
| ¿Qué ocurre con los secretos? | Misma descompilación y `remmina_file_save` en `0x2da70`: ramas de plugin secreto y cifrado; marcador punto. Inventario local: 4/4 perfiles con `password=.` | Respondida para migración; no se extrajeron ni imprimieron contraseñas |
| ¿Qué acciones ofrece la biblioteca? | `search_procedures remmina_main_`, `ev_b3e48457…`; XML GTK compilado: conectar/copiar/editar/borrar, búsqueda, listado/grupos, importar/exportar | Respondida para el flujo implementado; sin afirmar equivalencia visual exacta |
| ¿Cómo funciona conexión rápida? | Descompilación `0x3b530`, `ev_705842a0…`: crea perfil temporal con protocolo, servidor, nombre y password-storing desactivado | Respondida; conexión temporal sin añadir perfil a biblioteca |
| ¿Cómo se aplican ajustes RDP? | Búsqueda de cadenas `ev_adb5c498…`; referencias cruzadas y descompilación `sub_13850`, `ev_a700fab1…`: lee usuario/dominio/secreto, color, gateway, cert_ignore, resolución; configura FreeRDP y llama `freerdp_connect` | Parcial; implementada traducción del subconjunto documentado en README |
| ¿Qué significa resolución? | La semántica de `resolution_mode` y `scale` se corroboró con documentación primaria de Remmina | Respondida con fuente externa, sin atribuir enum completo a una cadena del binario |
| ¿Son compatibles los perfiles existentes? | Parser aplicado localmente a cuatro perfiles: roundtrip exacto y cambios sintéticos conservando el resto de claves | Respondida para su representación en archivo; autenticación en sus servidores no probada |
| ¿Funcionan las sesiones? | Prueba SSH real con fixture local y prueba FreeRDP contra puerto loopback cerrado | SSH local verificado; RDP solo arranque/CLI/stdin, no escritorio remoto completo |
| ¿Funciona macOS? | Runner, entitlements, script y workflow preparados | Pendiente ejecutar build y sesiones en un Mac |

## Qué es reconstrucción y qué es diseño nuevo

Observado: keyfiles GLib, acciones de la biblioteca, perfiles temporales, secretos delegados a plugins y uso de FreeRDP para RDP.

Diseño nuevo: Flutter Material, tema oscuro/claro, favoritos mediante `remina_favorite`, preferencias e historial JSON locales, llavero mediante `flutter_secure_storage`, terminal `dartssh2`/`xterm`, registro TOFU propio y lanzamiento del cliente FreeRDP con stdin. No se copió pseudocódigo descompilado dentro de la app.

La conservación de una clave significa compatibilidad del archivo, no implementación de la función. Opciones avanzadas de canales, dispositivos, teclados, proxies, plugins y preferencias globales de GTK quedan fuera de la equivalencia comprobada. Las preferencias globales `remmina.pref`, el llavero Linux y los archivos de estado no se migran como configuración ejecutable. Los perfiles `.remmina` sí se importan/exportan.

## Límites del entorno y de las conclusiones

REA pudo analizar ambos artefactos con Hopper. Ghidra no estaba configurado. Un diagnóstico separado con la CLI más reciente detectó diferencias de registro/versión de herramientas y no autenticó la versión local del launcher Hopper. No se ejecutó setup ni se alteró esa instalación. Por eso el registro conserva hash, proveedor y limitaciones devueltas: los resultados estáticos no certifican de forma independiente el proveedor ni sustituyen pruebas de comportamiento.

El pseudocódigo contiene llamadas indirectas, variables sin nombre y ramas reconstruidas; no es el código fuente original ni demuestra ejecución. No se conectó a los servidores del usuario, no se observó una sesión RDP real y no se probó un gateway. El build macOS necesita macOS y Xcode. Las sesiones REA abiertas se cerraron al terminar.

## Fuentes primarias de corroboración

- [Opciones de configuración Remmina](https://remmina.gitlab.io/remminadoc.gitlab.io/md__builds__remmina_remmina_ci__remmina_wiki__remmina__config__file__options.html).
- [Parser CLI FreeRDP 3.32.1](https://github.com/FreeRDP/FreeRDP/blob/3.32.1/client/common/cmdline.c): stdin forzado, orden de contraseñas de desktop/gateway y argumentos de gateway.
- [FreeRDP: compilación macOS](https://github.com/FreeRDP/FreeRDP/wiki/Compilation).
- [Homebrew: cliente SDL](https://formulae.brew.sh/formula/freerdp).

## Cierre del alcance

Completado: identidad, investigación de perfiles y flujos principales, app Flutter/FVM, migración de archivos, SSH y lanzador RDP. Parcial: traducción de todos los ajustes RDP y equivalencia de UX. Pendiente de otro entorno: build macOS y pruebas de sesión contra destinos reales; pendiente de implementación: los motores/funciones indicados en README.
