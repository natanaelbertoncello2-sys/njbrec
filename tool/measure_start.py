"""Mide cuánto antes del mensaje 'Press [q]' se captura el primer cuadro de gdigrab
y cuánto tarda en abrir el micrófono dshow. Uso: python tool/measure_start.py"""
import subprocess, sys, time, re

MIC = "Microphone (USB Audio Device)"

def run(with_mic):
    args = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "info",
            "-f", "gdigrab", "-use_wallclock_as_timestamps", "1", "-framerate", "30",
            "-video_size", "640x360", "-i", "desktop"]
    if with_mic:
        args += ["-f", "dshow", "-use_wallclock_as_timestamps", "1", "-i", f"audio={MIC}"]
    args += ["-copyts", "-t", "1", "-vf", "showinfo", "-f", "null", "-"]
    if with_mic:
        args[-3:-3] = ["-af", "ashowinfo"]
    t_spawn = time.time()
    p = subprocess.Popen(args, stderr=subprocess.PIPE, stdout=subprocess.DEVNULL, text=True, encoding="utf-8", errors="replace")
    t_press = None; first_v = None; first_a = None
    for line in p.stderr:
        now = time.time()
        if "Press [q]" in line and t_press is None:
            t_press = now
        m = re.search(r"pts_time:([\d.]+)", line)
        if m:
            if "Parsed_showinfo" in line and first_v is None:
                first_v = float(m.group(1))
            if "Parsed_ashowinfo" in line and first_a is None:
                first_a = float(m.group(1))
    p.wait()
    print(f"mic={with_mic}: primer cuadro {first_v - t_spawn:+.3f}s tras spawn; 'Press[q]' {t_press - t_spawn:+.3f}s tras spawn; "
          f"cuadro->Press {t_press - first_v:+.3f}s" + (f"; mic primer paquete {first_a - first_v:+.3f}s tras cuadro" if first_a else ""))

for i in range(3):
    run(False)
for i in range(3):
    run(True)
