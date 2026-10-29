import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app/app.dart';
import '../app/theme.dart';
import '../core/native_bridge.dart';
import '../core/settings.dart';

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({super.key});

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  ScreenLayout? _layout;

  @override
  void initState() {
    super.initState();
    NativeBridge.listMonitors().then((l) {
      if (mounted) setState(() => _layout = l);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final s = c.settings;
    final busy = c.recorder.isBusy;
    final monitors = _layout?.monitors ?? const <MonitorInfo>[];

    return AbsorbPointer(
      absorbing: busy,
      child: Opacity(
        opacity: busy ? 0.6 : 1,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(32, 16, 32, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Ajustes', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
              const SizedBox(height: 20),
              _Section(
                title: 'Fuente de captura',
                icon: Icons.desktop_windows_rounded,
                children: [
                  SegmentedButton<CaptureMode>(
                    segments: const [
                      ButtonSegment(value: CaptureMode.desktop, label: Text('Todo el escritorio'), icon: Icon(Icons.select_all_rounded)),
                      ButtonSegment(value: CaptureMode.monitor, label: Text('Un monitor'), icon: Icon(Icons.monitor_rounded)),
                      ButtonSegment(value: CaptureMode.region, label: Text('Área'), icon: Icon(Icons.crop_rounded)),
                    ],
                    selected: {s.captureMode},
                    onSelectionChanged: (v) => s.update((s) => s.captureMode = v.first),
                  ),
                  const SizedBox(height: 14),
                  if (s.captureMode == CaptureMode.monitor)
                    DropdownButtonFormField<int>(
                      initialValue: monitors.isEmpty ? null : s.monitorIndex.clamp(0, monitors.length - 1),
                      decoration: const InputDecoration(labelText: 'Monitor'),
                      items: [
                        for (final m in monitors) DropdownMenuItem(value: m.id, child: Text(m.label)),
                      ],
                      onChanged: (v) => v == null ? null : s.update((s) => s.monitorIndex = v),
                    ),
                  if (s.captureMode == CaptureMode.region) _RegionFields(s: s, layout: _layout),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Captura acelerada por GPU (Desktop Duplication)'),
                    subtitle: const Text('Más eficiente en pantallas grandes. Captura el monitor completo; si falla, desactivalo.',
                        style: TextStyle(color: NjbColors.textMuted, fontSize: 12)),
                    value: s.captureGpu,
                    onChanged: (v) => s.update((s) => s.captureGpu = v),
                  ),
                ],
              ),
              _Section(
                title: 'Video',
                icon: Icons.high_quality_rounded,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: s.fps,
                          decoration: const InputDecoration(labelText: 'Cuadros por segundo'),
                          items: const [15, 24, 30, 60].map((f) => DropdownMenuItem(value: f, child: Text('$f fps'))).toList(),
                          onChanged: (v) => v == null ? null : s.update((s) => s.fps = v),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: DropdownButtonFormField<VideoQuality>(
                          initialValue: s.quality,
                          decoration: const InputDecoration(labelText: 'Calidad'),
                          items: VideoQuality.values.map((q) => DropdownMenuItem(value: q, child: Text(q.label))).toList(),
                          onChanged: (v) => v == null ? null : s.update((s) => s.quality = v),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: c.encoders.contains(s.encoder) ? s.encoder : 'libx264',
                          decoration: const InputDecoration(labelText: 'Codificador'),
                          items: c.encoders.map((e) => DropdownMenuItem(value: e, child: Text(_encoderLabel(e)))).toList(),
                          onChanged: (v) => v == null ? null : s.update((s) => s.encoder = v),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              _Section(
                title: 'Audio',
                icon: Icons.graphic_eq_rounded,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Grabar micrófono'),
                    value: s.micEnabled,
                    onChanged: (v) => s.update((s) => s.micEnabled = v),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: c.audioInputs.contains(s.micDevice) ? s.micDevice : null,
                          decoration: const InputDecoration(labelText: 'Micrófono'),
                          items: c.audioInputs.map((d) => DropdownMenuItem(value: d, child: Text(d, overflow: TextOverflow.ellipsis))).toList(),
                          onChanged: s.micEnabled ? (v) => s.update((s) => s.micDevice = v) : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Volver a detectar dispositivos',
                        onPressed: () => c.refreshFfmpeg(),
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                  _VolumeSlider(
                    label: 'Volumen del micrófono',
                    value: s.micVolume,
                    enabled: s.micEnabled,
                    onChanged: (v) => s.update((s) => s.micVolume = v),
                  ),
                  const Divider(height: 24),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Grabar audio del sistema'),
                    subtitle: const Text('Captura lo que se escucha en los parlantes/auriculares (WASAPI loopback).',
                        style: TextStyle(color: NjbColors.textMuted, fontSize: 12)),
                    value: s.systemAudioEnabled,
                    onChanged: (v) => s.update((s) => s.systemAudioEnabled = v),
                  ),
                  _VolumeSlider(
                    label: 'Volumen del sistema',
                    value: s.systemVolume,
                    enabled: s.systemAudioEnabled,
                    onChanged: (v) => s.update((s) => s.systemVolume = v),
                  ),
                ],
              ),
              _Section(
                title: 'Salida y comportamiento',
                icon: Icons.folder_rounded,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: InputDecorator(
                          decoration: const InputDecoration(labelText: 'Carpeta de grabaciones'),
                          child: Text(s.outputDir, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Elegir carpeta de grabaciones');
                          if (dir != null) await s.update((s) => s.outputDir = dir);
                        },
                        icon: const Icon(Icons.folder_open_rounded, size: 18),
                        label: const Text('Cambiar'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: s.countdownSeconds,
                          decoration: const InputDecoration(labelText: 'Cuenta regresiva'),
                          items: const [0, 3, 5, 10].map((v) => DropdownMenuItem(value: v, child: Text(v == 0 ? 'Sin cuenta' : '$v segundos'))).toList(),
                          onChanged: (v) => v == null ? null : s.update((s) => s.countdownSeconds = v),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: DropdownButtonFormField<RecordingOverlay>(
                          initialValue: s.overlay,
                          decoration: const InputDecoration(labelText: 'Durante la grabación'),
                          items: const [
                            DropdownMenuItem(value: RecordingOverlay.floatingBar, child: Text('Barra flotante con controles')),
                            DropdownMenuItem(value: RecordingOverlay.hidden, child: Text('Ocultar todo (bandeja + atajos)')),
                          ],
                          onChanged: (v) => v == null ? null : s.update((s) => s.overlay = v),
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Abrir el editor al terminar'),
                    value: s.openEditorAfterStop,
                    onChanged: (v) => s.update((s) => s.openEditorAfterStop = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Atajos globales (Ctrl+Shift+R / P / H)'),
                    value: s.hotkeysEnabled,
                    onChanged: (v) async {
                      await s.update((s) => s.hotkeysEnabled = v);
                      await c.applyHotkeys();
                    },
                  ),
                ],
              ),
              _Section(
                title: 'ffmpeg',
                icon: Icons.terminal_rounded,
                children: [
                  Text(
                    c.ffmpegAvailable ? 'Detectado: ${c.ffmpegVersion}' : 'No detectado',
                    style: TextStyle(color: c.ffmpegAvailable ? NjbColors.green : NjbColors.red, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: InputDecorator(
                          decoration: const InputDecoration(labelText: 'Ruta personalizada (opcional)'),
                          child: Text(s.ffmpegPath.isEmpty ? 'Automática' : s.ffmpegPath, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        onPressed: () async {
                          final r = await FilePicker.pickFiles(
                            dialogTitle: 'Seleccionar ffmpeg.exe',
                            type: FileType.custom,
                            allowedExtensions: ['exe'],
                          );
                          final path = r.isEmpty ? null : r.first.path;
                          if (path != null) {
                            await s.update((s) => s.ffmpegPath = path);
                            await c.refreshFfmpeg();
                          }
                        },
                        child: const Text('Elegir…'),
                      ),
                      const SizedBox(width: 6),
                      TextButton(
                        onPressed: () async {
                          await s.update((s) => s.ffmpegPath = '');
                          await c.refreshFfmpeg();
                        },
                        child: const Text('Auto'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _encoderLabel(String e) => switch (e) {
        'h264_nvenc' => 'NVIDIA NVENC (GPU)',
        'h264_amf' => 'AMD AMF (GPU)',
        'h264_qsv' => 'Intel QuickSync (GPU)',
        _ => 'x264 (CPU, compatible)',
      };
}

class _RegionFields extends StatefulWidget {
  const _RegionFields({required this.s, required this.layout});

  final AppSettings s;
  final ScreenLayout? layout;

  @override
  State<_RegionFields> createState() => _RegionFieldsState();
}

class _RegionFieldsState extends State<_RegionFields> {
  late final _x = TextEditingController(text: '${widget.s.regionX}');
  late final _y = TextEditingController(text: '${widget.s.regionY}');
  late final _w = TextEditingController(text: '${widget.s.regionW}');
  late final _h = TextEditingController(text: '${widget.s.regionH}');

  @override
  void dispose() {
    _x.dispose();
    _y.dispose();
    _w.dispose();
    _h.dispose();
    super.dispose();
  }

  void _apply() {
    widget.s.update((s) {
      s.regionX = int.tryParse(_x.text) ?? s.regionX;
      s.regionY = int.tryParse(_y.text) ?? s.regionY;
      s.regionW = (int.tryParse(_w.text) ?? s.regionW).clamp(16, 16384);
      s.regionH = (int.tryParse(_h.text) ?? s.regionH).clamp(16, 16384);
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget field(String label, TextEditingController c) => Expanded(
          child: TextField(
            controller: c,
            decoration: InputDecoration(labelText: label),
            keyboardType: TextInputType.number,
            onSubmitted: (_) => _apply(),
            onTapOutside: (_) => _apply(),
          ),
        );
    final v = widget.layout?.virtualRect;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          field('X', _x),
          const SizedBox(width: 10),
          field('Y', _y),
          const SizedBox(width: 10),
          field('Ancho', _w),
          const SizedBox(width: 10),
          field('Alto', _h),
        ]),
        if (v != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Coordenadas en píxeles reales. Escritorio: ${v.left.toInt()},${v.top.toInt()} · ${v.width.toInt()}x${v.height.toInt()}',
              style: const TextStyle(color: NjbColors.textMuted, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

class _VolumeSlider extends StatelessWidget {
  const _VolumeSlider({required this.label, required this.value, required this.enabled, required this.onChanged});

  final String label;
  final double value;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 190, child: Text(label, style: const TextStyle(fontSize: 13, color: NjbColors.textMuted))),
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 2,
            divisions: 20,
            label: '${(value * 100).round()} %',
            onChanged: enabled ? onChanged : null,
          ),
        ),
        SizedBox(width: 48, child: Text('${(value * 100).round()} %', textAlign: TextAlign.end, style: const TextStyle(fontSize: 13))),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.icon, required this.children});

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 20, color: NjbColors.cyan),
                const SizedBox(width: 10),
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              ]),
              const SizedBox(height: 14),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}
