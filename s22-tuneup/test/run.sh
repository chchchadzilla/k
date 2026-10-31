#!/usr/bin/env bash
# Offline regression test: drives tuneup.sh against test/fake-adb and asserts protected apps are never touched.
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ADB="$D/fake-adb" TUNEUP_BACKUP="$(mktemp -d)" FAKE_ADB_STATE="$(mktemp -d)" FAKE_ADB_LOG="$(mktemp)"
T="$D/../tuneup.sh"
"$T" debloat --with-optional --carrier >/dev/null
"$T" debloat --apply --yes >/dev/null
"$T" notif-mute --preset >/dev/null
"$T" notif-mute com.azure.authenticator com.chase.sig.android >/dev/null || true
"$T" speed --apply >/dev/null
"$T" report >/dev/null
"$T" restore --all >/dev/null
"$T" notif-unmute --all >/dev/null
if grep -E "uninstall|revoke|disable-user|appops set" "$FAKE_ADB_LOG" | grep -qE "authenticator|bitwarden|chase|samsungpass|spay|authfw|app\.launcher|termux|com\.android\.vending|gms |apps\.messaging|vvm|pr\.adapt|aircommand|routines"; then
  echo "FAIL: a protected package was touched:"; grep -E "uninstall|revoke|disable-user|appops set" "$FAKE_ADB_LOG" | grep -E "authenticator|bitwarden|chase|samsungpass|spay|authfw|app\.launcher|termux|vending|gms |apps\.messaging|vvm|pr\.adapt|aircommand|routines"; exit 1
fi
grep -q "pm uninstall -k --user 0 com.samsung.android.voc" "$FAKE_ADB_LOG" || { echo "FAIL: expected removal of Samsung Members"; exit 1; }
grep -q "install-existing --user 0 com.samsung.android.voc" "$FAKE_ADB_LOG" || { echo "FAIL: expected restore"; exit 1; }
[[ ! -s "$TUNEUP_BACKUP/removed.tsv" ]] || { echo "FAIL: manifest not emptied after restore --all"; cat "$TUNEUP_BACKUP/removed.tsv"; exit 1; }
echo "PASS"
