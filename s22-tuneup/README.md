# s22-tuneup

Debloat, de-notify and speed up a Samsung Galaxy (built for an S22 Ultra, works on any One UI phone)
**from Termux on the phone itself**, no PC and no root. Everything is reversible.

How it works: Android's *Wireless debugging* lets the phone talk ADB to itself over `127.0.0.1`.
Through that channel the shell user may uninstall preinstalled apps for your user profile,
revoke notification permissions, and change animation settings. Same mechanism as
Universal Android Debloater / LADB / Shizuku, just scripted and logged.

## What it will never touch

* **Anything you installed yourself.** Debloat only considers packages that came with the firmware
  (`pm list packages -s`). Your authenticators, password managers, banking apps and their data are
  structurally out of scope, and additionally pinned in `lists/protected.txt` so even `notif-mute`
  refuses them.
* The One UI pieces that other things depend on (launcher, keyboard, Gallery, My Files, camera filter
  provider, S Pen services, Samsung account / Pass / Wallet / auth framework, Play Services, Play Store,
  phone/SMS/contacts, Modes & Routines, carrier voicemail, software update).

## Quick start (on the phone, in Termux)

Termux must be the F-Droid or GitHub build; the Play Store one is abandoned and `pkg` won't work.

```bash
pkg install -y git
git clone https://github.com/chchchadzilla/k && cd k/s22-tuneup
bash setup-termux.sh            # installs adb; add --with-claude to also install Claude Code
```

Phone side, once:

1. Settings > About phone > Software information > tap **Build number** 7 times.
2. Settings > Developer options > **Wireless debugging** on (needs Wi-Fi).
3. Put Settings and Termux in split screen (Recents > tap the app icon > *Open in split screen view*).
4. Wireless debugging > **Pair device with pairing code** → in Termux `./tuneup.sh pair <pairing port>` and type the code.
5. Back on the Wireless debugging screen read **IP address & port** → `./tuneup.sh connect <port>`.

The pairing port and the connect port are different numbers. Keep Termux in the foreground
(or run `termux-wake-lock`) while it works, or Android may kill it mid-run.

Then:

```bash
./tuneup.sh report            # what the phone looks like right now, incl. who spams notifications
./tuneup.sh debloat           # DRY RUN: shows exactly what would go and why
./tuneup.sh all               # snapshot -> debloat (asks y/N) -> mute promo notifications -> speed -> report
```

Reboot afterwards. If anything feels off: `./tuneup.sh restore --all` and `./tuneup.sh notif-unmute --all`.

## Commands

| command | what it does |
|---|---|
| `snapshot` | saves package lists, all `settings`, notification state and `dumpsys package` to `~/s22-tuneup-backups/<timestamp>` (runs automatically before any change) |
| `report` | model/firmware, storage, RAM, top CPU, package counts, animation scales, noisiest notification senders, apps exempt from battery optimization |
| `notif-audit` | ranks every package that has posted a notification recently (from the system's own notification archive), shows whether its permission is granted and whether it is protected, plus which apps are *reading* all your notifications |
| `notif-mute --preset` | revokes `POST_NOTIFICATIONS` for the promo/nag system apps in `lists/notify-mute.txt` (Galaxy Store, Samsung Members, Samsung Free, Themes, Tips, Game Launcher, Samsung Push, Play Store nags, YouTube/Music recommendations…). `notif-mute <pkg>…` for anything the audit shows you. Protected apps are refused. |
| `notif-unmute --all` / `<pkg>` | puts the permission back |
| `debloat` | dry run of Tier 1 (`lists/debloat-safe.txt`): Bixby, Samsung Free, Members, Themes, Tips, AR Zone/Emoji, Game Launcher, Kids, Smart Switch, Meta/Microsoft/Google preload stubs, Link to Windows, Meet, YouTube Music… |
| `debloat --apply` | does it (`pm uninstall -k --user 0`, data kept, restorable). `--with-optional` adds `lists/debloat-optional.txt` (Galaxy Wearable, edge panels, Samsung Internet/Email, preloaded Facebook/Netflix/Spotify/LinkedIn/Outlook…: read the list first). `--carrier` adds carrier bloat matched by `lists/carrier-patterns.txt`, voicemail excluded. `--mode disable` uses `pm disable-user` instead. |
| `restore --all` / `<pkg>` | `cmd package install-existing` (or `pm enable`) from the manifest `~/s22-tuneup-backups/removed.tsv` |
| `unused [--days N]` | apps **you** installed, ranked by last use from the system's usage stats, with app and data size in MB. Default: not opened in 60 days. The biggest lever on a phone with hundreds of user apps. |
| `remove-user-apps <pkg>…` | real uninstall of apps you installed (their data goes, same as uninstalling from the launcher). Asks per package, refuses protected apps and firmware packages. |
| `speed --apply` | animation scales 1.0 → 0.5, `pm trim-caches` (cache only, no data), run background dexopt now, and set `RUN_ANY_IN_BACKGROUND=ignore` on kept preloads |

## RAM Plus

If `report` shows gigabytes of swap in use minutes after a reboot, One UI is compressing memory because too much is
resident. Settings > Device care > Memory > **RAM Plus**: set it off (or the smallest value) and reboot. On a 12 GB
phone that trades a little multitasking headroom for noticeably less stutter.

## The notification problem specifically

Debloating removes the senders you don't need; `notif-mute` silences the ones that must stay installed.
That handles the promo noise. For the rest, the two One UI settings that make the biggest difference:

* **Settings > Notifications > App notifications**: sort by *Most recent*; for anything chatty but not
  urgent, open it and turn off *Sound* per channel instead of the whole app, so it still lands in the shade.
* **Modes and Routines**: a *Work* or *Sleep* mode with a short allow-list (calls from favorites, SMS, your
  authenticator, your bank) is what actually makes the phone quiet enough that a buzz means something.
  Then Settings > Notifications > Advanced settings > *Notification history* on, so nothing is lost.

## Claude Code in Termux (why `claude rc` said "No command claude found")

Claude Code isn't installed in Termux by default and Anthropic ships no Android build: the native
installer downloads a glibc binary that cannot run on Android's bionic libc. The community route is the
npm package run through Termux's Node:

```bash
bash setup-termux.sh --with-claude     # nodejs-lts + npm i -g @anthropic-ai/claude-code + alias + TMPDIR fix
source ~/.bashrc
termux-wake-lock                       # keep the process alive while you use it from the Claude app
claude                                 # /login (claude.ai account, Pro/Max/Team), then /rc
```

Remote Control needs the `claude` process to stay running, a claude.ai login (API keys don't work),
and no `ANTHROPIC_BASE_URL`/`DISABLE_GROWTHBOOK` in the environment. On a phone the practical way is
Termux in split screen with the Claude app, or `claude remote-control` in a `tmux` session. Even with
Remote Control working, system changes still go through the ADB bridge above, which is why this
toolkit exists either way.

## Tests

`test/run.sh` drives every command against `test/fake-adb` (a recorded-command ADB shim with an S22-ish
package set) and fails if any uninstall/revoke ever names a protected or user-installed package.
