import 'dart:io';

import 'package:flutter/material.dart';

import '../app/app.dart';
import '../app/app_controller.dart';
import '../app/theme.dart';
import '../core/hotkeys.dart';
import '../core/recorder.dart';
import '../core/settings.dart';
import 'library_panel.dart';
import 'settings_panel.dart';
import 'widgets/logo.dart';
import 'widgets/window_chrome.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _section = 0;

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    return Scaffold(
      body: Column(
        children: [
          WindowChrome(
            actions: [
              IconButton(
                tooltip: 'Acerca de NJB Rec',
                icon: const Icon(Icons.info_outline_rounded, size: 18),
                onPressed: () => _showAbout(context, c),
              ),
            ],
          ),
          Expanded(
            child: Row(
              children: [
                _SideNav(
                  selected: _section,
                  onSelect: (i) => setState(() => _section = i),
                ),
                const VerticalDivider(),
                Expanded(
                  child: IndexedStack(
                    index: _section,
                    children: const [
                      _RecordView(),
                      LibraryPanel(),
                      SettingsPanel(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showAbout(BuildContext context, AppController c) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const NjbLogo(size: 96),
              const SizedBox(height: 16),
              const NjbWordmark(height: 44),
              const SizedBox(height: 12),
              const Text(
                'Grabador de pantalla con audio del sistema y micrófono, pausa, '
                'atajos globales y editor de recortes.',
                textAlign: TextAlign.center,
                style: TextStyle(color: NjbColors.textMuted),
              ),
              const SizedBox(height: 16),
              Text(
                c.ffmpegAvailable ? c.ffmpegVersion : 'ffmpeg no encontrado',
                style: const TextStyle(fontSize: 11, color: NjbColors.textMuted),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Process.start('explorer.exe', ['https://github.com/natanaelbertoncello2-sys/njbrec/releases']),
            icon: const Icon(Icons.system_update_alt_rounded, size: 18),
            label: const Text('Buscar actualizaciones'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
        ],
      ),
    );
  }
}

class _SideNav extends StatelessWidget {
  const _SideNav({required this.selected, required this.onSelect});

  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      selectedIndex: selected,
      onDestinationSelected: onSelect,
      backgroundColor: NjbColors.bg,
      indicatorColor: NjbColors.violet.withValues(alpha: 0.35),
      labelType: NavigationRailLabelType.all,
      minWidth: 84,
      selectedIconTheme: const IconThemeData(color: NjbColors.text),
      unselectedIconTheme: const IconThemeData(color: NjbColors.textMuted),
      selectedLabelTextStyle: const TextStyle(color: NjbColors.text, fontSize: 12, fontWeight: FontWeight.w600),
      unselectedLabelTextStyle: const TextStyle(color: NjbColors.textMuted, fontSize: 12),
      leading: const Padding(
        padding: EdgeInsets.only(top: 8, bottom: 16),
        child: NjbLogo(size: 44),
      ),
      destinations: const [
        NavigationRailDestination(
          icon: Icon(Icons.fiber_manual_record_outlined),
          selectedIcon: Icon(Icons.fiber_manual_record_rounded, color: NjbColors.red),
          label: Text('Grabar'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.video_library_outlined),
          selectedIcon: Icon(Icons.video_library_rounded),
          label: Text('Videos'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.tune_rounded),
          selectedIcon: Icon(Icons.tune_rounded),
          label: Text('Ajustes'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Vista principal de grabación
// ---------------------------------------------------------------------------

class _RecordView extends StatelessWidget {
  const _RecordView();

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final rec = c.recorder;
    final s = c.settings;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 16, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const NjbWordmark(height: 56),
          const SizedBox(height: 6),
          const Text(
            'Grabá tu pantalla con audio, pausá cuando quieras y editá el resultado.',
            style: TextStyle(color: NjbColors.textMuted, fontSize: 14),
          ),
          const SizedBox(height: 28),
          if (c.ffmpegChecked && !c.ffmpegAvailable) const _FfmpegWarning(),
          if (!c.ffmpegChecked)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Row(children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Text('Detectando ffmpeg y dispositivos de audio…', style: TextStyle(color: NjbColors.textMuted)),
              ]),
            ),
          if (rec.lastError != null)
            _ErrorBanner(rec.lastError!, onClose: rec.clearError),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: _HeroCard(rec: rec, enabled: c.ffmpegAvailable)),
              const SizedBox(width: 20),
              Expanded(
                flex: 4,
                child: Column(
                  children: [
                    _QuickSettings(c: c),
                    const SizedBox(height: 16),
                    _HotkeyCard(enabled: s.hotkeysEnabled),
                  ],
                ),
              ),
            ],
          ),
          if (rec.lastOutputFile != null) ...[
            const SizedBox(height: 20),
            _LastRecording(file: rec.lastOutputFile!),
          ],
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.rec, required this.enabled});

  final Recorder rec;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final state = rec.state;
    final String title;
    final String subtitle;
    switch (state) {
      case RecState.idle:
        title = 'Listo para grabar';
        subtitle = 'Presioná el botón o usá ${Hotkeys.startStopLabel}.';
      case RecState.countdown:
        title = 'Comenzando en ${rec.countdown}…';
        subtitle = 'Preparate. Podés cancelar.';
      case RecState.recording:
        title = 'Grabando';
        subtitle = 'La ventana se convirtió en una barra flotante.';
      case RecState.paused:
        title = 'En pausa';
        subtitle = 'Reanudá cuando quieras.';
      case RecState.processing:
        title = rec.processingLabel;
        subtitle = 'Uniendo segmentos y mezclando audio…';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            const SizedBox(height: 8),
            _RecordButton(rec: rec, enabled: enabled),
            const SizedBox(height: 24),
            Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(subtitle, style: const TextStyle(color: NjbColors.textMuted), textAlign: TextAlign.center),
            const SizedBox(height: 20),
            if (state == RecState.processing)
              const LinearProgressIndicator(minHeight: 4, borderRadius: BorderRadius.all(Radius.circular(4))),
            if (state == RecState.countdown)
              OutlinedButton.icon(
                onPressed: rec.cancelCountdown,
                icon: const Icon(Icons.close_rounded),
                label: const Text('Cancelar'),
              ),
          ],
        ),
      ),
    );
  }
}

class _RecordButton extends StatefulWidget {
  const _RecordButton({required this.rec, required this.enabled});

  final Recorder rec;
  final bool enabled;

  @override
  State<_RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<_RecordButton> with SingleTickerProviderStateMixin {
  late final AnimationController _glow = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
  bool _hover = false;

  @override
  void dispose() {
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rec = widget.rec;
    final idle = rec.state == RecState.idle;
    final countdown = rec.state == RecState.countdown;
    final processing = rec.state == RecState.processing;
    final enabled = widget.enabled && (idle || rec.isActive);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: !enabled
            ? null
            : () => idle ? rec.start() : rec.stop(),
        child: AnimatedBuilder(
          animation: _glow,
          builder: (_, child) {
            final glow = 0.25 + 0.35 * _glow.value;
            return AnimatedScale(
              scale: _hover && enabled ? 1.05 : 1,
              duration: const Duration(milliseconds: 150),
              child: Container(
                width: 168,
                height: 168,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [Color(0xFF2A2548), Color(0xFF17142A)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  border: Border.all(color: NjbColors.border, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: (idle ? NjbColors.violet : NjbColors.red).withValues(alpha: enabled ? glow : 0.05),
                      blurRadius: 48,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: Center(child: child),
              ),
            );
          },
          child: countdown
              ? Text('${rec.countdown}', style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w800, color: NjbColors.cyan))
              : processing
                  ? const SizedBox(width: 48, height: 48, child: CircularProgressIndicator(strokeWidth: 4))
                  : idle
                      ? Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: enabled ? NjbColors.red : NjbColors.textMuted,
                            boxShadow: [BoxShadow(color: NjbColors.red.withValues(alpha: 0.5), blurRadius: 24)],
                          ),
                        )
                      : Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            color: NjbColors.red,
                          ),
                        ),
        ),
      ),
    );
  }
}

class _QuickSettings extends StatelessWidget {
  const _QuickSettings({required this.c});

  final AppController c;

  @override
  Widget build(BuildContext context) {
    final s = c.settings;
    final busy = c.recorder.isBusy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Rápido', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 8),
            _Toggle(
              icon: Icons.mic_rounded,
              label: 'Micrófono',
              sub: s.micDevice ?? 'Sin micrófono detectado',
              value: s.micEnabled && s.micDevice != null,
              onChanged: busy || s.micDevice == null ? null : (v) => s.update((s) => s.micEnabled = v),
            ),
            _Toggle(
              icon: Icons.volume_up_rounded,
              label: 'Audio del sistema',
              sub: 'Lo que suena en la PC',
              value: s.systemAudioEnabled,
              onChanged: busy ? null : (v) => s.update((s) => s.systemAudioEnabled = v),
            ),
            _Toggle(
              icon: Icons.mouse_rounded,
              label: 'Mostrar cursor',
              sub: 'Incluir el puntero en el video',
              value: s.captureCursor,
              onChanged: busy ? null : (v) => s.update((s) => s.captureCursor = v),
            ),
            _Toggle(
              icon: Icons.picture_in_picture_alt_rounded,
              label: 'Barra flotante al grabar',
              sub: s.overlay == RecordingOverlay.floatingBar
                  ? 'Se ve una barra pequeña con controles'
                  : 'Nada visible: solo bandeja y atajos',
              value: s.overlay == RecordingOverlay.floatingBar,
              onChanged: busy
                  ? null
                  : (v) => s.update((s) => s.overlay = v ? RecordingOverlay.floatingBar : RecordingOverlay.hidden),
            ),
          ],
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.icon, required this.label, required this.sub, required this.value, required this.onChanged});

  final IconData icon;
  final String label;
  final String sub;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon, color: value ? NjbColors.cyan : NjbColors.textMuted),
      title: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text(sub, style: const TextStyle(fontSize: 12, color: NjbColors.textMuted), overflow: TextOverflow.ellipsis),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _HotkeyCard extends StatelessWidget {
  const _HotkeyCard({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Atajos globales', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                const Spacer(),
                if (!enabled)
                  const Text('desactivados', style: TextStyle(color: NjbColors.amber, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 12),
            const _HotkeyRow(Hotkeys.startStopLabel, 'Iniciar / detener'),
            const _HotkeyRow(Hotkeys.pauseResumeLabel, 'Pausar / reanudar'),
            const _HotkeyRow(Hotkeys.toggleBarLabel, 'Mostrar / ocultar barra'),
          ],
        ),
      ),
    );
  }
}

class _HotkeyRow extends StatelessWidget {
  const _HotkeyRow(this.keys, this.action);

  final String keys;
  final String action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: NjbColors.bgElevated,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: NjbColors.border),
            ),
            child: Text(keys, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: NjbColors.cyan)),
          ),
          const SizedBox(width: 12),
          Text(action, style: const TextStyle(color: NjbColors.textMuted, fontSize: 13)),
        ],
      ),
    );
  }
}

class _LastRecording extends StatelessWidget {
  const _LastRecording({required this.file});

  final String file;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.check_circle_rounded, color: NjbColors.green),
        title: const Text('Última grabación guardada'),
        subtitle: Text(file, style: const TextStyle(color: NjbColors.textMuted, fontSize: 12)),
        trailing: Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: () => LibraryActions.openEditor(context, file),
              icon: const Icon(Icons.content_cut_rounded, size: 18),
              label: const Text('Editar'),
            ),
            TextButton.icon(
              onPressed: () => LibraryActions.revealInExplorer(file),
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: const Text('Carpeta'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FfmpegWarning extends StatelessWidget {
  const _FfmpegWarning();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NjbColors.amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NjbColors.amber.withValues(alpha: 0.5)),
      ),
      child: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: NjbColors.amber),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'No se encontró ffmpeg. Copiá ffmpeg.exe junto a njbrec.exe o indicá la ruta en Ajustes.',
              style: TextStyle(color: NjbColors.text),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message, {required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: NjbColors.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NjbColors.red.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, color: NjbColors.red),
          const SizedBox(width: 12),
          Expanded(child: SelectableText(message, style: const TextStyle(fontSize: 12.5))),
          IconButton(onPressed: onClose, icon: const Icon(Icons.close_rounded, size: 18)),
        ],
      ),
    );
  }
}
