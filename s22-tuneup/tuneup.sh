#!/usr/bin/env bash
# s22-tuneup: debloat, de-notify and speed up a Samsung phone from Termux over wireless ADB.
# Everything is reversible: a snapshot is taken first, every change is logged, and `restore` undoes it.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LISTS="$HERE/lists"
BACKUP="${TUNEUP_BACKUP:-$HOME/s22-tuneup-backups}"
ADB="${ADB:-adb}"
USER_ID="${TUNEUP_USER:-0}"
APPLY=0; WITH_OPTIONAL=0; WITH_CARRIER=0; MODE="uninstall"; YES=0

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_dim=$'\e[2m'; c_off=$'\e[0m'
log()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s!%s %s\n' "$c_yel" "$c_off" "$*"; }
die()  { printf '%s✖ %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }

usage() {
cat <<USAGE
usage: tuneup.sh <command> [options]

  pair <pairing-port>        adb pair 127.0.0.1:<port>  (Developer options > Wireless debugging > Pair device with pairing code)
  connect <port>             adb connect 127.0.0.1:<port> (the port on the main Wireless debugging screen, NOT the pairing one)
  status                     is adb connected?
  snapshot                   save package lists, settings, notification state to $BACKUP (run automatically before changes)
  report                     model, storage, RAM, top CPU, package counts, noisiest notification senders
  notif-audit                who has been posting notifications (from the system notification archive), ranked
  notif-mute --preset        revoke notification permission for known promo/nag system apps (lists/notify-mute.txt)
  notif-mute <pkg>...        same, for specific packages (protected apps are refused)
  notif-unmute --all|<pkg>.. restore notification permission
  debloat [--apply] [--with-optional] [--carrier] [--mode uninstall|disable]
                             dry run by default; --apply removes Tier 1 (lists/debloat-safe.txt) for user $USER_ID
  restore --all|<pkg>...     reinstall/enable packages removed by debloat (from the manifest)
  speed [--apply]            0.5x animations, trim app caches, background dexopt, restrict background for kept bloat
  all [--yes] [--with-optional] [--carrier]
                             snapshot -> report -> debloat --apply -> notif-mute --preset -> speed --apply -> report

env: ADB (default adb), TUNEUP_BACKUP (default ~/s22-tuneup-backups), TUNEUP_USER (default 0)
USAGE
}

# ---------- adb helpers ----------
ash() { "$ADB" shell "$@" 2>/dev/null | tr -d '\r'; }
need_device() {
  local st; st=$("$ADB" get-state 2>/dev/null | tr -d '\r' || true)
  [[ "$st" == "device" ]] && return 0
  cat >&2 <<MSG
No phone attached over adb. On the phone: Settings > Developer options > Wireless debugging (on, same Wi-Fi).
  1. tap "Pair device with pairing code"  ->  ./tuneup.sh pair <pairing-port>   (enter the 6-digit code when asked)
  2. back on the Wireless debugging screen, read "IP address & port"  ->  ./tuneup.sh connect <port>
Tip: open Settings and Termux in split screen so the code stays visible.
MSG
  exit 1
}

# ---------- list parsing ----------
# strip comments/blank lines, print "token<TAB>comment"
read_list() {
  local f="$1"; [[ -f "$f" ]] || return 0
  sed -e 's/\r$//' "$f" | awk '
    /^[[:space:]]*(#|$)/ {next}
    { line=$0; cmt=""; i=index(line,"#"); if(i>0){cmt=substr(line,i+1); line=substr(line,1,i-1)}
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",line); gsub(/^[[:space:]]+|[[:space:]]+$/,"",cmt)
      if(line!="") printf "%s\t%s\n", line, cmt }'
}
declare -a PROT_EXACT=() PROT_RE=()
load_protected() {
  local tok cmt
  while IFS=$'\t' read -r tok cmt; do
    case "$tok" in
      "~"*) PROT_RE+=("${tok#\~}") ;;
      *"*"*) PROT_RE+=("^${tok//./\\.}"); PROT_RE[-1]="${PROT_RE[-1]//\*/.*}\$" ;;
      *) PROT_EXACT+=("$tok") ;;
    esac
  done < <(read_list "$LISTS/protected.txt")
}
is_protected() {  # $1 pkg
  local p="$1" x re
  for x in "${PROT_EXACT[@]}"; do [[ "$x" == "$p" ]] && return 0; done
  shopt -s nocasematch
  for re in "${PROT_RE[@]}"; do [[ "$p" =~ $re ]] && { shopt -u nocasematch; return 0; }; done
  shopt -u nocasematch; return 1
}

# installed package sets (filled by load_packages)
declare -A SYS=() ALL=() LABEL=()
load_packages() {
  local p
  while read -r p; do [[ -n "$p" ]] && ALL["$p"]=1; done < <(ash pm list packages --user "$USER_ID" | sed 's/^package://')
  while read -r p; do [[ -n "$p" ]] && SYS["$p"]=1; done < <(ash pm list packages -s --user "$USER_ID" | sed 's/^package://')
  [[ ${#ALL[@]} -gt 0 ]] || die "pm list packages returned nothing; is adb really connected?"
}

# expand a list file (exact names + *globs) against installed SYSTEM packages -> prints "pkg<TAB>comment"
expand_against_system() {
  local f="$1" tok cmt p re
  while IFS=$'\t' read -r tok cmt; do
    if [[ "$tok" == *"*"* ]]; then
      re="^${tok//./\\.}"; re="${re//\*/.*}\$"
      for p in "${!SYS[@]}"; do [[ "$p" =~ $re ]] && printf '%s\t%s\n' "$p" "$cmt"; done
    else
      [[ -n "${SYS[$tok]:-}" ]] && printf '%s\t%s\n' "$tok" "$cmt"
    fi
  done < <(read_list "$f")
}
expand_carrier() {
  local -a inc=() exc=(); local tok cmt p re hit
  while IFS=$'\t' read -r tok cmt; do
    case "$tok" in "!~"*) exc+=("${tok#!\~}") ;; "~"*) inc+=("${tok#\~}") ;; esac
  done < <(read_list "$LISTS/carrier-patterns.txt")
  for p in "${!SYS[@]}"; do
    hit=0; for re in "${inc[@]}"; do [[ "$p" =~ $re ]] && { hit=1; break; }; done
    [[ $hit == 1 ]] || continue
    for re in "${exc[@]}"; do [[ "$p" =~ $re ]] && { hit=0; break; }; done
    [[ $hit == 1 ]] && printf '%s\t%s\n' "$p" "carrier"
  done
}

# ---------- commands ----------
cmd_pair()    { [[ $# -ge 1 ]] || die "usage: tuneup.sh pair <pairing-port>"; "$ADB" pair "127.0.0.1:$1"; }
cmd_connect() { [[ $# -ge 1 ]] || die "usage: tuneup.sh connect <port>"; "$ADB" connect "127.0.0.1:$1"; "$ADB" get-state; }
cmd_status()  { "$ADB" devices -l; "$ADB" get-state 2>/dev/null || true; }

cmd_snapshot() {
  need_device
  local ts dir; ts=$(date +%Y%m%d-%H%M%S); dir="$BACKUP/$ts"; mkdir -p "$dir"
  ash getprop                                   > "$dir/getprop.txt"
  ash pm list packages -f --user "$USER_ID"     > "$dir/packages-all.txt"
  ash pm list packages -s --user "$USER_ID"     > "$dir/packages-system.txt"
  ash pm list packages -3 --user "$USER_ID"     > "$dir/packages-user.txt"
  ash pm list packages -d --user "$USER_ID"     > "$dir/packages-disabled.txt"
  ash pm list packages -u --user "$USER_ID"     > "$dir/packages-including-uninstalled.txt"
  for ns in global system secure; do ash settings list "$ns" > "$dir/settings-$ns.txt"; done
  ash dumpsys notification --noredact           > "$dir/dumpsys-notification.txt"
  ash dumpsys package                           > "$dir/dumpsys-package.txt"
  ash cmd appops get --user "$USER_ID" com.android.shell >/dev/null 2>&1 || true
  ln -sfn "$dir" "$BACKUP/latest"
  ok "snapshot saved: $dir  ($(wc -l < "$dir/packages-all.txt") packages, $(wc -l < "$dir/packages-user.txt") user-installed)"
}

notif_counts() {  # ranked notification senders from the live notification service (active + archive)
  ash dumpsys notification --noredact | grep -oE 'pkg=[A-Za-z0-9._]+' | sed 's/^pkg=//' \
    | sort | uniq -c | sort -rn
}
notif_granted() {  # $1 pkg -> prints granted|revoked|unknown
  local out; out=$(ash dumpsys package "$1" | grep -A0 'android.permission.POST_NOTIFICATIONS' | head -1)
  case "$out" in *granted=true*) echo granted;; *granted=false*) echo revoked;; *) echo unknown;; esac
}

cmd_notif_audit() {
  need_device; load_protected
  log "Notification senders seen by the system (count = records in the live service + archive), most frequent first:"
  printf '%6s  %-9s  %-5s  %s\n' COUNT PERM PROT PACKAGE
  notif_counts | head -40 | while read -r n p; do
    local prot="-"; is_protected "$p" && prot="yes"
    printf '%6s  %-9s  %-5s  %s\n' "$n" "$(notif_granted "$p")" "$prot" "$p"
  done
  log ""
  log "Enabled notification listeners (apps that READ all your notifications):"
  ash settings get secure enabled_notification_listeners | tr ':' '\n' | sed 's#/.*##; s/^/   /' | grep -v '^   null$' | head -20
  log ""
  log "Mute a package:   ./tuneup.sh notif-mute <pkg>      Mute the known promo senders:   ./tuneup.sh notif-mute --preset"
}

mute_one() {  # $1 pkg $2 allow|ignore
  local p="$1" mode="$2" r1 r2
  if [[ "$mode" == ignore ]]; then
    r1=$(ash pm revoke --user "$USER_ID" "$p" android.permission.POST_NOTIFICATIONS)
    r2=$(ash cmd appops set --user "$USER_ID" "$p" POST_NOTIFICATION ignore)
  else
    r1=$(ash pm grant --user "$USER_ID" "$p" android.permission.POST_NOTIFICATIONS)
    r2=$(ash cmd appops set --user "$USER_ID" "$p" POST_NOTIFICATION allow)
  fi
  [[ -z "$r1$r2" || "$r1$r2" == *Success* ]] && return 0
  printf '%s' "$r1 $r2" | tr -s ' ' | head -c 120
  return 1
}
cmd_notif_mute() {
  need_device; load_protected; load_packages; mkdir -p "$BACKUP"
  local -a targets=(); local tok cmt
  if [[ "${1:-}" == "--preset" ]]; then
    while IFS=$'\t' read -r tok cmt; do [[ -n "${ALL[$tok]:-}" ]] && targets+=("$tok"); done < <(read_list "$LISTS/notify-mute.txt")
  else
    [[ $# -ge 1 ]] || die "usage: tuneup.sh notif-mute --preset | <pkg>..."
    targets=("$@")
  fi
  local p n=0
  for p in "${targets[@]}"; do
    [[ -n "${ALL[$p]:-}" ]] || { warn "not installed: $p"; continue; }
    is_protected "$p" && { warn "refusing to mute protected app: $p"; continue; }
    if err=$(mute_one "$p" ignore); then ok "muted  $p"; echo "$p" >> "$BACKUP/notif-muted.txt"; n=$((n+1))
    else warn "could not mute $p: $err"; fi
  done
  sort -u "$BACKUP/notif-muted.txt" -o "$BACKUP/notif-muted.txt" 2>/dev/null || true
  log "$n package(s) muted. Undo: ./tuneup.sh notif-unmute --all"
}
cmd_notif_unmute() {
  need_device; load_packages
  local -a targets=()
  if [[ "${1:-}" == "--all" ]]; then
    [[ -f "$BACKUP/notif-muted.txt" ]] || die "nothing recorded in $BACKUP/notif-muted.txt"
    mapfile -t targets < "$BACKUP/notif-muted.txt"
  else [[ $# -ge 1 ]] || die "usage: tuneup.sh notif-unmute --all | <pkg>..."; targets=("$@"); fi
  local p
  for p in "${targets[@]}"; do
    [[ -n "${ALL[$p]:-}" ]] || { warn "not installed: $p"; continue; }
    if err=$(mute_one "$p" allow); then ok "unmuted $p"; sed -i "/^$p\$/d" "$BACKUP/notif-muted.txt" 2>/dev/null || true
    else warn "could not unmute $p: $err"; fi
  done
}

cmd_debloat() {
  while [[ $# -gt 0 ]]; do case "$1" in
    --apply) APPLY=1;; --with-optional) WITH_OPTIONAL=1;; --carrier) WITH_CARRIER=1;;
    --mode) MODE="$2"; shift;; --yes) YES=1;; *) die "unknown option $1";; esac; shift; done
  [[ "$MODE" == uninstall || "$MODE" == disable ]] || die "--mode must be uninstall or disable"
  need_device; load_protected; load_packages
  local -A plan=(); local -A why=(); local p c tier
  while IFS=$'\t' read -r p c; do plan["$p"]="safe"; why["$p"]="$c"; done < <(expand_against_system "$LISTS/debloat-safe.txt")
  if [[ $WITH_OPTIONAL == 1 ]]; then
    while IFS=$'\t' read -r p c; do [[ -z "${plan[$p]:-}" ]] && { plan["$p"]="optional"; why["$p"]="$c"; }; done < <(expand_against_system "$LISTS/debloat-optional.txt")
  fi
  if [[ $WITH_CARRIER == 1 ]]; then
    while IFS=$'\t' read -r p c; do [[ -z "${plan[$p]:-}" ]] && { plan["$p"]="carrier"; why["$p"]="$c"; }; done < <(expand_carrier)
  fi
  local -a skipped=() todo=()
  for p in "${!plan[@]}"; do
    if is_protected "$p"; then skipped+=("$p"); else todo+=("$p"); fi
  done
  if [[ ${#todo[@]} -gt 0 ]]; then IFS=$'\n' todo=($(printf '%s\n' "${todo[@]}" | sort)); unset IFS; fi
  log "${c_dim}system packages installed: ${#SYS[@]}   user-installed (never touched): $(( ${#ALL[@]} - ${#SYS[@]} ))${c_off}"
  log "Plan (${#todo[@]} packages, mode=$MODE, user=$USER_ID):"
  for p in "${todo[@]}"; do printf '  %-8s %-48s %s\n' "${plan[$p]}" "$p" "${c_dim}${why[$p]}${c_off}"; done
  [[ ${#skipped[@]} -gt 0 ]] && { warn "listed but PROTECTED, skipped: ${skipped[*]}"; }
  [[ ${#todo[@]} -gt 0 ]] || { ok "nothing to do"; return 0; }
  if [[ $APPLY != 1 ]]; then log ""; log "Dry run. Add --apply to do it (a snapshot is taken first). Undo later with: ./tuneup.sh restore --all"; return 0; fi
  if [[ $YES != 1 ]]; then read -r -p "Remove these ${#todo[@]} packages for user $USER_ID? [y/N] " a; [[ "$a" == y || "$a" == Y ]] || die "aborted"; fi
  cmd_snapshot
  local ts logf r n_ok=0 n_fail=0; ts=$(date +%Y%m%d-%H%M%S); logf="$BACKUP/debloat-$ts.log"
  for p in "${todo[@]}"; do
    if [[ "$MODE" == uninstall ]]; then r=$(ash pm uninstall -k --user "$USER_ID" "$p"); else r=$(ash pm disable-user --user "$USER_ID" "$p"); fi
    if [[ "$r" == *Success* || "$r" == *"new state: disabled"* ]]; then
      ok "removed $p"; printf '%s\t%s\t%s\n' "$p" "$MODE" "$ts" >> "$BACKUP/removed.tsv"; n_ok=$((n_ok+1))
    else
      warn "failed  $p: ${r:-no output}"; n_fail=$((n_fail+1))
    fi
    printf '%s\t%s\t%s\n' "$p" "$MODE" "${r:-?}" >> "$logf"
  done
  log ""; ok "$n_ok removed, $n_fail failed. Log: $logf   Manifest: $BACKUP/removed.tsv"
  log "Reboot the phone when you're done. Undo anything: ./tuneup.sh restore --all   or   ./tuneup.sh restore <pkg>"
}

cmd_restore() {
  need_device
  local -a targets=(); local p mode ts r
  if [[ "${1:-}" == "--all" ]]; then
    [[ -f "$BACKUP/removed.tsv" ]] || die "no manifest at $BACKUP/removed.tsv"
    mapfile -t targets < <(cut -f1 "$BACKUP/removed.tsv" | sort -u)
  else [[ $# -ge 1 ]] || die "usage: tuneup.sh restore --all | <pkg>..."; targets=("$@"); fi
  for p in "${targets[@]}"; do
    mode=$(awk -F'\t' -v p="$p" '$1==p{m=$2} END{print m}' "$BACKUP/removed.tsv" 2>/dev/null); mode=${mode:-uninstall}
    if [[ "$mode" == disable ]]; then r=$(ash pm enable --user "$USER_ID" "$p"); else r=$(ash cmd package install-existing --user "$USER_ID" "$p"); fi
    if [[ "$r" == *installed* || "$r" == *Success* || "$r" == *enabled* ]]; then ok "restored $p"; sed -i "/^$p\t/d" "$BACKUP/removed.tsv" 2>/dev/null || true
    else warn "could not restore $p: ${r:-no output}"; fi
  done
}

cmd_report() {
  need_device; load_protected
  local model rel oneui up
  model=$(ash getprop ro.product.model); rel=$(ash getprop ro.build.version.release); oneui=$(ash getprop ro.build.version.oneui)
  log "== $model  Android $rel  One UI build ${oneui:-?}  firmware $(ash getprop ro.build.display.id)"
  log "== uptime: $(ash uptime -p 2>/dev/null || ash cat /proc/uptime | awk '{printf "%.1f h", $1/3600}')"
  log "== storage (/data):"; ash df -h /data | sed 's/^/   /'
  log "== memory:"; ash cat /proc/meminfo | grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree)' | sed 's/^/   /'
  log "== top CPU right now:"; ash top -b -n 1 -m 12 -s 3 2>/dev/null | tail -n +4 | sed 's/^/   /'
  log "== packages: $(ash pm list packages --user "$USER_ID" | wc -l) total, $(ash pm list packages -3 --user "$USER_ID" | wc -l) user-installed, $(ash pm list packages -d --user "$USER_ID" | wc -l) disabled"
  log "== animation scales (1.0 = stock): window=$(ash settings get global window_animation_scale) transition=$(ash settings get global transition_animation_scale) animator=$(ash settings get global animator_duration_scale)"
  log "== top notification senders:"; notif_counts | head -12 | sed 's/^/   /'
  log "== apps with battery optimization disabled (allowed to run wild in background):"
  ash dumpsys deviceidle whitelist 2>/dev/null | grep -v '^system' | sed 's/^/   /' | head -25
}

cmd_speed() {
  [[ "${1:-}" == "--apply" ]] && APPLY=1
  need_device; load_protected; load_packages
  log "Will:"
  log "  1. animations 1.0 -> 0.5 (window/transition/animator). Biggest felt difference, zero risk."
  log "  2. pm trim-caches: drop every app's cache files (not data). Frees storage, apps rebuild caches."
  log "  3. cmd package bg-dexopt-job: recompile apps now instead of waiting for an idle night."
  log "  4. RUN_ANY_IN_BACKGROUND=ignore for noisy preloads you kept (optional list that is still installed)."
  [[ $APPLY == 1 ]] || { log ""; log "Dry run. Add --apply."; return 0; }
  for k in window_animation_scale transition_animation_scale animator_duration_scale; do ash settings put global "$k" 0.5; done; ok "animations 0.5x"
  ash pm trim-caches 512G >/dev/null; ok "caches trimmed: $(ash df -h /data | awk 'NR==2{print $4" free"}')"
  log "running bg-dexopt-job (can take a few minutes, phone may warm up)..."; ash cmd package bg-dexopt-job >/dev/null; ok "dexopt done"
  local p c n=0
  while IFS=$'\t' read -r p c; do
    is_protected "$p" && continue
    ash cmd appops set --user "$USER_ID" "$p" RUN_ANY_IN_BACKGROUND ignore >/dev/null && { echo "$p" >> "$BACKUP/bg-restricted.txt"; n=$((n+1)); }
  done < <(expand_against_system "$LISTS/debloat-optional.txt")
  ok "$n kept preloads restricted from running in background (undo: cmd appops set <pkg> RUN_ANY_IN_BACKGROUND allow)"
}

cmd_all() {
  local -a extra=(); while [[ $# -gt 0 ]]; do case "$1" in --yes) YES=1;; --with-optional|--carrier) extra+=("$1");; *) die "unknown option $1";; esac; shift; done
  need_device
  cmd_snapshot; log ""; cmd_report; log ""
  cmd_debloat --apply "${extra[@]}" $( [[ $YES == 1 ]] && echo --yes ); log ""
  cmd_notif_mute --preset; log ""
  cmd_speed --apply; log ""
  cmd_report
  log ""; ok "done. Reboot the phone. Everything is logged under $BACKUP and reversible with restore / notif-unmute."
}

main() {
  local cmd="${1:-}"; shift || true
  mkdir -p "$BACKUP"
  case "$cmd" in
    pair) cmd_pair "$@";; connect) cmd_connect "$@";; status) cmd_status;;
    snapshot) cmd_snapshot;; report) cmd_report;;
    notif-audit) cmd_notif_audit;; notif-mute) cmd_notif_mute "$@";; notif-unmute) cmd_notif_unmute "$@";;
    debloat) cmd_debloat "$@";; restore) cmd_restore "$@";; speed) cmd_speed "$@";; all) cmd_all "$@";;
    ""|-h|--help|help) usage;;
    *) usage; die "unknown command: $cmd";;
  esac
}
main "$@"
