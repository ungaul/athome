#!/usr/bin/bash
set -euo pipefail

LINK="/usr/local/bin/athome"
RAW="https://raw.githubusercontent.com/ungaul/athome/main/athome.sh"

setup_sudoers() {
  local file="/etc/sudoers.d/athome-pacman"
  local user; user="$(id -un)"
  local entry="$user ALL=(ALL) NOPASSWD: /usr/bin/pacman *"
  if [ -f "$file" ] && grep -qF "$entry" "$file"; then
    echo "sudoers entry already exists"; return 0
  fi
  printf '%s\n' "$entry" | sudo tee "$file" > /dev/null
  sudo chmod 440 "$file"
  if sudo visudo -c -f "$file" >/dev/null 2>&1; then
    echo "wrote $file"
  else
    sudo rm -f "$file"
    echo "sudoers syntax check failed" >&2; return 1
  fi
}

if [ -z "${BASH_SOURCE[0]:-}" ] || [ ! -f "${BASH_SOURCE[0]}" ]; then
  echo "Downloading athome.sh -> $LINK"
  curl -fsSL "$RAW" | sudo tee "$LINK" > /dev/null
  sudo chmod +x "$LINK"
  mkdir -p "$HOME/.config/athome"
  setup_sudoers
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
setup_sudoers

echo "Installed: $LINK"
echo "Run: athome"
