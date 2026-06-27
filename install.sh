#!/usr/bin/bash
set -euo pipefail

LINK="/usr/local/bin/athome"
RAW="https://raw.githubusercontent.com/ungaul/athome/main/athome.sh"

if [ -z "${BASH_SOURCE[0]:-}" ] || [ ! -f "${BASH_SOURCE[0]}" ]; then
  echo "Downloading athome.sh -> $LINK"
  curl -fsSL "$RAW" | sudo tee "$LINK" > /dev/null
  sudo chmod +x "$LINK"
  mkdir -p "$HOME/.config/athome"
  echo "Installed: $LINK"
  echo "Run: athome"
  exit 0
fi

ATHOME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$ATHOME_DIR/athome.sh"

[ -f "$SCRIPT" ] || { echo "athome.sh not found in $ATHOME_DIR" >&2; exit 1; }

mkdir -p "$HOME/.config/athome"
chmod +x "$SCRIPT"
sudo ln -sf "$SCRIPT" "$LINK"

echo "Installed: $LINK"
echo "Run: athome"
