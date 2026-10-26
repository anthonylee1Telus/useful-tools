#!/bin/sh
# Delete one herdr-pair comms dir; refuse anything else.
set -eu
[ $# -eq 1 ] && [ -d "$1" ] || { echo "usage: cleanup.sh <herdr-pair dir>" >&2; exit 2; }
dir=$(cd "$1" && pwd -P); parent=$(dirname "$dir")
case "$(basename "$dir")" in herdr-pair.??????) ;; *) echo "refusing: $dir" >&2; exit 1 ;; esac
ok=0
for root in "${TMPDIR:-}" /tmp "${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}"; do
  [ -n "$root" ] && [ -d "$root" ] && [ "$parent" = "$(cd "$root" && pwd -P)" ] && ok=1
done
[ "$ok" = 1 ] || { echo "refusing: $parent is not a temp root" >&2; exit 1; }
rm -rf -- "$dir" && echo "deleted $dir"