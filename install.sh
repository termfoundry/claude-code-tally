#!/bin/sh
# Installs this status line for Claude Code: copies statusline-command.sh to
# ~/.claude/ (a different existing one is kept as a dated backup) and prints
# the settings.json entry it needs. Nothing else on the machine is changed.
set -e

# CDPATH unset: a cd it finds the folder through prints the path, a second time
here=$(CDPATH= cd "$(dirname "$0")" && pwd)
dest="$HOME/.claude/statusline-command.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required: brew install jq (macOS) or sudo apt install jq (Debian/Ubuntu)." >&2
  exit 1
fi

mkdir -p "$HOME/.claude"
src="$here/statusline-command.sh"
if [ "$src" -ef "$dest" ]; then
  echo "$dest already is this script (a link to it): nothing to copy"
elif [ -L "$dest" ]; then
  # Copying would write through the link into the file it points to
  echo "$dest is a link to another file and was left as it is: remove the link, then run this again." >&2
  exit 1
else
  if [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
    backup="$dest.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$dest" "$backup"
    echo "Kept your current script as $backup"
  fi
  # Copied next to it, then renamed into place in one step: a refresh running
  # at that moment reads the old script or the new one, never half of each.
  cp "$src" "$dest.new.$$" && mv -f "$dest.new.$$" "$dest" || { rm -f "$dest.new.$$"; exit 1; }
  echo "Installed $dest"
fi
echo

if grep -q '"statusLine"' "$HOME/.claude/settings.json" 2>/dev/null; then
  echo "~/.claude/settings.json already has a \"statusLine\" entry. It should read:"
else
  echo "Add this to ~/.claude/settings.json (inside the top-level { }):"
fi
cat <<'EOF'

  "statusLine": { "type": "command", "command": "sh ~/.claude/statusline-command.sh", "refreshInterval": 10 }

EOF
echo "The status line updates in running sessions at their next refresh."
