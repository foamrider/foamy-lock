"""Host shells for the offscreen Python test (runtime.py): Omarchy 4.5; tests/harness (Rust) mirrors these rules.

4.5 is FOAMY_HOST_45, else $OMARCHY_TEST_ROOT/shell, else the installed
/usr/share/omarchy/shell. 4.0 runs only when FOAMY_HOST_40 names a 4.0 shell
directory; `--host both` without it runs 4.5 and prints a SKIP line for 4.0."""
import os
from pathlib import Path
import subprocess
import sys

INSTALLED = Path('/usr/share/omarchy/shell')
CHOICES = ('4.5', '4.0', 'both')


def shell(name):
    if name == '4.0':
        value = os.environ.get('FOAMY_HOST_40')
        return Path(value) if value else None
    if os.environ.get('FOAMY_HOST_45'):
        return Path(os.environ['FOAMY_HOST_45'])
    if os.environ.get('OMARCHY_TEST_ROOT'):
        return Path(os.environ['OMARCHY_TEST_ROOT']) / 'shell'
    return INSTALLED


def selected(choice):
    """[(name, shell directory)] to test; prints SKIP for 4.0 without FOAMY_HOST_40."""
    chosen = []
    for name in (['4.5', '4.0'] if choice == 'both' else [choice]):
        path = shell(name)
        if path is None:
            print('SKIP: host 4.0 (set FOAMY_HOST_40 to an Omarchy 4.0 shell directory)', flush=True)
            continue
        if not (path / 'Commons').is_dir():
            raise SystemExit(f'host {name} not found at {path} (set FOAMY_HOST_{name.replace(".", "")})')
        chosen.append((name, path))
    return chosen


def current(script, choice, argv):
    """The (name, shell) this process tests. With several hosts selected, re-run
    `script` once per host with the same arguments and exit with the result."""
    if os.environ.get('FOAMY_LOCK_TEST_SHELL'):
        return os.environ['FOAMY_LOCK_TEST_HOST'], Path(os.environ['FOAMY_LOCK_TEST_SHELL'])
    chosen = selected(choice)
    if not chosen:
        raise SystemExit(0)
    if len(chosen) == 1:
        return chosen[0]
    failed = False
    for name, path in chosen:
        print(f'== host {name}: {path}', flush=True)
        env = dict(os.environ, FOAMY_LOCK_TEST_HOST=name, FOAMY_LOCK_TEST_SHELL=str(path))
        failed |= subprocess.run([sys.executable, '-I', '-B', str(script), *argv], env=env).returncode != 0
    raise SystemExit(1 if failed else 0)


def hermetic(environ, home, runtime, language_file=None):
    """`environ` without the desktop's XDG, display, language and Omarchy paths:
    HOME and every XDG base directory live under `home`."""
    env = {key: value for key, value in environ.items()
           if not key.startswith(('XDG_', 'OMARCHY_', 'FOAMY_LOCK_TEST_'))
           and key not in ('DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE',
                           'DBUS_SESSION_BUS_ADDRESS', 'LANGUAGE', 'QT_SCALE_FACTOR')}
    env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'), XDG_CACHE_HOME=str(home / '.cache'),
               XDG_DATA_HOME=str(home / '.local/share'), XDG_STATE_HOME=str(home / '.local/state'),
               XDG_RUNTIME_DIR=str(runtime))
    for key in ('XDG_DATA_DIRS', 'XDG_CONFIG_DIRS'):
        if key in environ:
            env[key] = environ[key]
    if language_file:
        env['OMARCHY_LANGUAGE_FILE'] = str(language_file)
    return env
