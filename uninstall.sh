#!/usr/bin/env bash
# Remove the 'athome' command from /usr/local/bin.

set -euo pipefail

LINK="/usr/local/bin/athome"

if [ ! -L "$LINK" ] && [ ! -f "$LINK" ]; then
  echo "athome is not installed at $LINK"
  exit 0
fi

sudo rm -f "$LINK"
echo "Removed: $LINK"
echo "Config and data in ~/.config/athome and ~/.local/share/athome are left intact."
