# Recording the tour

`../demo.gif` is `:FloatingClaudeDemo auto` captured from a real Neovim, not a
drawing. These two scripts remake it, so the picture in the README can be
regenerated when the float or the notification changes shape.

```sh
./capture.sh                       # detached tmux, 140x38, ~72s
python3 -m venv venv && ./venv/bin/pip install pillow
./venv/bin/python render.py \
  ~/.cache/floating-claude/record/frames ../demo.gif 140 38 12 0 875 1
```

`capture.sh` prints the number of frames and the last frame that still had a
caption on it — that is the end of the tour, and the `LAST` argument to pass to
`render.py`. Everything after it is the restored editor.

`render.py` also drops the drawn frames as PNGs in a `cache/` beside the frame
directory, so a second encode at different settings does not mean drawing them
all again. It is safe to delete.

## The video

The README also links an MP4 of the same frames, for watching with a player
that pauses and scrubs. GitHub only plays video from its own attachment host, so
it is not in this tree: encode it, drag it into any comment box on GitHub, and
use the `user-attachments` URL that comes back. `imageio-ffmpeg` brings its own
ffmpeg, so nothing else needs installing:

```sh
./venv/bin/pip install imageio-ffmpeg
FF=$(./venv/bin/python -c "import imageio_ffmpeg as i; print(i.get_ffmpeg_exe())")
cd ~/.cache/floating-claude/record/cache
python3 -c "
d = [int(x) for x in open('durations.txt').read().split()]
for i, ms in enumerate(d): print(f\"file '{i:04d}.png'\nduration {ms/1000:.3f}\")
print(f\"file '{len(d)-1:04d}.png'\")" > concat.txt
"$FF" -f concat -safe 0 -i concat.txt -vf "fps=30,format=yuv420p" \
  -c:v libx264 -preset slow -crf 20 -tune animation -movflags +faststart demo.mp4
```

The concat list keeps each frame's captured duration. Do not expect it to be
smaller than the GIF: a terminal barely changes between frames, which is the
case `disposal=1` handles best, and the MP4 came out at 1.3MB to the GIF's
0.8MB. What it buys is text without a 256-colour palette, and a pause button.

## What breaks it

- **`disposal=1`, never `2`.** Disposal 2 clears each frame to the background,
  so every frame has to carry the whole screen. The same 67 seconds came out at
  12.5MB that way and 606KB this way.
- **Glyph fallback.** JetBrainsMono has no glyph for `⎿ ✢ ✻ ✽ ⧉`, which are
  precisely the characters Claude's TUI leans on. A terminal falls back per
  glyph; Pillow does not, and they render as empty boxes. Adwaita Mono covers
  all five and is metrically compatible. Override either family with
  `FC_FONT_DIR` and `FC_FALLBACK_DIR`.
- **Trailing blanks.** `tmux capture-pane` strips them, so each row has to carry
  its last background colour out to the edge — otherwise the float ends up with
  a hole punched in its right-hand side.
- **`terminal-features ",*:RGB"`.** Without it truecolor never reaches the
  capture and everything arrives in 256 colours.

## Checking a capture

```sh
grep -oh 'floating-claude · [0-9]*/[0-9]*' frames/*.txt | sort -u
```

Every beat should appear, fourteen as the tour stands. Comparing each beat's first frame against its
`.time` file shows how long it was actually on screen, which is how the edit
approval was found to be lasting 2.2 seconds — too fast to read in a recording,
and fixed by `auto_ms` on that beat in `demo/script.lua`.
