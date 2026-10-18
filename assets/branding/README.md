# Ícono Remina para macOS

Generado con la herramienta integrada **image_gen** a partir del ícono instalado de Remmina (`/usr/share/icons/hicolor/512x512/apps/org.remmina.Remmina.png`). Es una variante personal: conserva azul/verde, aro y chevrones de Remmina; añade ojos y sonrisa inspirados en Finder y una baldosa de porcelana con forma de ícono macOS.

## Archivos

- `remina-macos.png`: master de producción, 1024×1024 RGBA transparente.
- `remina-mark-64.png`, `remina-mark-128.png`, `remina-mark-256.png`: variantes de tamaño; la app usa 128 px en la barra lateral.
- `source/remina-macos-generated.png`: salida original sin modificar de image_gen.
- `../../macos/Runner/Assets.xcassets/AppIcon.appiconset/`: catálogo nativo, PNG de 16 a 1024 px.

Para reexportar los tamaños, ejecuta `tools/export_icons.sh` (ImageMagick). La exportación normaliza el lienzo, recorta el contorno externo para eliminar el halo irregular generado y reduce los tamaños con filtro Lanczos. Conserva el dibujo y la transparencia dentro del contorno. `assets/remina.svg` conserva el ícono anterior, que ya no se utiliza en el catálogo.

## Prompt de generación

```text
Use case: logo-brand.
Asset type: final production application icon for a personal macOS remote desktop client called Remina, square 1024x1024.
Input image 1 is a reference to the original Remmina logo. Create an original recognizable variation of this mark combining Remmina remote connection identity with a subtle macOS Finder personality.
Preserve the core arrangement: two bold opposed terminal chevrons, green > in upper left and blue < in lower right, inside a nearly complete circular connection ring split into blue upper-left and green lower-right arcs.
Reimagine the circular emblem as a refined native macOS app icon: centered in a softly rounded square tile of warm porcelain white, gentle bevel, restrained depth, crisp smooth edges, very subtle soft shadow. The ring and chevrons have a satin azure blue and emerald green finish. Within the central negative space, suggest the friendly Finder face using only two discreet dark navy eye dots and a tiny curved smile, carefully positioned so the two main chevrons remain clearly readable. A subtle vertical tonal division inside the emblem evokes Finder's blue-and-light face, but avoid clutter and do not add an Apple silhouette.
This must look like one coherent polished icon, not two logos pasted together. Front-facing orthographic view, no perspective, no scene, no devices, no lettering, no watermark, no surrounding mockup. Bold geometries must read at 32 pixels. Rounded tile occupies about 84% of the square canvas with even transparent margins. Actual transparent alpha outside the tile, no checkerboard drawn into pixels. High resolution polished production graphic.
```

## Prompt de refinado

```text
Edit target: the generated Remina app icon.
Change ONLY the outer contour and transparent margins to make this a finished production macOS icon. Keep exactly the same blue and green connection ring, green > and blue < symbols, two navy eyes, smile, split pale face, porcelain tile, and overall artwork.
Remove all white specks, rough halos, cloudy fringe, scratches, and irregular pixels around the outside of the rounded-square tile. The outside silhouette must be a perfectly smooth regular macOS rounded square, with a clean anti-aliased edge and no detached elements. The tile should occupy 84% of the square canvas (8% empty transparent margins on all sides), centered and front-facing. Outside it is perfectly empty transparent alpha. No surrounding shadow haze. Do not draw a checkerboard. No added text, no extra objects. Keep internal artwork unchanged. Square 1024x1024 final app icon.
```

No se utilizaron CLI/API alternativos ni claves API locales para generar las imágenes.

