# athome
Bootstrap and sync tool for dotfiles on Arch Linux. Works with any dotfiles repo that mirrors files at their `$HOME`-relative paths.

## Install
```bash
curl -fsSL https://raw.githubusercontent.com/ungaul/athome/main/install.sh | bash
```

## Usage
```bash
athome
```

| Flag | Description |
|---|---|
| `athome` | Two-way sync: files listed in `sync.conf` are kept in sync between their live location and the dotfiles repo |
| `--deploy` | One-way push from repo → live, backs up any differing files first |
| `--bootstrap` | Full machine setup: packages, dotfiles, services, SSH, shell. Runs automatically on first launch. Automatically running on first launch of `athome` |
| `--dry-run` | Preview what would change without touching anything |
| `-y` | Skip all confirmations |

### Cron (nightly auto-sync)

```
0 3 * * * athome
```
