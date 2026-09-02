#!/usr/bin/env bash
# Run the guided tour in a fixed-size detached tmux and snapshot the pane on a
# timer. Each frame is the pane's text with its colour escapes (`capture-pane
# -e`) plus a sibling .time file holding milliseconds since the tour started;
# render.py turns the pair into a GIF.
#
#   ./capture.sh [OUTDIR] [COLS] [ROWS] [TOTAL_MS]
#
# Defaults produce the 140x38 capture the README's recording is made from.
# Integer milliseconds throughout: bc is not everywhere.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

OUT="${1:-${XDG_CACHE_HOME:-$HOME/.cache}/floating-claude/record}"
COLS="${2:-140}"
ROWS="${3:-38}"
TOTAL_MS="${4:-72000}"
SESSION=fc-record

command -v tmux >/dev/null || { echo "tmux is required" >&2; exit 1; }

rm -rf "$OUT/frames"
mkdir -p "$OUT/frames"
tmux kill-session -t $SESSION 2>/dev/null || true

tmux new-session -d -s $SESSION -x "$COLS" -y "$ROWS" -c "$ROOT"
# Without RGB in terminal-features, truecolor never reaches the capture.
tmux set-option -t $SESSION default-terminal "tmux-256color"
tmux set-option -t $SESSION -as terminal-features ",*:RGB"
tmux set-option -t $SESSION status off

tmux send-keys -t $SESSION \
  "clear && nvim -u $HERE/init.lua -i NONE lua/floating-claude/watcher.lua" Enter
sleep 3
tmux send-keys -t $SESSION ":FloatingClaudeDemo auto" Enter

start=$(date +%s%3N)
i=0
while :; do
  elapsed=$(( $(date +%s%3N) - start ))
  (( elapsed > TOTAL_MS )) && break
  printf -v name "%04d" $i
  echo "$elapsed" > "$OUT/frames/$name.time"
  tmux capture-pane -e -p -t $SESSION > "$OUT/frames/$name.txt"
  i=$(( i + 1 ))
  sleep 0.07
done

tmux kill-session -t $SESSION 2>/dev/null || true
echo "captured $i frames over ${elapsed}ms into $OUT/frames"

# The tour is over once the caption window stops appearing; anything after that
# is the restored editor and wants trimming out of the render.
last=$(grep -l 'floating-claude ·' "$OUT"/frames/*.txt | tail -1 || true)
[ -n "$last" ] && echo "last captioned frame: $(basename "$last" .txt)"
