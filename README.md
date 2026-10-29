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
- **Editor**: recorte por inicio/fin con miniaturas, repetición del rango,
  silenciar, captura de cuadro y exportación a MP4 (corte rápido o preciso),
  GIF o MP3.
- **Biblioteca**: lista de grabaciones con miniaturas, abrir, editar, mostrar
  en carpeta y eliminar.
- Calidad, fps y codificador (x264 / NVENC / AMF / QuickSync según el equipo).

## Requisitos

- Windows 10/11 x64.
- `ffmpeg.exe`. Si existe `windows/ffmpeg/ffmpeg.exe` al compilar se copia
  junto al ejecutable; si no, la app lo busca en el `PATH` o en la ruta que se
  indique en **Ajustes → ffmpeg**.

## Compilar

```powershell
flutter pub get
python tool/make_branding.py      # regenera logo e iconos (necesita Pillow)
flutter run -d windows            # desarrollo
powershell -ExecutionPolicy Bypass -File tool/build_release.ps1   # release + zip en dist/
```

## Estructura

```
lib/app/        tema, controlador de la app (ventana, bandeja, atajos)
lib/core/       ffmpeg, grabador por segmentos, ajustes, puente nativo
lib/ui/         pantalla principal, ajustes, biblioteca, barra flotante, editor
windows/runner/njb_native.cpp   WASAPI loopback + monitores (canal njbrec/native)
tool/           generación de branding, build y captura de pantalla
assets/branding iconos y logos generados
```

Las grabaciones se guardan por defecto en `Videos\NJB Rec`.
