# Foamy Lock

A lock screen for Omarchy Quattro with a large clock, account name and avatar,
password and fingerprint authentication, network and battery status, and media
controls. It uses Omarchy's wallpaper and authentication services.

![Foamy Lock with a sample account and sample media](preview.png)

The screenshot uses synthetic account and media details and a neutral wallpaper.

## Install

This plugin requires Omarchy Quattro, its Quickshell build, and the existing
`/etc/pam.d/omarchy-lock-password` service. Fingerprint unlock also requires
Omarchy's fingerprint setup and an enrolled fingerprint. The plugin does not
install or change PAM configuration. The layout uses Adwaita Sans, URW Gothic,
and JetBrainsMono Nerd Font; install these fonts for the intended typography and
status icons.

Install while your session is unlocked:

```sh
omarchy plugin add https://github.com/foamrider/foamy-lock.git
```

If another custom lock plugin is enabled, answer **No** to the enable prompt and
replace its entry with `foamy.lock` in `~/.config/omarchy/shell.json` as shown below.
Otherwise, you can enable Foamy Lock at the prompt; Omarchy disables the stock
lock service automatically. Keep exactly one lock service active, and keep
`omarchy.lock` in `disabledPlugins`. Preserve all unrelated entries and settings.

Apply the initial switch with `omarchy restart shell` **while unlocked**. Lock
normally with `omarchy system lock`. Restarting the shell while locked can leave
the compositor showing its lock-screen recovery screen.

## Settings

Settings belong directly on the plugin entry in the `plugins` array of
`~/.config/omarchy/shell.json`, not inside a separate `config` object. This fragment
shows the defaults; merge it into your existing file instead of replacing it:

```json
{
  "version": 1,
  "plugins": [
    {
      "id": "foamy.lock",
      "timeFormat": "24h",
      "showUserInfo": true,
      "showMedia": true,
      "blankAfterSec": 30
    }
  ],
  "disabledPlugins": ["omarchy.lock"]
}
```

| Setting | Default | Values and effect |
| --- | --- | --- |
| `timeFormat` | `"24h"` | `"24h"` or `"12h"`; 12-hour time includes AM/PM. The date uses the session locale. |
| `showUserInfo` | `true` | Show the account name and avatar. Set `false` to hide both. |
| `showMedia` | `true` | Show available MPRIS media and transport controls. Set `false` to hide them. |
| `blankAfterSec` | `30` | Integer from 1 to 2147483 seconds of lock-screen inactivity before blanking the display and keyboard backlight. `null` disables this timer. This does not unlock or suspend the computer. |

All settings are optional. Changes are watched live. Invalid or unreadable JSON,
duplicate plugin entries, or invalid setting values produce a warning and retain
the last valid preferences (the defaults on startup). They never disable locking
or bypass authentication. Correct the file to apply new settings.

The automatic **lock** timeout remains Omarchy's `idle.lock` setting. This plugin's
`blankAfterSec` only controls blanking after a lock has been requested. The normal
password check and wake handling are preserved; a running password check pauses
the blanking timer. Fingerprint waiting does not prevent blanking.

The plugin reads the same `~/.config/omarchy/shell.json` and
`~/.local/state/omarchy/current/background` paths as Omarchy. It stores its derived
avatar thumbnail at `$XDG_CACHE_HOME/omarchy/foamy.lock/avatar.png`, falling back to
`~/.cache/omarchy/foamy.lock/avatar.png`.

## Account name and avatar

Open **About Me** from the application launcher (the app is **Mugshot**, also
available as `mugshot`). It lets you set your account's display name and avatar.
Foamy Lock reads those account details; there is no separate name or image setting
in `shell.json`. Open the preview or lock again after saving to refresh them.

AccountsService supplies the display name and avatar when available. The passwd
entry's full name and `~/.face` are fallbacks; without a display name the login name
is shown, and without a usable image the avatar shows an initial. ImageMagick's
`magick` command creates a square thumbnail; if conversion fails, the original
image is used.

## Media and preview

Media controls use Quickshell's MPRIS integration directly and do not need Foamy
Media or a custom bar. A playing track with metadata takes priority; otherwise the
first player with track metadata is shown. Buttons follow the player's supported
transport actions. No controls appear when no player supplies metadata.

```sh
omarchy-shell lock preview
omarchy-shell lock hidePreview
omarchy-shell lock status
```

Preview is a visual overlay, **not a secure lock**. Click it to dismiss it. Preview
and status use your real account details; the README screenshot is generated
separately with synthetic data. Status includes effective settings, configuration
errors, lock state, and local account information. Do not share its output without
checking it for personal details.

## Validation

```sh
omarchy plugin validate .
qmllint Service.qml LockView.qml
node --test tests/model.test.cjs
python3 tests/render.py
python3 tests/runtime.py
```

The render test uses the real view with synthetic account, network, battery, and
media data. It saves wide, narrow, error, and busy-state images in a temporary
folder. The runtime test uses an isolated home and session bus with simulated
PAM and session-lock objects; it does not lock the desktop or authenticate a user.
A real password/fingerprint unlock, suspend/resume, and multi-monitor lock cycle
still require supervised validation after installation.

## Remove

Run this command only while your session is **unlocked**:

```sh
omarchy plugin remove foamy.lock
```

When removing an enabled replacement, Omarchy restores `omarchy.lock`.
If Foamy Lock was already disabled, explicitly
enable the stock lock with `omarchy plugin enable omarchy.lock`. Restart the
shell while unlocked with `omarchy restart shell`, then verify the stock lock
works. Account details, fingerprints, PAM configuration, and the avatar cache
remain unchanged.

Omarchy manages the plugin entry in `shell.json`. Packages and data outside
the plugin directory are retained unless you remove them separately.

## License

Licensed under [MIT](LICENSE), with the upstream [Omarchy notice](LICENSE-OMARCHY).
