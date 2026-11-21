# Plan: copy the lock look to the SDDM login screen

Status: draft 4 (2026-11-20). Steps 1 and 2 are done; step 2 is on `dev`
(`5840ebe`). Step 3 (the greeter bundle) is being built; see "Step 3
contract". Calling `pkexec` from Studio's own process is checked in step 5.
The user accepted every recommendation under "Decisions".

## Goal

Lock Studio gets a **Copy to login screen** button. It copies the current
lock look to the SDDM greeter and leaves out the parts SDDM can't show. The
plugin stays an ordinary user plugin. Only the copy step runs as root, and
only after a dialog and a password prompt.

## Facts (checked on Omarchy 4.5.0, SDDM 0.21.0)

- **Plugins have no root step.** `omarchy plugin add` clones, validates the
  manifest and rescans. There is no install hook.
- **The SDDM theme is system-owned.** `/usr/share/sddm/themes/omarchy/`
  belongs to the `omarchy-settings` package and is owned by root.
  `/etc/sddm.conf.d/10-theme.conf` selects it with `[Theme] Current=omarchy`.
- **Omarchy themes it with sudo.** `omarchy-plymouth-set` runs a fixed
  `sudo /bin/bash -c` transaction. It builds the files in a root-owned
  staging folder, checks every directory, and replaces each file in one step.
  It only changes the colours and logo in its own `Main.qml`.
- **The greeter is a different runtime.** It runs as the `sddm` user
  (`sddm-greeter-qt6`, Qt 6) with `SddmComponents`: `sddm.login()`,
  `userModel`, `sessionModel`. It has no Quickshell, no Omarchy services, no
  MPRIS and no `omarchy-lock-password` PAM service.
- **The greeter can't read the home folder.** `/home/tomas` is `700`.
- **Most elements are portable.** The element files import only `QtQuick`,
  `QtQuick.Effects` and `../kit`. `Layout.js` is pure. `Backdrop.qml` and
  `PasswordElement.qml` import `qs.Commons` for colours, and `FoamyStyle`,
  `FoamyPalette` and `FoamyI18n` import `qs.Commons`. `LockView.qml` uses
  Quickshell PAM, UPower, networking and file reading.
- **The fonts are system-wide here:** Adwaita Sans, URW Gothic and
  JetBrainsMono Nerd Font. `QtQuick.Effects` is installed.
- **Autologin is on** (`/etc/sddm.conf.d/autologin.conf`). The greeter shows
  only after logging out.
- **Omarchy's installer can select the theme in a `99-` drop-in.** On
  miriam-pc (an Omarchy 4.5 ISO install, 2026-09-05) the installer wrote
  `/etc/sddm.conf.d/99-omarchy-login.conf` with `[Theme] Current=omarchy`
  as well as `[Users]`. No package owns it. On this PC the same file has
  only `[Users]`. A drop-in that should win must sort after it.
- **An admin can move SDDM's theme folder.** miriam-pc had
  `99-z-miriam-login.conf` with `Current=miriam-lock` and
  `ThemeDir=/usr/local/share/sddm/themes`. SDDM then looks for every theme
  there. (That file is now `/etc/sddm-99-z-miriam-login.conf.bak`, so
  miriam-pc runs Omarchy's setup for testing.)
- **The polkit agent is Omarchy's shell.** The `omarchy.polkit` service
  plugin (Quickshell's `PolkitAgent`) runs inside `omarchy-shell` and draws
  the password prompt. It replaced `polkit-gnome-authentication-agent-1`.
  `/usr/bin/pkexec` exists. If a user disables `omarchy.polkit`, `pkexec`
  has no agent in the session.

## Spike results (2026-11-20)

Prototype in the session scratchpad, `sddm-spike/`. No repo file was
changed. It ran with `sddm-greeter-qt6 --test-mode --theme <dir>`: once
offscreen (software rendering) and once as a Wayland window on the desktop
(GPU). The theme held copies of `ClockElement`, `DateElement`,
`PasswordElement`, `Backdrop` with the shaders, and stand-ins for the view,
the kit and `qs.Commons`.

1. **`import qs.Commons` doesn't resolve** from the theme folder ("module
   is not installed"). A relative folder import (`import "../qs/Commons"`)
   with its own `qmldir` works, singletons included.
   **Decision:** `Backdrop.qml` and `PasswordElement.qml` take their four
   theme colours from `view`. `LockView` passes them from `Commons`, so the
   lock is unchanged. The greeter's own `kit/` holds greeter versions of
   `FoamyStyle`, `FoamyPalette`, `FoamyI18n` and `FoamyClipboard`. The real
   `FoamyStyle` also needs `Border.flat()` from `Commons`, so it is replaced
   too. Nothing is rewritten at build time.
2. **Shaders and effects work.** As a Wayland window the greeter renders
   with OpenGL. The `aurora` shader loaded and drew. `MultiEffect` blur and
   shadow drew correctly. Offscreen, the software renderer drew the still
   frame. Not yet checked: the real greeter inside SDDM's own Hyprland as
   the `sddm` user (step 6).
3. **Reading `snapshot.json` with `XMLHttpRequest` is blocked.** Qt needs
   `QML_XHR_ALLOW_FILE_READ=1`, which a theme can't set.
   **Decision:** the snapshot goes in `theme.conf` as one quoted JSON value
   (`snapshot="{\"preset\":…}"`). The greeter reads it as `config.snapshot`.
   Commas, quotes and non-ASCII text ("Ø") came through unchanged. No
   base64 is needed (`Qt.atob` is deprecated). The publisher writes this
   line from JSON that `jq` has checked, and removes any
   `theme.conf.user`, which SDDM would read over `theme.conf`.
4. **Config order:** `man sddm.conf` says SDDM reads
   `/usr/lib/sddm/sddm.conf.d`, then `/etc/sddm.conf.d`, then
   `/etc/sddm.conf`, with the last one winning. `/etc/sddm.conf` doesn't
   exist here. Our drop-in is `99-zz-foamy-lock.conf` (Decision 4).
   `status` computes the effective `[Theme] Current` in that order and
   reports `overridden` when `/etc/sddm.conf` or a later drop-in sets a
   different theme.
5. **`pkexec`:** `man pkexec` gives exit 126 when the prompt is dismissed
   and 127 when authorization fails or an error occurs. Otherwise it
   returns the program's exit code. The publisher's own failures must
   therefore use codes other than 126 and 127.
   **Live check (user-approved, from a session shell, not yet from
   Studio's own process):** the `omarchy.polkit` prompt appeared each time.
   Closing it gave 126 ("Request dismissed"). A wrong password made the
   prompt ask again, and closing it then also gave 126; a wrong password
   alone doesn't end `pkexec`. The right password ran the program:
   `/usr/bin/true` gave 0 and `/usr/bin/false` gave 1. Authorization isn't
   kept between runs, so every `pkexec` call asks again: copy and restore
   must each be one `pkexec` call.
   Studio's results map 126 to "cancelled", 127 to "permission not
   granted" (also the result when no polkit agent runs), and the
   publisher's own codes to their reasons.

Other findings:

- **A theme that fails to load falls back to SDDM's built-in theme**
  ("Fallback to embedded theme"), so a broken import still leaves a login
  screen. A theme that loads but breaks at runtime has no such fallback.
  That makes the login path the most important end-to-end check.
- In test mode `userModel.lastUser` is empty and `sddm.login()` reaches no
  daemon. Login can only be tested in the real greeter (step 6).
- All three fonts resolve in the greeter process.
- With the stand-in view, the password field showed "Fingerprint reader
  unavailable". The greeter view sets `fingerprintConfigured` and
  `fingerprintUnavailable` so the element shows no fingerprint text.

## Omarchy's "Unlock" menu entry ("Lås opp")

Appearance → Unlock (`appearance.unlock` in
`default/omarchy/omarchy-menu.jsonc`) is not an SDDM theme switcher.

- `omarchy-plymouth-switcher` lists every Omarchy theme that has a
  `preview-unlock.png`, plus "default".
- Picking a theme runs `omarchy-plymouth-set-by-theme`. It takes the theme's
  `unlock.png` and its `colors.toml` background and foreground, and writes
  them to the Plymouth boot screen (the disk unlock screen) and to the
  colours and logo of the `omarchy` SDDM theme.
- "default" runs `omarchy-plymouth-reset`, which runs
  `omarchy-refresh-plymouth` and `omarchy-refresh-sddm`.
- It never changes `[Theme] Current`. It always styles the `omarchy` theme.

**Foamy Lock should not be in that list.** The list is built from theme
folders, so the only way in is a fake theme in `~/.config/omarchy/themes/`,
which would also show up in the theme switcher. The list also stands for a
boot-screen style, which Foamy Lock doesn't provide.

How the two work together once Foamy's theme is selected:

- Picking a theme in Unlock still changes the Plymouth boot screen.
- Its SDDM change goes to the `omarchy` theme, which is no longer shown, so
  it has no visible effect on the login screen.
- "default" refreshes the `omarchy` theme files and doesn't remove Foamy's
  drop-in. The login screen stays Foamy's.
- The README says this. Studio's login-screen section names the active
  theme, so the result is never hidden.

A separate menu entry is possible through the user's
`~/.config/omarchy/extensions/omarchy-menu.jsonc` (with a `when:` guard).
That file is the user's config, so the plugin doesn't write to it. The README
can show an optional snippet that opens Studio on the login-screen section.
See open decision 3.

## What is copied

The snapshot is plain data made at copy time. It is not live.

| Setting or element | On the login screen |
| --- | --- |
| `preset`, `layout` (zone, style, order, hidden, scale, opacity, offset, align, glass) | Yes. `screens` is dropped: the greeter's output names can differ. |
| `glass` | Yes |
| `timeFormat` | Yes |
| Date, clock, calendar | Yes |
| Password field | Yes, through `sddm.login()` |
| Account | Name and avatar, copied. See "Account" below. |
| `showUserInfo` | Yes |
| Theme colours (`Commons.Color`, `[lock]` colours) | Resolved and copied as hex values |
| Language | Copied as the language code at copy time |
| Background: theme colour, picture or wallpaper | Yes. The picture is copied, scaled down by the helper. |
| Background: animated shader presets | Yes, if the spike shows shaders work in the greeter |
| Background: video | No (open decision 2) |
| Media, artwork | No: there is no user session or MPRIS |
| Weather | No: it comes from Foamy Weather in the user session |
| Status: network, Bluetooth, volume, battery | No: there are no Quickshell services. `/sys` can't be read from greeter QML by default. |
| `system` panel | No: `/proc` can't be read from greeter QML by default |
| Fingerprint | No: SDDM gives no feedback on fingerprint progress |
| `blankAfterSec` | No: SDDM and the greeter compositor handle the display |
| `artworkHosts`, `artworkFileRoots`, `showBrowserMedia`, `showArtwork` | Never copied |

A left-out element is written as `hidden: true`, and `Layout.js` lays out
the rest as it does on the lock.

**Account.** Omarchy's greeter logs in as `userModel.lastUser`. Foamy's does
the same. It shows the copied name and avatar only when `lastUser` is the
user who copied. Otherwise it shows the name from `userModel` and the
initial. On a machine with several users, the login screen never shows one
user's picture over another user's login.

**Privacy.** The copied wallpaper, avatar and name are shown to anyone at
the login screen, and every local user can read them in `/usr/share`. The
dialog says so.

## Studio: the login-screen section

**When it is shown.** The helper's new `studio login-screen status` decides.
The section is hidden unless all of these hold:

- `/etc/systemd/system/display-manager.service` resolves to `sddm.service`;
- `sddm.service` is enabled;
- `/usr/bin/sddm-greeter-qt6` exists.

A failed check is "SDDM is not in use", and the section is hidden. A status
command that fails or times out is an error. Studio shows it in the section
and doesn't hide the section.

**States** (reported by `status`):

| State | Studio shows |
| --- | --- |
| `unavailable` | Nothing (section hidden) |
| `not-installed` | **Copy to login screen** |
| `current` | "The login screen matches this look." **Copy to login screen** (disabled) and **Restore Omarchy login screen** |
| `outdated` | "The login screen shows an older look." **Copy to login screen** and **Restore Omarchy login screen** |
| `overridden` | "Foamy Lock's login theme is installed, but SDDM uses `<theme>`." Both buttons |
| `broken` | "The login theme files are incomplete." Both buttons |

`current` and `outdated` compare a hash of the snapshot Studio would write
with the hash stored next to the installed copy. A newer plugin version also
counts as `outdated`, because the greeter code has changed.

`overridden` means the effective `[Theme] Current`, computed from SDDM's
config files in the order SDDM reads them, isn't `foamy-lock`. The spike
confirms that order.

**The dialog.** It uses Studio's existing question dialog
(`StudioWindow.qml`, `Accessible.role: Accessible.Dialog`). Draft text:

> **Copy to login screen**
>
> This copies the current lock look to the login screen (SDDM). The login
> screen is shown when the computer starts and after you log out.
>
> It will:
> - install or update Foamy Lock's login theme in
>   `/usr/share/sddm/themes/foamy-lock`
> - copy the layout, colours, background picture, your name and your
>   profile picture there. Anyone at this computer can see them on the login
>   screen.
> - select the theme in `/etc/sddm.conf.d/99-zz-foamy-lock.conf`
>
> *(Only when SDDM uses another theme:)* This replaces the login theme
> `<theme>`, set in `<file>`. Restoring brings it back.
>
> Not shown on the login screen: media, weather, fingerprint, network and
> battery status, the system panel and video backgrounds.
>
> This needs administrator (root) permission. You will be asked for your
> password.
>
> *(Only with autologin on:)* Autologin is on, so you see the login screen
> only after you log out.
>
> [Cancel] [Copy to login screen]

The list of left-out items is computed from the current look, so it names
only what this look actually uses.

**Restore Omarchy login screen** gets its own dialog with the same
structure: it removes `/etc/sddm.conf.d/99-zz-foamy-lock.conf` and
`/usr/share/sddm/themes/foamy-lock`, and SDDM uses whatever the other
drop-ins select again (usually `omarchy`). Root permission, password
prompt.

**Results.** After the prompt, Studio shows one of: copied; cancelled (the
prompt was closed or the password was wrong, nothing changed); failed with
the reason (the previous login screen is kept). Studio reads `status` again
afterwards and never assumes success.

All new text goes through `FoamyI18n`, in `i18n/en.json` and `i18n/no.json`.

## Parts

1. **Greeter bundle**, in a new `sddm/` folder:
   - `Main.qml`: a small view on SDDM's API. It parses `config.snapshot`
     from `theme.conf` (spike result 3), lays out the elements with
     `Layout.js`, logs in with
     `sddm.login(lastUser, password, sessionIndex)`, picks the session the
     way Omarchy's theme does (the `uwsm` one) and handles
     `onLoginFailed`.
   - `metadata.desktop` with `QtVersion=6`.
   - A `kit/` folder with greeter versions of `FoamyStyle`, `FoamyPalette`,
     `FoamyI18n` and `FoamyClipboard` (same names and the properties the
     elements use), filled from the snapshot. The foamy-kit copies in the
     plugin's `kit/` stay unchanged.
   - The element files, `Layout.js` and the shaders, copied as they are.
   - Before that, `Backdrop.qml` and `PasswordElement.qml` stop importing
     `qs.Commons` and take their colours from `view` (spike result 1). The
     lock looks and behaves the same; the existing tests and a visual check
     of the lock confirm it.
2. **Helper**, new `studio login-screen` subcommands in
   `native/src/studio/login_screen/` (built in step 2; the module docs hold
   the exact contracts):
   - `status`: the checks and states above. It reports `installed` for a
     complete folder that SDDM uses. Studio turns that into "matches" or
     "out of date" by comparing `installed.hash` with `stage`'s hash. It
     reads every file in SDDM's config folders, whatever the suffix (a
     `.pacnew` too), as SDDM 0.21's `ConfigReader.cpp` does, in Qt's
     locale-aware order under the locale systemd gives the daemon
     (`/etc/locale.conf`). Under `nb_NO` that puts `_` before `-`, so
     `50_x.conf` comes before `50-foamy-lock.conf`. Locale rules such as
     Norwegian "aa" sorting as "å" aren't modelled.
   - `stage`: Studio sends the look the lock confirmed it applied, the
     resolved theme colours, the language, and the paths of the background
     and avatar the lock already prepared in its sandbox. The helper
     doesn't read `shell.json`, as it doesn't today. `stage` checks and
     filters them and writes `snapshot.json`, byte copies of the pictures
     and `manifest.json` into a new `0700` folder in `$XDG_RUNTIME_DIR`.
     Limits: each picture ≤ 25 MiB and ≤ 3840 × 2160, a fixed file list.
     The helper writes backgrounds as uncompressed PNGs, so 3840 × 2160 is
     24.9 MB. The lock may prepare larger ones for bigger screens; Studio
     asks the `background` kind for a copy capped at 3840 × 2160 for the
     login screen (step 5).
     The greeter bundle is added to the folder in step 3.
   - `manifest.json` (schema version 1) is the contract between `stage`,
     the publisher and `status`: `{"version": 1, "plugin", "hash", "files":
     [{"name", "size", "sha256"}]}`. `status` refuses unknown keys.
   - `stage` checks the look's shape, element names, sizes and that no
     user path is left, and nothing more. The values are `Layout.js`'s job,
     in the lock and again in the greeter. Studio sends `showsPicture`
     (computed with `Layout.js`, which knows each preset's default source).
   - For step 3: the greeter sets the background's `path` from
     `files.background` before `parseLook`, since a `picture` source needs
     one. The copied picture is already blurred, so the greeter must not
     apply the look's `blur` again.
   - For step 4: the publisher takes `stage.lock` (next to the `stage-*`
     folders) while it reads a staging folder, so a new `stage` can't
     remove the folder under it.
3. **Publisher**, `sddm/foamy-lock-login-screen` (not `bin/`, which holds
   only the verified helper binaries; not in `bundle.txt`), a bash script
   modelled on
   `omarchy-plymouth-set`:
   - It refuses to run as root, stages as the user, then runs a fixed
     privileged transaction through `pkexec`.
   - As root it sets a fixed `PATH` and `umask 077`, and treats the staging
     folder as untrusted. It accepts only regular files from the fixed
     list, no symlinks, sizes within the manifest limits, and checks
     `snapshot.json` with `jq` against the schema.
   - It copies into a root-owned staging folder, then replaces each file in
     `/usr/share/sddm/themes/foamy-lock` in one step and writes the drop-in
     last. On any failure, the previous theme and drop-in stay as they were.
   - `--restore` removes only the drop-in and the theme folder, after
     checking that they are Foamy's (the stored manifest matches).
   - Root never decodes images. The helper already re-encoded them in its
     sandbox.
   - The published folder is `0755` with `0644` files: the `sddm` user
     must read it, and `status` (as the user) reads the manifest and file
     sizes. With `umask 077` alone, `status` reports `IO`.
   - The drop-in `/etc/sddm.conf.d/99-zz-foamy-lock.conf` holds
     `[Theme]`, `Current=foamy-lock` and `ThemeDir=/usr/share/sddm/themes`
     (Decision 4).
4. **Studio:** the section, the two dialogs, the states and results.
5. **Docs:** a README section covering what is copied, the root step, the
   Unlock menu interplay, autologin, and how to restore.

## Step 3 contract

Two parts are built in parallel. These are the interfaces between them.

**Theme folder layout.** The installed theme mirrors the plugin's layout, so
the element files keep their relative imports (`../kit`, `shaders/…`):

- `Main.qml`, `metadata.desktop` and `kit/*` come from the plugin's `sddm/`
  folder (`sddm/Main.qml` → `Main.qml`, `sddm/kit/X` → `kit/X`);
- everything else keeps its plugin path (`Layout.js`,
  `elements/ClockElement.qml`, `elements/shaders/aurora.frag.qsb`, …);
- plus `snapshot.json`, `background.png`, `avatar.png`, `manifest.json`
  from `stage`, and `theme.conf`, which the publisher writes.

**`sddm/bundle.txt`** (owned by the greeter part) lists the plugin files
the theme needs, one plugin-relative path per line, mapped as above. Blank
lines and lines starting with `#` are skipped. `stage` copies exactly these
files into the staging folder and lists them in `manifest.json`.

**Manifest names** may contain `/`: a relative path of plain components
(`[A-Za-z0-9._-]`, not `.` or `..`, not starting with `.`), at most 4
levels, at most 255 entries. `status` checks each one without following a
symlink in any component.

**Snapshot additions:** `strings`, the plugin's translation catalog for the
snapshot's `language` (`i18n/<language>.json`, else the part before `-`,
else `{}`), copied as an object. The greeter's `FoamyI18n` reads it, falling
back to the English key.

**`theme.conf`:** `[General]` and one line
`snapshot="<snapshot.json's compact text>"`, in which each `\` becomes
`\\` and each `"` becomes `\"` (QSettings' quoted-string escapes). The
greeter reads `config.snapshot` and `JSON.parse`s it. The publisher (step 4)
writes it; the greeter part's test tooling writes it the same way.

**Greeter behaviour** (the greeter part):

- `Main.qml` builds a view with the members the elements read (as
  `LockView` does), runs `Layout.js` on the snapshot's look, and draws only
  date, clock, account, password, calendar and the background.
- Background: `picture` uses `background.png` (already blurred: no second
  blur), else the look's own source.
- Login: `sddm.login(userModel.lastUser, password, session)`, with the
  session picked as Omarchy's theme does (the `uwsm` one, else
  `sessionModel.lastIndex`); `loginFailed` shows the failure in the field.
- Account: the copied name and avatar only when `lastUser` equals the
  snapshot's `user`; otherwise `userModel`'s name for `lastUser` and the
  initial.
- No fingerprint text. Every screen draws the theme; only the primary
  screen's field takes the keys, like the lock.

## Steps 4 and 5 contract

**Publisher CLI** (step 4), run by Studio as the user:

- `sddm/foamy-lock-login-screen publish <staging-folder>`: `<staging-folder>`
  is a folder `stage` returned. It asks for root once through `pkexec`.
- `sddm/foamy-lock-login-screen restore`: removes our drop-in and theme
  folder through `pkexec`.
- stdout: one JSON line, `{"ok": true}` or `{"ok": false, "code": "<CODE>",
  "error": "<English>"}`, with exit 0 or 1. Its own exits are never 126 or
  127, which are `pkexec`'s: 126 the prompt was dismissed, 127 not
  authorized or no polkit agent (no JSON line then).
- As root, the files are read from the staging folder with the invoking
  user's rights (`setpriv` to `PKEXEC_UID`), so a symlink there can't make
  root read a file the user can't; root then checks each copy's size and
  SHA-256 against `manifest.json`.
- It replaces only a theme folder whose `manifest.json` is Foamy's, and only
  a drop-in with Foamy's marker line; anything else named the same is
  refused (`NOT_OURS`) and left alone.

**Studio** (step 5) runs `studio login-screen status` to show the section
and its state, `studio login-screen stage` with the applied look (with
`showsPicture` from `Layout.js`, the colours from `Commons`, the language,
the avatar the lock rendered and a background prepared by the `background`
kind at most 3840 × 2160), then the publisher with the returned folder, then
`status` again, and compares `installed.hash` with `stage`'s hash.

## Steps

1. **Spike** (scratchpad, no repo change). Build a bundle with the clock,
   date, password field and the `aurora` shader. Run it with
   `sddm-greeter-qt6 --test-mode --theme <dir>`. Answer:
   1. Does `import qs.Commons` resolve from the theme folder?
   2. Do `QtQuick.Effects` and the `.qsb` shaders work in the greeter?
   3. Can `Main.qml` read `snapshot.json` next to it?
   4. In which order does SDDM 0.21 read `/usr/lib/sddm/sddm.conf.d`,
      `/etc/sddm.conf.d` and `/etc/sddm.conf`? (From the SDDM source or
      documentation, then one check with `--test-mode`.)
   5. Does `pkexec` from Studio's Quickshell process show the polkit
      prompt, and what exit codes does it give for cancel and wrong password?
2. **Helper** `status` and `stage`, with table-driven tests: each setting
   and element against kept or dropped; each status state from a fake
   `/etc` and `/usr` tree. Unhappy paths: missing wallpaper, a picture over
   the limit, an unreadable `shell.json`.
3. **Greeter bundle.** Visual check in `--test-mode` for every preset that
   carries over, on a wide and a narrow screen, with a light and a dark
   theme, a failed login and a long account name.
4. **Publisher**, with tests of the transaction against a temporary prefix
   (the prefix is fixed to `/` when the script runs as root). Unhappy paths:
   a symlink in staging, a file over the limit, a bad snapshot, a failure in
   the middle of publishing (the old theme stays), restore with a changed
   theme folder (refused).
5. **Studio** section and dialogs. Visual check of every state, keyboard
   focus in the dialogs, both languages.
6. **End to end on this machine.** This changes `/usr` and `/etc` and
   needs the password, so it needs the user's approval: copy, log out, log
   in, then restore. Check the result with Unlock → a theme and with Unlock
   → default.
7. README, then `tests/validate.sh` and the review.

## Decisions

The user accepted each recommendation below on 2026-11-20.

1. **Where the privileged code lives.** Recommended: like Omarchy, the
   fixed transaction is in the plugin's script and runs through `pkexec`
   on every copy. The other option installs a root-owned publisher once
   (for example in `/usr/local/lib/foamy-lock/`) and runs only that. It is
   stronger against a changed plugin folder, but it needs its own update
   path. Either way, the password prompt is the trust decision: the copied
   QML becomes the code that reads every user's login password.
2. **Video backgrounds.** Recommended: leave them out at first. Use the
   video's still frame as the picture instead.
3. **An Omarchy menu entry.** Recommended: no automatic entry. Show an
   optional `omarchy-menu.jsonc` snippet in the README.
4. **Drop-in name and theme folder** (changed 2026-11-20 after miriam-pc).
   The drop-in is `99-zz-foamy-lock.conf`. It sorts after Omarchy's
   `10-theme.conf` and `99-omarchy-login.conf` and after a custom `99-z-…`
   file, in byte order and under `nb_NO`. It sets `ThemeDir` to
   `/usr/share/sddm/themes` along with `Current`, and the theme is installed
   there, so another file's `ThemeDir` can't hide it. Copying replaces
   whatever theme was selected; the dialog names it. Restore removes only our
   drop-in and theme folder, so the earlier theme and folder apply again.
   `status` reports the effective `ThemeDir` and checks our folder in it.
