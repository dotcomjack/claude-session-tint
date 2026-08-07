#!/usr/bin/env python3
"""Render docs/demo.gif.

Every colour in the output is computed with the same arithmetic the tool uses,
so this is a faithful preview rather than an artist's impression. tabtint.sh's
scale16() is a straight multiply:

    printf '%s %s %s' "$((r * 257 * pct / 100))" ...

which is a wash toward black at pct percent, so a window tagged #A3D8E1 at the
default resting 22% renders rgb(35,47,49) and the same window lit at 48%
renders rgb(78,103,108). Those are the numbers below.

Frames are emitted as HTML, shot with headless Chrome, and assembled by
ImageMagick with per-frame delays so the two holds (idle, then lit) cost one
frame each instead of thirty.

    python3 docs/make-demo-gif.py
"""

import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DOCS = Path(__file__).resolve().parent
OUT = DOCS / "demo.gif"

IDLE_PCT = 22
ATTN_PCT = 48

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WIDTH = 1000
# Tall enough for two rows plus the caption, and no taller: trailing dead
# space reads as a broken crop once the GIF is scaled into a README.
HEIGHT = 352

# key, hex, cwd, the line shown while working
WINDOWS = [
    ("api", "#A3D8E1", "~/src/api", "$ npm run build"),
    ("web", "#6FB07A", "~/src/web", "$ git push origin main"),
    ("mobile", "#C4744A", "~/src/mobile", "$ xcodebuild -scheme App"),
    ("docs", "#D9B44A", "~/src/docs", '$ claude "update the changelog"'),
    ("infra", "#B07AC4", "~/src/infra", "$ terraform plan"),
    ("tooling", "#46C8B8", "~/src/tooling", "$ ./build.sh"),
]

# The window that finishes while you are looking somewhere else.
HERO = 3


def wash(hexcolor, pct):
    """tabtint.sh scale16(), in 8-bit rather than 16-bit."""
    h = hexcolor.lstrip("#")
    r, g, b = (int(h[i : i + 2], 16) for i in (0, 2, 4))
    return f"rgb({r * pct // 100},{g * pct // 100},{b * pct // 100})"


def frame_html(pct, caption, done):
    """One frame. pct is the hero window's current wash; everything else rests."""
    lit = pct > IDLE_PCT
    cells = []
    for i, (key, hexcolor, cwd, cmd) in enumerate(WINDOWS):
        hero = i == HERO
        bg = wash(hexcolor, pct if hero else IDLE_PCT)
        # Ring the hero only once it is clearly lit, so the ramp reads as the
        # colour moving rather than a border switching on.
        ring = " lit" if hero and pct >= ATTN_PCT - 4 else ""
        body = (
            '<div class="l ok">Done. 3 files changed.</div>'
            if hero and done
            else f'<div class="l">{cmd}</div>'
        )
        badge = (
            '<div class="badge">response ready</div>'
            if hero and lit and done
            else ""
        )
        cells.append(
            f'<div class="win{ring}">'
            f'<div class="bar"><span class="dots"><i></i><i></i><i></i></span>'
            f'<span class="chip" style="background:{hexcolor}"></span>'
            f'<span class="title">{key}</span></div>'
            f'<div class="body" style="background:{bg}">'
            f'<div class="l dim">{cwd}</div>{body}<div class="l cur">&#9613;</div>'
            f"</div>{badge}</div>"
        )

    return f"""<!doctype html><meta charset="utf-8"><style>
*{{box-sizing:border-box;margin:0}}
body{{background:#0d0d0f;font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;padding:32px;width:{WIDTH}px}}
.grid{{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}}
.win{{border-radius:7px;overflow:hidden;border:1px solid #2a2a2e;position:relative}}
.win.lit{{border-color:#D9B44A}}
.bar{{background:#1c1c1f;padding:6px 10px;display:flex;align-items:center;gap:7px}}
.dots{{display:flex;gap:4px}} .dots i{{width:8px;height:8px;border-radius:999px;background:#3a3a3e;display:block}}
.chip{{width:7px;height:7px;border-radius:2px;display:block;margin-left:2px}}
.title{{color:#c9c9c9;font-size:11px;font-family:Monaco,monospace}}
.body{{padding:11px;height:88px;font-family:Monaco,monospace;font-size:10.5px;color:#e8e8e8}}
.l{{margin-bottom:4px}} .dim{{color:#9a9a9a}} .cur{{color:#7a7a7a}} .ok{{color:#f2f2f2}}
.badge{{position:absolute;top:7px;right:8px;background:#D9B44A;color:#1a1408;font-size:9px;font-weight:700;padding:2px 6px;border-radius:5px}}
.cap{{color:#8a8a8a;font-size:13px;margin-top:20px;font-family:Monaco,monospace;height:16px}}
.cap b{{color:#D9B44A;font-weight:400}}
</style><body><div class="grid">{''.join(cells)}</div>
<div class="cap">{caption}</div></body>"""


def shoot(src, png, profile=None, timeout=40):
    """Screenshot src to png.

    Headless Chrome writes the file and then keeps running: the GCM/network
    service holds the process open, so waiting on exit hangs forever. Poll for
    the file instead, wait for its size to settle, then kill it.
    """
    proc = subprocess.Popen(
        [
            CHROME,
            "--headless=new",
            f"--user-data-dir={profile or src.parent / 'profile'}",
            "--no-first-run",
            "--no-sandbox",
            "--disable-gpu",
            "--hide-scrollbars",
            "--force-device-scale-factor=2",
            "--virtual-time-budget=2000",
            f"--window-size={WIDTH},{HEIGHT}",
            f"--screenshot={png}",
            f"file://{src}",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        last, stable, waited = -1, 0, 0.0
        while waited < timeout:
            time.sleep(0.25)
            waited += 0.25
            if png.exists():
                size = png.stat().st_size
                # Two consecutive equal sizes means the write finished.
                stable = stable + 1 if size == last and size > 0 else 0
                last = size
                if stable >= 2:
                    return
            if proc.poll() is not None and png.exists():
                return
    finally:
        proc.kill()
        proc.wait(timeout=10)


def storyboard():
    """(html, centiseconds) pairs. Long holds, short ramps."""
    idle_cap = "six sessions, each wearing its project colour"
    lit_cap = "<b>docs finished while you were somewhere else</b>"
    seen_cap = "you looked at it, back to resting"

    seq = [(frame_html(IDLE_PCT, idle_cap, False), 150)]

    steps = 6
    span = ATTN_PCT - IDLE_PCT
    for s in range(1, steps + 1):  # ramp up
        seq.append((frame_html(IDLE_PCT + span * s // steps, lit_cap, True), 4))
    seq.append((frame_html(ATTN_PCT, lit_cap, True), 200))  # hold lit
    for s in range(1, steps + 1):  # ramp down
        seq.append((frame_html(ATTN_PCT - span * s // steps, seen_cap, True), 5))
    seq.append((frame_html(IDLE_PCT, seen_cap, True), 130))
    return seq


def main():
    if not Path(CHROME).exists():
        sys.exit(f"Chrome not found at {CHROME}")
    if not shutil.which("magick"):
        sys.exit("ImageMagick not found (brew install imagemagick)")

    frames = storyboard()
    work = Path(tempfile.mkdtemp(prefix="tabtint-gif-"))
    # Chrome 136+ ignores --user-data-dir pointing at the default profile, and a
    # visible window here would be indistinguishable from a real session. Keep
    # it headless with a throwaway profile, and take the profile with us.
    profile = work / "profile"

    shot_paths = []
    for i, (html, _) in enumerate(frames):
        src = work / f"f{i:02d}.html"
        png = work / f"f{i:02d}.png"
        src.write_text(html)
        shoot(src, png, profile)
        if not png.exists():
            sys.exit(f"Chrome produced no output for frame {i}")
        shot_paths.append(png)
        print(f"  frame {i + 1}/{len(frames)}", file=sys.stderr)

    args = ["magick", "-loop", "0"]
    for (_, delay), png in zip(frames, shot_paths):
        args += ["-delay", str(delay), str(png)]
    # 128 colours is plenty for six flat washes and roughly halves the file.
    args += ["-layers", "OptimizePlus", "-colors", "128", str(OUT)]
    subprocess.run(args, check=True)

    shutil.rmtree(work, ignore_errors=True)
    print(f"wrote {OUT} ({OUT.stat().st_size // 1024} KB, {len(frames)} frames)")


if __name__ == "__main__":
    main()
