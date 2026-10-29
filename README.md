# NJB Rec

Grabador de pantalla para Windows hecho en Flutter. Graba la pantalla con
audio del sistema y micrófono, permite pausar y reanudar, se controla con
atajos globales o una barra flotante mínima, y trae un editor para recortar
y exportar.

## Funciones

- **Captura**: todo el escritorio, un monitor o un área personalizada. Opción
  de captura acelerada por GPU (Desktop Duplication).
- **Audio**: micrófono (DirectShow) + audio del sistema (WASAPI loopback nativo),
  con volumen independiente para cada uno.
- **Pausa / reanudar**: la grabación se parte en segmentos que se unen al
  terminar, sin recodificar el video.
- **Sin estorbar**: mientras se graba la ventana se convierte en una barra
  flotante pequeña (o se oculta por completo) y queda un icono en la bandeja.
- **Atajos globales**:
  - `Ctrl + Shift + R` iniciar / detener
  - `Ctrl + Shift + P` pausar / reanudar
  - `Ctrl + Shift + H` mostrar / ocultar la barra flotante
- **Editor multipista**:
  - **Cortes**: marcá tramos con I/O y eliminalos (varios por video, con
    restaurar, deshacer/rehacer).
  - **Narración**: grabá tu voz con el micrófono desde el editor (tecla R)
    mientras ves el video; el clip queda en la posición del cabezal y se
    puede mover, recortar y ajustar. El audio original baja solo mientras
    habla la narración.
  - **Música / efectos**: importá MP3/WAV/M4A, con volumen, entrada y salida
    suave y punto de inicio dentro del archivo.
  - **Textos**: títulos con tamaño, color, fondo, negrita y aparición suave;
    se arrastran directamente sobre el video.
  - **Imágenes / logos**: PNG/JPG con ancho y opacidad, también arrastrables.
  - Fundido de entrada/salida, volumen o silencio del audio original,
    captura de cuadro.
  - Exportación a MP4, GIF o MP3 con todo aplicado. El proyecto se guarda
    solo junto al video (`<video>.njbproj.json`) para seguir editando después.
- **Biblioteca**: lista de grabaciones con miniaturas, abrir, editar, mostrar
  en carpeta y eliminar.
- Calidad, fps y codificador (x264 / NVENC / AMF / QuickSync según el equipo).

## Requisitos

- Windows 10/11 x64.
- `ffmpeg.exe`. Si existe `windows/ffmpeg/ffmpeg.exe` al compilar se copia
  junto al ejecutable; si no, la app lo busca en el `PATH` o en la ruta que se
  indique en **Ajustes → ffmpeg**.

## Si no abre en otra PC

- **Windows SmartScreen** ("Windows protegió su PC"): el instalador no está
  firmado. Clic en *Más información → Ejecutar de todas formas*.
- **Faltaba el runtime de Visual C++**: desde la 1.1.1 las DLL
  (`msvcp140`, `vcruntime140`, `vcruntime140_1`) van incluidas junto al
  ejecutable, así que ya no hace falta instalar nada.
- Necesita Windows 10/11 de 64 bits con una GPU que soporte Direct3D 11.
- Si abre pero no graba: revisá en **Ajustes → ffmpeg** que figure
  "Detectado".

## Compilar

```powershell
flutter pub get
python tool/make_branding.py      # regenera logo e iconos (necesita Pillow)
flutter run -d windows            # desarrollo
powershell -ExecutionPolicy Bypass -File tool/build_release.ps1   # release + zip en dist/
```

## Publicar una nueva versión

1. Subí el número en `pubspec.yaml` (`version: 1.0.1+2`).
2. Commit y push a `main`.
3. Creá y subí un tag: `git tag v1.0.1 && git push --tags`.

GitHub Actions (`.github/workflows/release.yml`) compila, descarga ffmpeg,
arma el instalador y publica la release con el `.exe` y el zip portable.
Para hacerlo localmente: `tool/build_release.ps1` deja ambos archivos en
`dist/` y después `gh release create vX.Y.Z dist/*`.

Las descargas quedan en https://github.com/natanaelbertoncello2-sys/njbrec/releases
(también desde el botón "Buscar actualizaciones" en Acerca de).

## Estructura

```
lib/app/        tema, controlador de la app (ventana, bandeja, atajos)
lib/core/       ffmpeg, grabador por segmentos, ajustes, puente nativo
lib/editor/     modelo de proyecto, exportador (grafo de filtros ffmpeg), narración
lib/ui/         pantalla principal, ajustes, biblioteca, barra flotante, editor
windows/runner/njb_native.cpp   WASAPI loopback + monitores (canal njbrec/native)
tool/           generación de branding, build y captura de pantalla
assets/branding iconos y logos generados
```

Las grabaciones se guardan por defecto en `Videos\NJB Rec`.
