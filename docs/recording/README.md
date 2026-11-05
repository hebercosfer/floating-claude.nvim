# Recording the tour

`../demo.gif` is `:FloatingClaudeDemo auto` captured from a real Neovim, not a
drawing, and the video in the README is encoded from the same frames. These two
scripts remake both, so the recording can be regenerated when the float or the
notification changes shape.

```sh
FC_OWN_CONFIG=1 ./capture.sh       # detached tmux, 140x38, ~125s, in your own config
python3 -m venv venv && ./venv/bin/pip install pillow
# FC_FG / FC_BG: your colourscheme's Normal colours (tokyonight-moon's here).
FC_FG=c8d3f5 FC_BG=222436 ./venv/bin/python render.py \
  ~/.cache/floating-claude/record/frames ../demo.gif 140 38 24 0 LAST 1
```

`capture.sh` prints the number of frames and the last frame that still had a
caption on it — that is the end of the tour, and the `LAST` argument to pass to
`render.py`. Everything after it is the restored editor.

`render.py` also drops the drawn frames as PNGs in a `cache/` beside the frame
directory, so a second encode at different settings does not mean drawing them
all again. It is safe to delete.

## The video

The README shows an MP4 of the same frames rather than the GIF: sharper text,
and a player that pauses and scrubs. GitHub only plays video from its own
attachment host, so it is not in this tree: encode it, drag it into any comment box on GitHub, and
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
"$FF" -f concat -safe 0 -i concat.txt \
  -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2,fps=30,scale=out_color_matrix=bt709:out_range=tv,format=yuv420p" \
  -c:v libx264 -preset slow -crf 20 -tune animation \
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -movflags +faststart demo.mp4
```

The concat list keeps each frame's captured duration. Do not expect it to be
smaller than the GIF: a terminal barely changes between frames, which is the
case `disposal=1` handles best, and the MP4 came out at 1.3MB to the GIF's
0.8MB. What it buys is text without a 256-colour palette, and a pause button.

## What breaks it

- **Render at font size 24, twice the terminal's.** The video stores colour at
  half resolution (`yuv420p`, the only kind every browser plays), so a 1-pixel
  border came out greyed, with a dark fringe, and no two borders alike. At
  twice the size every line is 2 pixels wide, drawn from an even pixel so it
  fills whole 2x2 colour blocks and keeps its colour, and the text is sharp on a
  high-DPI screen. The odd width that gives is padded to even, and the video is
  converted and tagged as BT.709, which is what a browser assumes for HD.
- **Box-drawing characters are drawn, not typeset.** A terminal draws `─ │ ╭`
  and the rest itself, edge to edge in the cell, which is why its borders join
  without a seam; the font's glyphs are thinner and soft at every join.
  `BOX_CHARS` lists the ones the renderer draws; add to it when a capture shows
  a new one.
- **The cell width has to be the font's exact advance.** JetBrainsMono advances
  7.203px at size 12; rounded to 7, a 128-cell run of text drawn as one string
  ended 26px right of the grid, so the float's right border landed in a
  different column on every row. Every recording before 0.5.0 had this.
- **Backgrounds go down before any glyph.** Painting a row's background and
  then its text, row by row, let the next row's background cover the foot of
  Claude's `⎿`, which hangs below its cell, and it read as a plain bar.
- **Your own colourscheme needs `FC_FG` and `FC_BG`.** Neovim writes its Normal
  background out on some rows and leaves others to the terminal's default;
  unless the renderer paints the default in the same colour, the code sits on
  bands. Set both to the Normal highlight, e.g. `FC_FG=c8d3f5 FC_BG=222436`
  for tokyonight-moon.
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

Every beat should appear; the caption's `n/total` says how many there are. Comparing each beat's first frame against its
`.time` file shows how long it was actually on screen, which is how the edit
approval was found to be lasting 2.2 seconds — too fast to read in a recording,
and fixed by `auto_ms` on that beat in `demo/script.lua`.
