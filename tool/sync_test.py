"""Prueba de sincronía audio/video de una grabación de NJB Rec.

1. `python tool/sync_test.py make`  -> genera build/sync_ref.mp4: destello blanco + bip cada segundo.
2. Reproducilo a pantalla completa (ffplay -fs build/sync_ref.mp4) y grabalo con NJB Rec.
3. `python tool/sync_test.py check "<grabacion.mp4>"` -> compara destellos (video) con bips (audio).
"""
import re, subprocess, sys, statistics

def make(out):
    subprocess.run([
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "color=c=black:s=1280x720:r=30",
        "-f", "lavfi", "-i", "sine=f=1000:r=48000",
        "-vf", "drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='lt(mod(t\\,1)\\,0.1)'",
        "-af", "volume=1:enable='lt(mod(t\\,1)\\,0.1)',volume=0:enable='gte(mod(t\\,1)\\,0.1)'",
        "-t", "40", "-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p", "-c:a", "aac", out,
    ], check=True)
    print("ok:", out)

def check(path):
    # Brillo medio por cuadro.
    r = subprocess.run(["ffmpeg", "-hide_banner", "-i", path, "-vf", "signalstats,metadata=print:key=lavfi.signalstats.YAVG",
                        "-an", "-f", "null", "-"], capture_output=True, text=True, errors="replace")
    frames = re.findall(r"pts_time:([\d.]+)\s*\n.*?YAVG=([\d.]+)", r.stderr)
    flashes, prev_bright = [], False
    for t, y in frames:
        bright = float(y) > 120
        if bright and not prev_bright:
            flashes.append(float(t))
        prev_bright = bright
    # Bips: nivel RMS por bloque de audio.
    r = subprocess.run(["ffmpeg", "-hide_banner", "-i", path, "-vn", "-af",
                        "asetnsamples=480,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level",
                        "-f", "null", "-"],
                       capture_output=True, text=True, errors="replace")
    blocks = re.findall(r"pts_time:([\d.]+)\s*\n.*?RMS_level=(-?[\d.]+|-inf)", r.stderr)
    beeps, prev_loud = [], False
    for t, lvl in blocks:
        loud = lvl != "-inf" and float(lvl) > -35
        if loud and not prev_loud:
            beeps.append(float(t))
        prev_loud = loud
    print(f"destellos: {len(flashes)}  bips: {len(beeps)}")
    if not flashes or not beeps:
        print("no se detectaron eventos suficientes"); return
    # Para cada destello, el bip más cercano.
    diffs = []
    for f in flashes:
        b = min(beeps, key=lambda x: abs(x - f))
        if abs(b - f) < 0.5:
            diffs.append(b - f)
    if not diffs:
        print("sin coincidencias"); return
    print(f"audio - video (s): mediana {statistics.median(diffs):+.3f}, min {min(diffs):+.3f}, max {max(diffs):+.3f}, n={len(diffs)}")
    print("  (positivo = el audio suena después del cuadro; |x| < 0.1 s es imperceptible)")

if __name__ == "__main__":
    if sys.argv[1] == "make":
        make(sys.argv[2] if len(sys.argv) > 2 else "build/sync_ref.mp4")
    else:
        check(sys.argv[2])
