#!/usr/bin/env bash
# One-time Termux setup for s22-tuneup (and optionally Claude Code so `claude rc` works next time).
# Run inside Termux:   bash setup-termux.sh            (add --with-claude to also install Claude Code)
set -uo pipefail
WITH_CLAUDE=0; [[ "${1:-}" == "--with-claude" ]] && WITH_CLAUDE=1

if [[ -z "${PREFIX:-}" || ! -d "$PREFIX" ]]; then
  echo "This must run inside Termux (PREFIX is not set)."; exit 1
fi

echo "== updating Termux packages"
if ! pkg update -y; then
  cat <<MSG

pkg update failed. If you installed Termux from the Play Store, that build is abandoned and its repos are dead.
Install Termux from F-Droid (https://f-droid.org/packages/com.termux/) or GitHub releases, then rerun this.
MSG
  exit 1
fi
pkg upgrade -y
echo "== installing adb (android-tools), git, coreutils"
pkg install -y android-tools git coreutils grep sed gawk

if [[ $WITH_CLAUDE == 1 ]]; then
  echo "== installing Node.js + Claude Code (community-supported path; Anthropic ships no Android build)"
  pkg install -y nodejs-lts
  npm install -g @anthropic-ai/claude-code || { echo "npm install failed; see README 'Claude Code in Termux'"; exit 1; }
  CLI="$(npm root -g)/@anthropic-ai/claude-code/cli.js"
  RC="$HOME/.bashrc"; touch "$RC"
  grep -q 'alias claude=' "$RC" || cat >> "$RC" <<EOT

# Claude Code on Termux (the native installer's glibc binary cannot run on Android's bionic libc)
export TMPDIR="\$PREFIX/tmp"
alias claude='node $CLI'
EOT
  mkdir -p "$PREFIX/tmp"
  echo "== Claude Code: $(node "$CLI" --version 2>/dev/null || echo 'installed, run: source ~/.bashrc && claude --version')"
fi

cat <<MSG

== done. Next, on the phone:
  Settings > About phone > Software information > tap "Build number" 7x   (enables Developer options)
  Settings > Developer options > Wireless debugging: ON   (phone must be on Wi-Fi)
  Open Settings and Termux side by side (Recents > tap app icon > "Open in split screen view").
  Wireless debugging > "Pair device with pairing code"  ->  in Termux:  ./tuneup.sh pair <pairing port>
  Then from the main Wireless debugging screen "IP address & port"  ->  ./tuneup.sh connect <port>
  ./tuneup.sh report        # look first
  ./tuneup.sh debloat       # dry run
  ./tuneup.sh all           # do the whole thing, with a prompt before anything is removed
MSG
[[ $WITH_CLAUDE == 1 ]] && echo "  For Remote Control next time: source ~/.bashrc && termux-wake-lock && claude   then /login, then /rc"
exit 0
