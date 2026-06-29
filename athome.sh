#!/usr/bin/env bash
# athome — dotfiles sync and machine bootstrap.
#
# Usage:
#   athome [--dry-run] [-y]            two-way sync (default)
#   athome --deploy [--dry-run] [-y]   one-way: repo -> live
#   athome --bootstrap [-y]            full Arch Linux machine setup
#
# On first run, athome asks which dotfiles repo to use and saves the answer
# to ~/.config/athome/config. Override with DOTFILES_DIR (local path) or
# DOTFILES_REPO_URL env vars.
#
# Two-way sync: state (last-synced sha256) in .dotfiles-sync-state.tsv.
#   only one side changed  -> copy that way
#   both changed           -> CONFLICT (interactive tty: prompt, else skip)
#   one side deleted       -> deletion propagated to the other side
#
# Deploy (--deploy): ignores state, copies repo -> live, backs up differing
# live files to ~/dotfiles_backup. Removes live files absent from repo (for
# tracked directory entries). One confirmation up front.

set -uo pipefail

ATHOME_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_FILE="${ATHOME_CONFIG:-$HOME/.config/athome/config}"
SYNC_FILE="${DOTFILES_SYNC_FILE:-$HOME/.config/athome/sync.conf}"
_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/athome"
STATE_FILE="$_DATA_DIR/sync-state.tsv"
BACKUP_DIR="$_DATA_DIR/backups"
LOCK_FILE="$_DATA_DIR/sync.lock"
BOOTSTRAP_LOG="$HOME/.athome-bootstrap.log"

DRY_RUN=0
DEPLOY=0
BOOTSTRAP=0
ASSUME_YES=0
ORIG_ARGS=("$@")
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=1 ;;
    --deploy)    DEPLOY=1 ;;
    --bootstrap) BOOTSTRAP=1 ;;
    --config)    mkdir -p "$(dirname "$CONFIG_FILE")"; ${EDITOR:-vi} "$CONFIG_FILE"; exit $? ;;
    --edit)      mkdir -p "$(dirname "$SYNC_FILE")"; ${EDITOR:-vi} "$SYNC_FILE"; exit $? ;;
    --list)      cat "$SYNC_FILE" 2>/dev/null || echo "(sync.conf is empty or not found)"; exit $? ;;
    -y|--yes)    ASSUME_YES=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
  C_CYAN=$'\033[36m'; C_BLUE=$'\033[34m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_GREEN=''; C_YELLOW=''; C_RED=''
  C_CYAN=''; C_BLUE=''
fi

BOOTSTRAP_STATUS=0

log() {
  local msg="$*" ts color="$C_RESET"
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  case "$msg" in
    *CONFLICT*)             color="$C_RED$C_BOLD" ;;
    *ERROR*|*FATAL*)        color="$C_RED" ;;
    *WARNING*|*"another sync"*) color="$C_YELLOW" ;;
    *PUSH*|*PULL*|*NEW*|*REPLACE*|*REMOVE*|"==> "*) color="$C_GREEN" ;;
    "synced="*)             color="$C_BOLD$C_CYAN" ;;
  esac
  printf '%s%s%s %s%s%s\n' "$C_DIM" "$ts" "$C_RESET" "$color" "$msg" "$C_RESET"
  [ "$BOOTSTRAP" -eq 1 ] && printf '%s %s\n' "$ts" "$msg" >> "$BOOTSTRAP_LOG"
  return 0
}

warn() {
  log "WARNING: $*"
  BOOTSTRAP_STATUS=1
}

die() {
  log "FATAL: $*"
  exit 1
}

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  read -r -p "$1 [y/N] " reply </dev/tty
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# ---- config ------------------------------------------------------------------

load_config() {
  # Always source the config file to load all settings (REMOVE_UNLISTED, etc.).
  # An env-exported DOTFILES_DIR overrides whatever the file says.
  local env_dir="${DOTFILES_DIR:-}"
  [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
  [ -n "$env_dir" ] && DOTFILES_DIR="$env_dir"
  [ -n "${DOTFILES_DIR:-}" ]
}

save_config() {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  {
    printf 'DOTFILES_DIR=%q\n' "$DOTFILES_DIR"
    [ -n "${DOTFILES_REPO_URL:-}" ] && printf 'DOTFILES_REPO_URL=%q\n' "$DOTFILES_REPO_URL"
    [ -n "${GITHUB_USER:-}" ]       && printf 'GITHUB_USER=%q\n'       "$GITHUB_USER"
    printf 'REMOVE_UNLISTED=%s\n' "${REMOVE_UNLISTED:-0}"
  } > "$CONFIG_FILE"
}

prompt_config() {
  # /dev/tty is the right check: reads go to /dev/tty regardless of stdout redirection
  [ -e /dev/tty ] || die "no dotfiles repo configured and not running interactively — set DOTFILES_DIR"
  DOTFILES_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/athome/dotfiles"
  printf '\n%sathome: first run — configure dotfiles repo%s\n' "$C_BOLD" "$C_RESET"
  printf '%s(repo will be stored at %s)%s\n\n' "$C_DIM" "$DOTFILES_DIR" "$C_RESET"

  if git -C "$DOTFILES_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    log "using existing repo at $DOTFILES_DIR"
  else
    printf 'Dotfiles repo URL (leave empty to init an empty repo): '
    read -r DOTFILES_REPO_URL </dev/tty
    if [ -n "${DOTFILES_REPO_URL:-}" ]; then
      GITHUB_USER="$(printf '%s' "$DOTFILES_REPO_URL" \
        | sed -E 's|https://github\.com/||; s|git@github\.com:||; s|/.*||')"
      log "cloning $DOTFILES_REPO_URL -> $DOTFILES_DIR"
      mkdir -p "$DOTFILES_DIR"
      git clone "$DOTFILES_REPO_URL" "$DOTFILES_DIR"
    else
      log "initializing empty repo at $DOTFILES_DIR"
      mkdir -p "$DOTFILES_DIR"
      git -C "$DOTFILES_DIR" init -q
    fi
  fi

  read -r -p "Remove packages not listed in .pacman during sync? [y/N] " reply </dev/tty
  case "${reply,,}" in y|yes) REMOVE_UNLISTED=1 ;; *) REMOVE_UNLISTED=0 ;; esac

  save_config
  log "config saved to $CONFIG_FILE"
  if [ ! -f "$SYNC_FILE" ]; then
  mkdir -p "$(dirname "$SYNC_FILE")"
  if [ -f "$DOTFILES_DIR/sync.conf" ]; then
    cp "$DOTFILES_DIR/sync.conf" "$SYNC_FILE"
    log "sync.conf loaded from dotfiles repo"
  else
    touch "$SYNC_FILE"
    log "created empty $SYNC_FILE — add paths to track there"
  fi
fi
  printf '\n'
}

REMOVE_UNLISTED=0
declare -a _TRACKED=()
declare -a _BLACKLIST=()

if ! load_config; then
  BOOTSTRAP=1
fi
load_config 2>/dev/null || prompt_config
REPO="$DOTFILES_DIR"

# ---- sync.conf parsing -------------------------------------------------------

load_sync_conf() {
  _TRACKED=()
  _BLACKLIST=()
  local section="" raw
  while IFS= read -r raw || [ -n "$raw" ]; do
    raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$raw" ] && continue
    case "$raw" in \#*) continue ;; esac
    case "$raw" in
      '[blacklist]') section=blacklist; continue ;;
      '['*']')       section="";        continue ;;
    esac
    if [ "$section" = blacklist ]; then
      _BLACKLIST+=("${raw%/}")
    else
      _TRACKED+=("$raw")
    fi
  done < "$SYNC_FILE"
}

is_blacklisted() {
  local path="$1" rel pattern
  [ "${#_BLACKLIST[@]}" -eq 0 ] && return 1
  case "$path" in
    "$HOME"/*) rel="${path#"$HOME"/}" ;;
    /*)        rel="${path#/}" ;;
    *)         rel="$path" ;;
  esac
  for pattern in "${_BLACKLIST[@]}"; do
    case "$rel" in
      "$pattern"|"$pattern"/*) return 0 ;;
    esac
  done
  return 1
}

# ---- sync helpers ------------------------------------------------------------

hash_of() {
  local f="$1"
  [ -f "$f" ] || return 0
  if [ ! -r "$f" ]; then
    log "  WARNING: cannot read $f (permission denied) — skipping"
    return 1
  fi
  sha256sum -- "$f" | cut -d' ' -f1
}

declare -A _STATE=()
_STATE_DIRTY=0

_state_load() {
  _STATE=()
  [ -f "$STATE_FILE" ] || return 0
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && _STATE["$k"]="$v"
  done < "$STATE_FILE"
}

_state_flush() {
  [ "$_STATE_DIRTY" -eq 0 ] && return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  local tmp
  tmp="$(mktemp "$STATE_FILE.XXXXXX")"
  local k
  for k in "${!_STATE[@]}"; do
    printf '%s\t%s\n' "$k" "${_STATE[$k]}"
  done > "$tmp"
  mv "$tmp" "$STATE_FILE"
  _STATE_DIRTY=0
}

state_get() {
  local v="${_STATE[$1]+x}"
  [ -n "$v" ] || return 1
  printf '%s\n' "${_STATE[$1]}"
}

state_set() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  _STATE["$1"]="$2"
  _STATE_DIRTY=1
}

state_del() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  unset "_STATE[$1]"
  _STATE_DIRTY=1
}

atomic_copy() {
  local src="$1" dst="$2" tmp
  mkdir -p "$(dirname -- "$dst")"
  tmp="$(mktemp "$(dirname -- "$dst")/.sync-tmp-XXXXXX")" || return 1
  if cp -p -- "$src" "$tmp"; then
    mv -f -- "$tmp" "$dst"
  else
    rm -f -- "$tmp"
    return 1
  fi
}

backup_live() {
  local live="$1" stamp rel
  stamp="$(date '+%Y%m%dT%H%M%S')"
  rel="$(printf '%s' "$live" | sed 's#^/##; s#/#__#g')"
  cp -p -- "$live" "$BACKUP_DIR/${stamp}__${rel}" \
    || { log "  ERROR   backup of $live failed — refusing to overwrite without backup"; return 1; }
}

resolve_conflict() {
  local live="$1" repo="$2" key="$3" mode="$4" reply
  # Pick the newer file by mtime; fall back to live if equal or unreadable
  _newer_side() {
    local lt rt
    lt=$(stat -c '%Y' "$live" 2>/dev/null || echo 0)
    rt=$(stat -c '%Y' "$repo" 2>/dev/null || echo 0)
    [ "$lt" -ge "$rt" ] && echo live || echo repo
  }
  # Non-interactive: keep whichever file is newer
  if [ ! -t 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    case "$mode" in
      both|repo-deleted)
        local _winner; _winner=$(_newer_side)
        if [ "$_winner" = live ]; then
          log "  CONFLICT $key: keeping live (newer)"
          atomic_copy "$live" "$repo" || { log "  ERROR   $key: copy failed"; ERRORS=$((ERRORS+1)); return; }
          state_set "$key" "$(hash_of "$live" || true)"
        else
          log "  CONFLICT $key: keeping repo (newer)"
          backup_live "$live" || { ERRORS=$((ERRORS+1)); return; }
          atomic_copy "$repo" "$live" || { log "  ERROR   $key: copy failed"; ERRORS=$((ERRORS+1)); return; }
          state_set "$key" "$(hash_of "$repo" || true)"
        fi
        SYNCED=$((SYNCED+1)) ;;
      live-deleted)
        log "  CONFLICT $key: live deleted but repo changed — skipping (run interactively to resolve)"
        CONFLICTS=$((CONFLICTS+1)) ;;
    esac
    return
  fi
  local _newer; _newer=$(_newer_side)
  case "$mode" in
    both)
      printf '\n%s  CONFLICT %s%s\n' "$C_RED$C_BOLD" "$key" "$C_RESET"
      printf '%s  %s- repo%s  %s+ live%s\n' "$C_DIM" "$C_RED" "$C_DIM" "$C_GREEN" "$C_RESET"
      diff --color=always -u --label repo --label live "$repo" "$live" 2>/dev/null \
        | tail -n +3 \
        | sed 's/^/  /' || true
      printf '%s  ──────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
      if [ "$_newer" = live ]; then
        printf '  [L]ive is newer — keep [L]ive or [r]epo? [L/r] '
      else
        printf '  [R]epo is newer — keep [r]epo or [l]ive? [R/l] '
      fi ;;
    live-deleted)
      printf '\n%s  CONFLICT %s%s: deleted on live but repo changed\n' \
        "$C_RED$C_BOLD" "$key" "$C_RESET"
      printf '  Keep [r]epo or delete from [b]oth? [r/b] ' ;;
    repo-deleted)
      printf '\n%s  CONFLICT %s%s: deleted in repo but live changed\n' \
        "$C_RED$C_BOLD" "$key" "$C_RESET"
      printf '  Keep [L]ive or delete from [b]oth? [L/b] ' ;;
  esac
  read -r reply </dev/tty
  # empty reply = default to whichever is newer
  [ -z "$reply" ] && reply=$_newer
  case "$mode:${reply,,}" in
    both:l)
      log "  RESOLVE $key: keeping live -> repo"
      atomic_copy "$live" "$repo" || { log "  ERROR   $key: copy failed"; ERRORS=$((ERRORS+1)); return; }
      state_set "$key" "$(hash_of "$live")"
      SYNCED=$((SYNCED+1)) ;;
    both:r)
      log "  RESOLVE $key: keeping repo -> live"
      backup_live "$live" || { ERRORS=$((ERRORS+1)); return; }
      atomic_copy "$repo" "$live" || { log "  ERROR   $key: copy failed"; ERRORS=$((ERRORS+1)); return; }
      state_set "$key" "$(hash_of "$repo")"
      SYNCED=$((SYNCED+1)) ;;
    live-deleted:r)
      log "  RESOLVE $key: restoring from repo -> live"
      atomic_copy "$repo" "$live" || { log "  ERROR   $key: copy failed"; ERRORS=$((ERRORS+1)); return; }
      state_set "$key" "$(hash_of "$repo")"
      SYNCED=$((SYNCED+1)) ;;
    live-deleted:b)
      log "  RESOLVE $key: deleting from both"
      rm -f -- "$repo"
      state_del "$key"
      SYNCED=$((SYNCED+1)) ;;
    repo-deleted:l)
      log "  RESOLVE $key: re-adding live -> repo"
      atomic_copy "$live" "$repo" || { log "  ERROR   $key: copy failed"; ERRORS=$((ERRORS+1)); return; }
      state_set "$key" "$(hash_of "$live")"
      SYNCED=$((SYNCED+1)) ;;
    repo-deleted:b)
      log "  RESOLVE $key: deleting from both"
      backup_live "$live" || { ERRORS=$((ERRORS+1)); return; }
      rm -f -- "$live"
      state_del "$key"
      SYNCED=$((SYNCED+1)) ;;
    *)
      log "  CONFLICT $key: unrecognised reply '$reply' — keeping live"
      atomic_copy "$live" "$repo" 2>/dev/null \
        || { log "  ERROR   $key: copy failed"; ERRORS=$((ERRORS+1)); return; }
      state_set "$key" "$(hash_of "$live")"
      SYNCED=$((SYNCED+1)) ;;
  esac
}

repo_path_for() {
  local live="$1"
  case "$live" in
    "$HOME"/*) printf '%s\n' "$REPO/${live#"$HOME"/}" ;;
    *)         printf '%s\n' "$REPO/${live#/}" ;;
  esac
}

sync_one_file() {
  local live="$1" repo="$2" key="$3"
  local prev live_hash repo_hash

  prev="$(state_get "$key" || true)"

  # Fast path: both files exist, are identical, and state is known — skip hashing entirely
  if [ -n "$prev" ] && [ -f "$live" ] && [ -f "$repo" ] && cmp -s -- "$live" "$repo"; then
    UNCHANGED=$((UNCHANGED+1))
    return
  fi

  live_hash="$(hash_of "$live" || true)"
  repo_hash="$(hash_of "$repo" || true)"

  if [ "$live_hash" = "$repo_hash" ]; then
    if [ -z "$live_hash" ]; then
      [ -n "$prev" ] && state_del "$key"
    else
      state_set "$key" "$live_hash"
      UNCHANGED=$((UNCHANGED+1))
    fi
    return
  fi

  if [ -z "$live_hash" ] && [ -n "$repo_hash" ]; then
    if [ -z "$prev" ]; then
      log "  NEW     $key (-> live)"
      [ "$DRY_RUN" -eq 1 ] || atomic_copy "$repo" "$live" || { log "  ERROR   $key: copy failed"; ERRORS=$((ERRORS+1)); return; }
      state_set "$key" "$repo_hash"
      SYNCED=$((SYNCED+1))
    elif [ "$prev" = "$repo_hash" ]; then
      log "  DELETE  $key (deleted on live -> deleting from repo)"
      [ "$DRY_RUN" -eq 1 ] || rm -f -- "$repo"
      state_del "$key"
      SYNCED=$((SYNCED+1))
    else
      resolve_conflict "$live" "$repo" "$key" "live-deleted"
    fi
    return
  fi

  if [ -n "$live_hash" ] && [ -z "$repo_hash" ]; then
    if [ -z "$prev" ]; then
      log "  NEW     $key (-> repo)"
      [ "$DRY_RUN" -eq 1 ] || atomic_copy "$live" "$repo" || { log "  ERROR   $key: copy failed"; ERRORS=$((ERRORS+1)); return; }
      state_set "$key" "$live_hash"
      SYNCED=$((SYNCED+1))
    elif [ "$prev" = "$live_hash" ]; then
      log "  DELETE  $key (deleted in repo -> deleting from live)"
      if [ "$DRY_RUN" -eq 0 ]; then
        backup_live "$live" || { ERRORS=$((ERRORS+1)); return; }
        rm -f -- "$live"
      fi
      state_del "$key"
      SYNCED=$((SYNCED+1))
    else
      resolve_conflict "$live" "$repo" "$key" "repo-deleted"
    fi
    return
  fi

  # both exist, differ
  if [ -n "$prev" ] && [ "$prev" = "$repo_hash" ]; then
    log "  PUSH    $key (live -> repo)"
    [ "$DRY_RUN" -eq 1 ] || atomic_copy "$live" "$repo" || { log "  ERROR   $key: copy failed"; ERRORS=$((ERRORS+1)); return; }
    state_set "$key" "$live_hash"
    SYNCED=$((SYNCED+1))
  elif [ -n "$prev" ] && [ "$prev" = "$live_hash" ]; then
    log "  PULL    $key (repo -> live)"
    if [ "$DRY_RUN" -eq 0 ]; then
      backup_live "$live" || { ERRORS=$((ERRORS+1)); return; }
      atomic_copy "$repo" "$live" || { log "  ERROR   $key: copy failed"; ERRORS=$((ERRORS+1)); return; }
    fi
    state_set "$key" "$repo_hash"
    SYNCED=$((SYNCED+1))
  else
    resolve_conflict "$live" "$repo" "$key" "both"
  fi
}

sync_dir_pair() {
  local live_root="$1" repo_root="$2"
  local tmp_list rel
  tmp_list="$(mktemp)"
  # || true: [ -d ] short-circuit exits 1 when a dir is absent — that's expected on first sync
  { [ -d "$live_root" ] && find "$live_root" -type f -printf '%P\n' || true
    [ -d "$repo_root" ] && find "$repo_root" -type f -printf '%P\n' || true
  } | sort -u > "$tmp_list"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    is_blacklisted "$live_root/$rel" && continue
    sync_one_file "$live_root/$rel" "$repo_root/$rel" "$live_root/$rel"
  done < "$tmp_list"
  rm -f "$tmp_list"
}

snapshot_enabled_units() {
  local out="$HOME/.config/systemd/user/.enabled-units" tmp
  command -v systemctl >/dev/null 2>&1 || return 0
  [ -d "$HOME/.config/systemd/user" ] || return 0
  tmp="$(mktemp)"
  systemctl --user list-unit-files --state=enabled --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -v '@' | sort > "$tmp"
  if [ -s "$tmp" ]; then mv "$tmp" "$out"; else rm -f "$tmp"; fi
}

deploy_backup_and_replace() {
  local live="$1" repo="$2" rel
  if [ -f "$live" ]; then
    rel="${live#"$HOME"/}"
    [ "$rel" = "$live" ] && rel="${live#/}"
    mkdir -p "$(dirname -- "$BACKUP_DIR/$rel")"
    mv -f -- "$live" "$BACKUP_DIR/$rel" \
      || { log "  ERROR   backup of $live failed — refusing to overwrite"; return 1; }
  fi
  atomic_copy "$repo" "$live"
}

# ---- package helpers ---------------------------------------------------------

# Strip whitespace and comments from a .pacman file; output sorted package list
pacman_listed() {
  local file="$1"
  grep -v '^[[:space:]]*#' "$file" \
    | grep -v '^[[:space:]]*$' \
    | sed 's/[[:space:]]*$//' \
    | sort
}

# ---- bootstrap stages --------------------------------------------------------

stage_system_update() {
  log "-- updating system (pacman -Syu) --"
  if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null
    log "  multilib repo added to /etc/pacman.conf"
  fi
  sudo pacman -Syu --noconfirm
}

stage_base_devel() {
  log "-- ensuring base-devel and git are installed --"
  sudo pacman -S --needed --noconfirm base-devel git
}

stage_gh_auth() {
  log "-- authenticating with GitHub via gh --"
  if ! command -v gh >/dev/null 2>&1; then
    log "  gh not found — installing via pacman..."
    sudo pacman -S --needed --noconfirm github-cli || { warn "could not install gh"; return 1; }
  fi
  if gh auth status >/dev/null 2>&1; then
    # Ensure admin:public_key scope is granted
    if ! gh auth status 2>&1 | grep -q 'admin:public_key'; then
      log "  refreshing gh scopes (adding admin:public_key)..."
      gh auth refresh -h github.com -s admin:public_key </dev/tty || warn "could not refresh gh scopes"
    fi
    log "  already authenticated ($(gh api user -q .login 2>/dev/null || true))"
    return 0
  fi
  if [ "$ASSUME_YES" -eq 1 ]; then
    warn "gh not authenticated — run: gh auth login"; return 1
  fi
  log "  launching gh auth login..."
  gh auth login --scopes "repo,admin:public_key" </dev/tty || { warn "gh auth login failed"; return 1; }
  log "  authenticated as $(gh api user -q .login 2>/dev/null || true)"
}

stage_clone() {
  log "-- checking for dotfiles repo at $REPO --"
  if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    log "dotfiles repo already present, pulling latest"
    git -C "$REPO" fetch origin -q 2>/dev/null && git -C "$REPO" reset --hard origin/main -q \
      || warn "git pull failed in $REPO, continuing with whatever is checked out"
    return 0
  fi
  [ -n "${DOTFILES_REPO_URL:-}" ] || die "repo not found at $REPO and DOTFILES_REPO_URL not set"
  # If gh is available and repo doesn't exist on GitHub, create it first
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    local repo_path
    repo_path="$(printf '%s' "$DOTFILES_REPO_URL" \
      | sed -E 's|https://github\.com/||; s|git@github\.com:||; s|\.git$||')"
    if ! gh repo view "$repo_path" >/dev/null 2>&1; then
      log "  repo $repo_path not found on GitHub, creating..."
      gh repo create "$repo_path" --private --confirm 2>/dev/null \
        || gh repo create "$repo_path" --private 2>/dev/null \
        || warn "could not create repo $repo_path, attempting clone anyway"
      log "  created $repo_path"
    fi
  fi
  log "cloning $DOTFILES_REPO_URL -> $REPO"
  mkdir -p "$(dirname "$REPO")"
  git clone -q "$DOTFILES_REPO_URL" "$REPO" 2>/dev/null \
    || { mkdir -p "$REPO"; git -C "$REPO" init -q
         git -C "$REPO" remote add origin "$DOTFILES_REPO_URL"
         log "  clone failed (empty repo?), initialized locally"; }
}

stage_yay() {
  log "-- checking for yay --"
  if pacman -Qi yay-bin &>/dev/null; then
    log "removing conflicting yay-bin"
    sudo pacman -Rns --noconfirm yay-bin || warn "could not remove yay-bin, continuing"
  fi
  if command -v yay >/dev/null 2>&1; then log "yay already installed"; return 0; fi
  log "installing yay from source"
  local tmp
  tmp="$(mktemp -d)"
  git clone -q https://aur.archlinux.org/yay.git "$tmp/yay"
  (cd "$tmp/yay" && makepkg -si --noconfirm)
  rm -rf "$tmp"
}

stage_rust() {
  log "-- ensuring rust toolchain is available --"
  if ! command -v rustc >/dev/null 2>&1; then
    command -v rustup >/dev/null 2>&1 || sudo pacman -S --needed --noconfirm rustup
    rustup toolchain install stable --no-self-update
    rustup default stable
  else
    log "rustc already available ($(rustc --version 2>/dev/null))"
  fi
}

stage_packages() {
  log "-- installing packages from .pacman --"
  [ -f "$REPO/.pacman" ] || { warn ".pacman not found in dotfiles repo, skipping package install"; return 1; }
  command -v yay >/dev/null 2>&1 || { warn "yay not found — run stage_yay first"; return 1; }
  mapfile -t pkgs < <(pacman_listed "$REPO/.pacman")
  [ "${#pkgs[@]}" -gt 0 ] || { log "no packages listed, skipping"; return 0; }
  mapfile -t missing < <(comm -23 <(printf '%s\n' "${pkgs[@]}") <(pacman -Qq | sort))
  if [ "${#missing[@]}" -eq 0 ]; then log "all packages already installed (explicit)"; return 0; fi
  log "${#missing[@]} package(s) to install"
  yay -S --needed --noconfirm --batchinstall --norebuild --removemake \
      --answerdiff None --answeredit None --answerclean None --ask 4 \
      --overwrite '*' \
      "${missing[@]}"
}

stage_mount_disks() {
  log "-- detecting unmounted secondary disks --"
  command -v lsblk >/dev/null 2>&1 || { warn "lsblk not found, skipping disk setup"; return 1; }
  local fstab_backup="/etc/fstab.bak.$(date +%s)" backed_up=0 failed=0
  local name type fstype mountpoint uuid pkname parent model mnt
  # lsblk -rno outputs space-separated columns, not tab-separated
  while IFS=' ' read -r name type fstype mountpoint uuid pkname; do
    [ -n "$name" ] || continue
    case "$type" in part|disk) ;; *) continue ;; esac
    [ -n "$fstype" ] && [ "$fstype" != "swap" ] || continue
    [ -z "$mountpoint" ] || continue
    [ -n "$uuid" ] || continue
    if grep -q "UUID=$uuid" /etc/fstab 2>/dev/null; then
      log "  $name (UUID=$uuid) already in fstab, skipping"; continue
    fi
    if [ "$type" = "part" ] && [ -n "$pkname" ]; then
      parent="/dev/$pkname"
    else
      parent="/dev/$name"
    fi
    model="$(lsblk -dno MODEL "$parent" 2>/dev/null | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    model="$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
    [ -n "$model" ] || model="disk-${uuid:0:8}"
    mnt="/mnt/$model"
    log "  found /dev/$name (fstype=$fstype, uuid=$uuid) -> $mnt"
    if [ "$backed_up" -eq 0 ]; then
      sudo cp /etc/fstab "$fstab_backup"
      log "  backed up /etc/fstab to $fstab_backup"
      backed_up=1
    fi
    sudo mkdir -p "$mnt"
    if printf 'UUID=%s %s %s defaults,nofail 0 2\n' "$uuid" "$mnt" "$fstype" \
         | sudo tee -a /etc/fstab >/dev/null \
       && sudo systemctl daemon-reload \
       && sudo mount "$mnt"; then
      sudo chown "$(id -u):$(id -g)" "$mnt"
      log "  mounted and chowned $mnt"
    else
      warn "  failed to mount $mnt (fstab backup at $fstab_backup)"
      failed=1
    fi
  done < <(lsblk -rno NAME,TYPE,FSTYPE,MOUNTPOINT,UUID,PKNAME)
  [ "$failed" -eq 0 ]
}

stage_docker() {
  log "-- setting up docker --"
  command -v docker >/dev/null 2>&1 || { warn "docker not installed (check .pacman), skipping"; return 1; }
  local user; user="$(id -un)"
  local added=0
  for grp in docker input; do
    if ! id -nG "$user" | grep -qw "$grp"; then
      sudo usermod -aG "$grp" "$user"
      log "  added $user to group $grp"
      added=1
    else
      log "  $user already in group $grp"
    fi
  done
  sudo systemctl enable docker 2>/dev/null || true
  sudo systemctl start docker 2>/dev/null || true
  [ "$added" -eq 1 ] && log "  NOTE: log out and back in for group memberships to take effect"
  return 0
}

stage_realtime() {
  log "-- setting up realtime group for shairport-sync --"
  getent group realtime >/dev/null 2>&1 || { sudo groupadd realtime; log "  created group 'realtime'"; }
  sudo usermod -aG realtime "$(id -un)"
  local limits_file="/etc/security/limits.d/99-realtime.conf"
  if [ ! -f "$limits_file" ]; then
    sudo mkdir -p "$(dirname "$limits_file")"
    printf '@realtime - rtprio 99\n@realtime - memlock unlimited\n' | sudo tee "$limits_file" >/dev/null
    log "  wrote $limits_file"
  fi
  if command -v restic >/dev/null 2>&1; then
    sudo setcap cap_dac_read_search=+eip "$(command -v restic)"
    log "  setcap cap_dac_read_search -> restic"
  fi
}

stage_system_services() {
  log "-- enabling avahi-daemon, sshd, and cronie --"
  local failed=0
  for svc in avahi-daemon.service sshd.service cronie.service; do
    if sudo systemctl enable --now "$svc"; then
      log "  $svc enabled"
    else
      warn "  failed to enable $svc"; failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

stage_display_manager() {
  log "-- enabling display manager --"
  local dm
  for dm in sddm gdm lightdm greetd; do
    if pacman -Qq "$dm" >/dev/null 2>&1; then
      if sudo systemctl enable "${dm}.service"; then
        log "  $dm enabled (takes effect on next boot)"
      else
        warn "  failed to enable $dm"; return 1
      fi
      return 0
    fi
  done
  log "  no known display manager installed (sddm/gdm/lightdm/greetd), skipping"
}

stage_dotfiles() {
  log "-- deploying tracked files (repo -> live, backed up to $HOME/dotfiles_backup) --"
  # Bootstrap: if live sync.conf is empty but repo has one, copy it first so --deploy can use it
  local repo_sync="$REPO/.config/athome/sync.conf"
  if [ -f "$repo_sync" ] && [ ! -s "$SYNC_FILE" ]; then
    mkdir -p "$(dirname "$SYNC_FILE")"
    cp "$repo_sync" "$SYNC_FILE"
    log "sync.conf bootstrapped from repo"
  fi
  local deploy_args=(--deploy)
  [ "$ASSUME_YES" -eq 1 ] && deploy_args+=(-y)
  local rc=0
  DOTFILES_DIR="$REPO" bash "$(readlink -f "${BASH_SOURCE[0]}")" "${deploy_args[@]}"
  [ "$rc" -eq 0 ] || warn "deploy exited with code $rc"
}

stage_crontab() {
  log "-- restoring crontab from .cron --"
  [ -f "$REPO/.cron" ] || { warn ".cron not found in dotfiles repo, skipping"; return 1; }
  local backup="$HOME/.cron.bak.$(date +%s)"
  if crontab -l >"$backup" 2>/dev/null; then log "existing crontab backed up to $backup"
  else rm -f "$backup"; log "no existing crontab to back up"; fi
  crontab "$REPO/.cron"
}

stage_ssh_perms() {
  log "-- fixing ~/.ssh permissions --"
  [ -d "$HOME/.ssh" ] || { log "no ~/.ssh, skipping"; return 0; }
  chmod 700 "$HOME/.ssh"
  find "$HOME/.ssh" -type f -name "*.pub" -exec chmod 644 {} +
  find "$HOME/.ssh" -type f -not -name "*.pub" -exec chmod 600 {} +
}

stage_ssh_keygen() {
  log "-- ensuring an ssh key exists --"
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  grep -q 'github.com' "$HOME/.ssh/known_hosts" 2>/dev/null \
    || ssh-keyscan github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
  if [ -f "$HOME/.ssh/id_ed25519" ]; then log "ssh key already exists"; return 0; fi
  ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N ""
}

stage_ssh_copy_id() {
  log "-- copying ssh key to hosts from ~/.ssh/config --"
  [ -f "$HOME/.ssh/config" ] || { log "no ~/.ssh/config, skipping"; return 0; }
  [ -f "$HOME/.ssh/id_ed25519.pub" ] || { warn "no public key to copy, skipping"; return 1; }
  local hosts host failed=0
  hosts="$(grep -i '^Host ' "$HOME/.ssh/config" | awk '{print $2}' | grep -v '\*' || true)"
  [ -n "$hosts" ] || { log "no concrete hosts found in ~/.ssh/config"; return 0; }
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    log "  ssh-copy-id -> $host"
    ssh-copy-id -i "$HOME/.ssh/id_ed25519.pub" "$host" \
      || { warn "  ssh-copy-id failed for $host (run manually later)"; failed=1; }
  done <<< "$hosts"
  [ "$failed" -eq 0 ]
}

stage_user_services() {
  log "-- enabling systemd --user services --"
  local dir="$HOME/.config/systemd/user"
  [ -d "$dir" ] || { log "no $dir, skipping"; return 0; }
  systemctl --user daemon-reload
  local list="$dir/.enabled-units"
  if [ ! -f "$list" ]; then
    warn "no $list (run athome on a working machine first to generate it), skipping"
    return 1
  fi
  local unit failed=0
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    if systemctl --user enable --now "$unit" >>"$BOOTSTRAP_LOG" 2>&1; then
      log "enabled $unit"
    else
      warn "failed to enable $unit (see $BOOTSTRAP_LOG)"; failed=1
    fi
  done < "$list"
  [ "$failed" -eq 0 ]
}

stage_shell() {
  log "-- checking login shell --"
  local fish_path
  fish_path="$(command -v fish || true)"
  [ -n "$fish_path" ] || { log "fish not installed, skipping"; return 0; }
  [ -d "$HOME/.config/fish" ] || { log "fish not tracked in dotfiles, skipping"; return 0; }
  if [ "${SHELL:-}" = "$fish_path" ]; then log "fish already the login shell"; return 0; fi
  log "setting fish as login shell"
  chsh -s "$fish_path"
}

stage_linger() {
  log "-- enabling linger --"
  sudo loginctl enable-linger "$(id -un)"
}

stage_hyprpm() {
  log "-- updating hyprpm plugins --"
  command -v hyprpm >/dev/null 2>&1 || { log "hyprpm not found, skipping"; return 0; }
  if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    local sig
    sig="$(ls /tmp/hypr/ 2>/dev/null | head -1)"
    if [ -n "$sig" ]; then
      export HYPRLAND_INSTANCE_SIGNATURE="$sig"
    else
      log "Hyprland not running, skipping hyprpm"; return 0
    fi
  fi
  hyprpm update || warn "hyprpm update failed"
}

stage_nautilus_terminal() {
  log "-- pointing nautilus-open-any-terminal at preferred terminal --"
  command -v gsettings >/dev/null 2>&1 || { log "gsettings not found, skipping"; return 0; }
  gsettings list-schemas 2>/dev/null \
    | grep -q '^com.github.stunkymonkey.nautilus-open-any-terminal$' \
    || { log "nautilus-open-any-terminal schema not found, skipping"; return 0; }
  local term
  if [ "$ASSUME_YES" -eq 1 ]; then
    log "  non-interactive, skipping terminal selection"
    return 0
  fi
  printf 'Terminal to use with nautilus (e.g. ghostty, kitty, alacritty): '
  read -r term </dev/tty
  [ -n "$term" ] || { log "  empty input, skipping"; return 0; }
  gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal "$term"
  log "  set to $term"
}

stage_git_identity() {
  log "-- configuring git identity --"
  local current_name current_email name email
  current_name="$(git config --global user.name 2>/dev/null || true)"
  current_email="$(git config --global user.email 2>/dev/null || true)"

  if [ -n "$current_name" ]; then
    log "  git user.name = $current_name (already set)"
  elif [ "$ASSUME_YES" -eq 1 ]; then
    warn "git user.name not set — run: git config --global user.name 'Your Name'"
  else
    local default_name="${GITHUB_USER:-}"
    printf 'Git user.name%s: ' "${default_name:+ [$default_name]}"
    read -r name </dev/tty
    name="${name:-$default_name}"
    if [ -n "$name" ]; then
      git config --global user.name "$name"
      log "  git user.name = $name"
    else
      warn "git user.name not set"
    fi
  fi

  if [ -n "$current_email" ]; then
    log "  git user.email = $current_email (already set)"
  elif [ "$ASSUME_YES" -eq 1 ]; then
    warn "git user.email not set — run: git config --global user.email 'you@example.com'"
  else
    printf 'Git user.email: '
    read -r email </dev/tty
    if [ -n "$email" ]; then
      git config --global user.email "$email"
      log "  git user.email = $email"
    else
      warn "git user.email not set"
    fi
  fi
}

stage_ssh_github() {
  log "-- authorizing SSH key on GitHub --"
  [ -f "$HOME/.ssh/id_ed25519.pub" ] || { warn "no SSH public key found, skipping"; return 1; }

  if ssh -o BatchMode=yes -o ConnectTimeout=5 -T git@github.com 2>&1 \
       | grep -q 'successfully authenticated'; then
    log "  SSH key already authorized on GitHub"
    return 0
  fi

  # Primary: use gh to add the key
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    local title; title="${HOSTNAME}-$(date '+%Y%m%d')"
    if gh ssh-key add "$HOME/.ssh/id_ed25519.pub" --title "$title"; then
      log "  SSH key added via gh ($title)"
      if git -C "$REPO" remote get-url origin 2>/dev/null | grep -q '^https://'; then
        git -C "$REPO" remote set-url origin \
          "$(git -C "$REPO" remote get-url origin \
             | sed 's|https://github\.com/|git@github.com:|')"
        log "  dotfiles remote switched to SSH"
      fi
      return 0
    else
      warn "gh ssh-key add failed, falling back to manual"
    fi
  fi

  # Fallback: manual
  if [ "$ASSUME_YES" -eq 1 ]; then
    warn "SSH key not yet on GitHub — add it manually: https://github.com/settings/keys"
    printf '  %s\n' "$(cat "$HOME/.ssh/id_ed25519.pub")"
    return 1
  fi
  printf '\n%sAdd this SSH key manually → https://github.com/settings/keys%s\n' "$C_BOLD" "$C_RESET"
  printf '  %s\n\n' "$(cat "$HOME/.ssh/id_ed25519.pub")"
  local i=0
  while [ "$i" -lt 10 ]; do
    read -r -p "Press Enter once added (or 's' to skip): " reply </dev/tty
    case "${reply,,}" in s|skip) log "  skipped"; return 0 ;; esac
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -T git@github.com 2>&1 \
         | grep -q 'successfully authenticated'; then
      log "  confirmed"
      return 0
    fi
    log "  not authenticated yet, try again..."; i=$((i+1))
  done
  warn "could not confirm GitHub SSH authentication"
}

stage_sudoers() {
  log "-- writing sudoers entry for athome pacman operations --"
  local file="/etc/sudoers.d/athome-pacman" user
  user="$(id -un)"
  local entry="$user ALL=(ALL) NOPASSWD: /usr/bin/pacman -Syu --noconfirm, /usr/bin/pacman -S --needed --noconfirm *, /usr/bin/pacman -Rns --noconfirm *"
  if [ -f "$file" ] && grep -qF "NOPASSWD:" "$file"; then
    log "  sudoers entry already exists"; return 0
  fi
  printf '%s\n' "$entry" | sudo tee "$file" > /dev/null
  sudo chmod 440 "$file"
  if sudo visudo -c -f "$file" >/dev/null 2>&1; then
    log "  wrote $file"
  else
    sudo rm -f "$file"
    warn "sudoers syntax check failed, removed $file"; return 1
  fi
}

# Remove packages in the given list that are safe to remove (no external dependents).
_remove_safe() {
  local -a to_remove=("$@")
  [ "${#to_remove[@]}" -eq 0 ] && return 0
  local safe_to_remove=() remove_set required_by blocked dep
  remove_set=$(printf '%s\n' "${to_remove[@]}")
  for pkg in "${to_remove[@]}"; do
    required_by=$(pacman -Qi "$pkg" 2>/dev/null \
      | grep '^Required By' | sed 's/[^:]*: //' | tr ' ' '\n' \
      | grep -v '^None$' | grep -v '^[[:space:]]*$' || true)
    blocked=0
    if [ -n "$required_by" ]; then
      while IFS= read -r dep; do
        grep -qx "$dep" <<<"$remove_set" || { blocked=1; break; }
      done <<<"$required_by"
    fi
    if [ "$blocked" -eq 1 ]; then
      true
    else
      safe_to_remove+=("$pkg")
    fi
  done
  [ "${#safe_to_remove[@]}" -eq 0 ] && return 0
  log "  removing ${#safe_to_remove[@]} unlisted official package(s): ${safe_to_remove[*]}"
  sudo pacman -Rns --noconfirm "${safe_to_remove[@]}"
}

stage_remove_unlisted() {
  log "-- removing packages not listed in .pacman --"
  [ "${REMOVE_UNLISTED:-0}" -eq 1 ] || { log "  REMOVE_UNLISTED disabled, skipping"; return 0; }
  [ -f "$REPO/.pacman" ] || { warn ".pacman not found, skipping"; return 1; }
  local -a _aur _official to_remove
  mapfile -t _aur < <(pacman -Qqem 2>/dev/null | sort)
  mapfile -t _official < <(
    comm -23 <(pacman -Qqe | sort) <(printf '%s\n' "${_aur[@]:-}" | sort)
  )
  mapfile -t to_remove < <(
    comm -23 <(printf '%s\n' "${_official[@]}") <(pacman_listed "$REPO/.pacman")
  )
  [ "${#to_remove[@]}" -eq 0 ] && { log "  no unlisted packages"; return 0; }
  _remove_safe "${to_remove[@]}"
}

stage_nqptp() {
  log "-- nqptp (AirPlay 2 clock sync for shairport-sync) --"
  command -v nqptp >/dev/null 2>&1 || { log "  nqptp not installed, skipping"; return 0; }
  if systemctl is-enabled nqptp.service >/dev/null 2>&1; then
    log "  nqptp already enabled"; return 0
  fi
  if [ "$ASSUME_YES" -eq 1 ]; then
    log "  nqptp skipped (non-interactive)"; return 0
  fi
  read -r -p "Enable nqptp? [y/N] " reply </dev/tty
  case "${reply,,}" in
    y|yes) sudo systemctl enable --now nqptp.service && log "  nqptp enabled" ;;
    *)     log "  nqptp skipped" ;;
  esac
}

run_stage() {
  local name="$1" cmd="${2:-}"
  printf '\n%s%s==>%s %s%s%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_BOLD" "$name" "$C_RESET"
  [ -n "$cmd" ] && printf '    %s$ %s%s\n' "$C_DIM" "$cmd" "$C_RESET"
  if [ "$ASSUME_YES" -ne 1 ]; then
    printf '    %s[Enter to run / s to skip]%s ' "$C_DIM" "$C_RESET"
    local reply
    read -r reply </dev/tty
    case "${reply,,}" in s|skip) printf '%s%s  - skipped%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"; return 0 ;; esac
  fi
  if "$name"; then
    printf '%s%s  ✓ %s%s\n' "$C_BOLD" "$C_GREEN" "$name" "$C_RESET"
  else
    printf '%s%s  ✗ %s%s\n' "$C_BOLD" "$C_RED" "$name" "$C_RESET"
    warn "stage '$name' failed, continuing"
  fi
}

# ---- bootstrap ---------------------------------------------------------------

if [ "$BOOTSTRAP" -eq 1 ]; then
  [ "$(id -u)" -ne 0 ] || die "do not run as root (uses sudo where needed)"
  command -v pacman >/dev/null 2>&1 || die "bootstrap only supports Arch Linux (pacman not found)"
  sudo -v || die "sudo authentication failed"
  ( while true; do sudo -v; sleep 60; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

  printf '== athome bootstrap starting (dotfiles: %s) ==\n' "$REPO" >> "$BOOTSTRAP_LOG"
  printf '%s%s' "$C_BOLD" "$C_CYAN"
  printf '       ▄▄ ▄▄                        \n'
  printf '      ▄██▄██          ▄             \n'
  printf ' ▄▀▀▄▄ ██ ████▄ ▄███▄ ███▄███▄ ▄█▀█▄\n'
  printf ' ▄█▀██ ██ ██ ██ ██ ██ ██ ██ ██ ██▄█▀\n'
  printf '▄█▄▄██▄██▄██ ██▄▀███▀▄██ ██ ██▄▀█▄▄▄\n'
  printf '%s' "$C_RESET"
  printf '\n%s dotfiles:%s %s\n' "$C_DIM" "$C_RESET" "$REPO"
  [ "$ASSUME_YES" -ne 1 ] && printf '%s Enter to run each stage, s to skip it.%s\n\n' "$C_DIM" "$C_RESET"

  run_stage stage_system_update     "sudo pacman -Syu"
  run_stage stage_base_devel        "sudo pacman -S base-devel git"
  run_stage stage_gh_auth           "gh auth login"
  run_stage stage_clone             "gh repo create / git clone $DOTFILES_REPO_URL → $REPO"
  run_stage stage_yay               "git clone aur/yay && makepkg -si"
  run_stage stage_sudoers           "NOPASSWD: pacman -Syu, -S --needed, -Rns only"
  run_stage stage_rust              "rustup toolchain install stable"
  run_stage stage_packages          "yay -S \$(cat $REPO/.pacman)"
  run_stage stage_remove_unlisted   "sudo pacman -Rns <packages not in .pacman>"
  run_stage stage_mount_disks       "sudo mount + echo UUID=... >> /etc/fstab"
  run_stage stage_docker            "sudo usermod -aG docker && systemctl enable --now docker"
  run_stage stage_realtime          "sudo groupadd realtime && tee /etc/security/limits.d/99-realtime.conf"
  run_stage stage_system_services   "systemctl enable --now avahi-daemon sshd cronie"
  run_stage stage_display_manager   "systemctl enable sddm/gdm/lightdm/greetd"
  run_stage stage_dotfiles          "athome --deploy"
  run_stage stage_crontab           "crontab $REPO/.cron"
  run_stage stage_ssh_perms         "chmod 700 ~/.ssh && chmod 600 ~/.ssh/*"
  run_stage stage_ssh_keygen        "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519"
  run_stage stage_ssh_copy_id       "ssh-copy-id <hosts from ~/.ssh/config>"
  run_stage stage_user_services     "systemctl --user enable --now <units>"
  run_stage stage_shell             "chsh -s $(command -v fish 2>/dev/null || echo fish)"
  run_stage stage_linger            "loginctl enable-linger $(id -un)"
  run_stage stage_nautilus_terminal "gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal <prompt>"
  run_stage stage_hyprpm            "hyprpm update"
  run_stage stage_git_identity      "git config --global user.name / user.email"
  run_stage stage_ssh_github        "gh ssh-key add ~/.ssh/id_ed25519.pub (fallback: manual)"
  run_stage stage_nqptp             "systemctl enable --now nqptp.service"

  if [ "$BOOTSTRAP_STATUS" -eq 0 ]; then
    printf '\n%s%s>> bootstrap finished, all stages OK%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  else
    printf '\n%s%s>> bootstrap finished with warnings (see %s)%s\n' \
      "$C_BOLD" "$C_YELLOW" "$BOOTSTRAP_LOG" "$C_RESET"
  fi
  printf '%sLog out and back in (or reboot) to pick up docker/input group memberships, fish shell, and display manager.%s\n' \
    "$C_DIM" "$C_RESET"
  printf '== athome bootstrap finished (status=%s) ==\n' "$BOOTSTRAP_STATUS" >> "$BOOTSTRAP_LOG"
  exit "$BOOTSTRAP_STATUS"
fi

# ---- deploy ------------------------------------------------------------------

[ -d "$REPO" ] || die "dotfiles dir does not exist: $REPO"

if [ "$DEPLOY" -eq 1 ]; then
  [ -f "$SYNC_FILE" ] || { log "no sync file at $SYNC_FILE, nothing to do"; exit 0; }
  load_sync_conf

  pending="$(mktemp)"
  stale="$(mktemp)"
  for raw in "${_TRACKED[@]+"${_TRACKED[@]}"}"; do
    raw="${raw%/}"
    case "$raw" in /*) live="$raw" ;; *) live="$HOME/$raw" ;; esac
    repo_target="$(repo_path_for "$live")"

    if [ -d "$repo_target" ]; then
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        is_blacklisted "$live/$rel" && continue
        printf '%s\t%s\n' "$live/$rel" "$repo_target/$rel" >> "$pending"
      done < <(find "$repo_target" -type f -printf '%P\n')
      if [ -d "$live" ]; then
        while IFS= read -r rel; do
          [ -n "$rel" ] || continue
          is_blacklisted "$live/$rel" && continue
          [ -f "$repo_target/$rel" ] || printf '%s\n' "$live/$rel" >> "$stale"
        done < <(find "$live" -type f -printf '%P\n')
      fi
    elif [ -f "$repo_target" ]; then
      is_blacklisted "$live" || printf '%s\t%s\n' "$live" "$repo_target" >> "$pending"
    fi
  done

  to_replace="$(mktemp)"
  while IFS=$'\t' read -r live repo; do
    [ "$(hash_of "$live" || true)" = "$(hash_of "$repo" || true)" ] && continue
    printf '%s\t%s\n' "$live" "$repo" >> "$to_replace"
  done < "$pending"
  rm -f "$pending"

  replace_count="$(wc -l < "$to_replace")"
  stale_count="$(wc -l < "$stale")"
  if [ "$replace_count" -eq 0 ] && [ "$stale_count" -eq 0 ]; then
    log "deploy: live already matches repo for every tracked file, nothing to do"
    rm -f "$to_replace" "$stale"
    exit 0
  fi

  [ "$replace_count" -gt 0 ] && \
    log "deploy: $replace_count file(s) differ and would be replaced (repo -> live)"
  [ "$stale_count" -gt 0 ] && \
    log "deploy: $stale_count file(s) exist on live but not in repo and would be removed"
  log "deploy: existing/removed live versions will be moved to $BACKUP_DIR first"

  if [ "$DRY_RUN" -eq 1 ]; then
    while IFS=$'\t' read -r live _repo; do log "  WOULD REPLACE $live"; done < "$to_replace"
    while IFS= read -r live; do log "  WOULD REMOVE  $live"; done < "$stale"
    rm -f "$to_replace" "$stale"
    exit 0
  fi

  if [ "$ASSUME_YES" -ne 1 ]; then
    read -r -p "Replace/remove these $((replace_count + stale_count)) file(s) to match this repo? [y/N] " reply </dev/tty
    case "$reply" in
      [yY]|[yY][eE][sS]) ;;
      *) log "deploy: aborted by user"; rm -f "$to_replace" "$stale"; exit 0 ;;
    esac
  fi

  replaced=0 errors=0
  while IFS=$'\t' read -r live repo; do
    if deploy_backup_and_replace "$live" "$repo"; then
      log "  REPLACED $live"; replaced=$((replaced+1))
    else
      log "  ERROR replacing $live"; errors=$((errors+1))
    fi
  done < "$to_replace"
  rm -f "$to_replace"

  removed=0
  rel=""
  while IFS= read -r live; do
    rel="${live#"$HOME"/}"
    [ "$rel" = "$live" ] && rel="${live#/}"
    mkdir -p "$(dirname -- "$BACKUP_DIR/$rel")"
    if mv -f -- "$live" "$BACKUP_DIR/$rel"; then
      log "  REMOVED  $live"; removed=$((removed+1))
    else
      log "  ERROR removing $live"; errors=$((errors+1))
    fi
  done < "$stale"
  rm -f "$stale"

  log "deploy done: replaced=$replaced removed=$removed errors=$errors"
  [ "$errors" -eq 0 ] || exit 1
  exit 0
fi

# ---- sync (default) ----------------------------------------------------------

mkdir -p "$BACKUP_DIR"
touch "$STATE_FILE"

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  log "another sync is already running, exiting"
  exit 0
fi

_state_load
trap '_state_flush' EXIT

SYNCED=0
UNCHANGED=0
CONFLICTS=0
ERRORS=0
_SYNCED_REPO_FILES=()  # repo paths touched this run

snapshot_enabled_units

if [ ! -s "$SYNC_FILE" ]; then
  _repo_sync="$REPO/.config/athome/sync.conf"
  if [ -f "$_repo_sync" ]; then
    mkdir -p "$(dirname "$SYNC_FILE")"
    cp "$_repo_sync" "$SYNC_FILE"
    log "sync.conf bootstrapped from repo"
  else
    log "no sync file at $SYNC_FILE, nothing to do"
    exit 0
  fi
fi

log "repo: pulling latest..."
git -C "$REPO" fetch origin -q 2>/dev/null && git -C "$REPO" reset --hard origin/main -q \
  || warn "git pull failed in $REPO, continuing with local copy"
log "repo: up to date"

load_sync_conf
log "files: starting sync..."
for raw in "${_TRACKED[@]+"${_TRACKED[@]}"}"; do
  raw="${raw%/}"
  case "$raw" in /*) live="$raw" ;; *) live="$HOME/$raw" ;; esac
  repo_target="$(repo_path_for "$live")"

  if [ -d "$live" ] || [ -d "$repo_target" ]; then
    sync_dir_pair "$live" "$repo_target"
  else
    is_blacklisted "$live" || sync_one_file "$live" "$repo_target" "$live"
  fi
done
log "files: sync done"

if command -v pacman >/dev/null 2>&1 && [ -f "$REPO/.pacman" ]; then
  mapfile -t _pkgs < <(pacman_listed "$REPO/.pacman")
  if [ "${#_pkgs[@]}" -gt 0 ]; then
    _pacman_hash="$(sha256sum "$REPO/.pacman" | cut -d' ' -f1)"
    _pacman_hash_cache="$_DATA_DIR/pacman.last-hash"
    _cached_hash="$(cat "$_pacman_hash_cache" 2>/dev/null || true)"
    mapfile -t _missing < <(comm -23 <(printf '%s\n' "${_pkgs[@]}") <(pacman -Qq | sort))
    if [ "${#_missing[@]}" -gt 0 ]; then
      if command -v yay >/dev/null 2>&1; then
        log "packages: installing ${#_missing[@]} missing package(s)"
        yay -S --needed --noconfirm --batchinstall --norebuild --removemake \
            --answerdiff None --answeredit None --answerclean None --ask 4 \
            --overwrite '*' \
            "${_missing[@]}" && printf '%s\n' "$_pacman_hash" > "$_pacman_hash_cache" \
          || warn "some packages failed to install"
      else
        warn "packages: ${#_missing[@]} missing, but yay not found — install yay to manage packages"
      fi
    else
      log "packages: all present"
      printf '%s\n' "$_pacman_hash" > "$_pacman_hash_cache"
    fi
    if [ "${REMOVE_UNLISTED:-0}" -eq 1 ]; then
      mapfile -t _aur < <(pacman -Qqem 2>/dev/null | sort)
      mapfile -t _official < <(
        comm -23 <(pacman -Qqe | sort) <(printf '%s\n' "${_aur[@]:-}" | sort)
      )
      mapfile -t _extra < <(
        comm -23 <(printf '%s\n' "${_official[@]}") <(printf '%s\n' "${_pkgs[@]}")
      )
      if [ "${#_extra[@]}" -gt 0 ]; then
        _remove_safe "${_extra[@]}" || warn "some packages failed to remove"
      fi
    fi
  fi
fi

if [ -f "$REPO/.cron" ]; then
  _cron_hash="$(sha256sum "$REPO/.cron" | cut -d' ' -f1)"
  _cron_hash_cache="$_DATA_DIR/cron.last-hash"
  _cron_cached="$(cat "$_cron_hash_cache" 2>/dev/null || true)"
  if [ "$_cron_hash" != "$_cron_cached" ]; then
    log "cron: applying $REPO/.cron"
    if crontab "$REPO/.cron"; then
      printf '%s\n' "$_cron_hash" > "$_cron_hash_cache"
    else
      warn "cron: crontab failed"
    fi
  else
    log "cron: unchanged, skipping"
  fi
fi

log ""
log "synced=$SYNCED unchanged=$UNCHANGED conflicts=$CONFLICTS errors=$ERRORS"

if [ "$SYNCED" -gt 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  if git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet \
      && [ -z "$(git -C "$REPO" ls-files --others --exclude-standard)" ]; then
    log "repo: nothing to commit"
  else
    log "repo: committing and pushing..."
    git -C "$REPO" add -A
    git -C "$REPO" commit -m "sync: $(date -Iseconds)" -q \
      && git -C "$REPO" push origin HEAD -q \
      && log "repo: pushed" \
      || warn "repo: git push failed"
  fi
fi

if [ "$ERRORS" -gt 0 ]; then exit 1
elif [ "$CONFLICTS" -gt 0 ]; then exit 2
fi
exit 0
