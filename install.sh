#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CFLIB_DIR="$SCRIPT_DIR/crazyflie-lib-python"
CFLIB_REPO="https://github.com/bitcraze/crazyflie-lib-python.git"
CFLIB_VENV="$SCRIPT_DIR/.venv-cflib"

LPS_DIR="$SCRIPT_DIR/lps-tools"
LPS_REPO="https://github.com/bitcraze/lps-tools.git"
LPS_VENV="$SCRIPT_DIR/.venv-lps"

STARTER_PROGRAMS_DIR="$SCRIPT_DIR/starter_programs"
VSCODE_SETTINGS_DIR="$STARTER_PROGRAMS_DIR/.vscode"
VSCODE_SETTINGS_FILE="$VSCODE_SETTINGS_DIR/settings.json"
VSCODE_PYTHON_EXTENSION="ms-python.python"

APP_DIR="$HOME/.local/share/applications"
WRAPPER_DIR="$HOME/.local/bin"

CFCLIENT_WRAPPER="$WRAPPER_DIR/cmra-cfclient"
LPS_WRAPPER="$WRAPPER_DIR/cmra-lps-tools"
VSCODE_WRAPPER="$WRAPPER_DIR/cmra-crazyflie-code"

CFCLIENT_DESKTOP_NAME="Crazyflie Client.desktop"
LPS_DESKTOP_NAME="LPS Tools.desktop"
VSCODE_DESKTOP_NAME="Crazyflie Starter Programs.desktop"

log() {
    printf '\n\033[1;34m[CMRA install]\033[0m %s\n' "$*"
}

ok() {
    printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[WARNING]\033[0m %s\n' "$*" >&2
}

fail() {
    printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
    exit 1
}

trap 'fail "Installation failed on line $LINENO."' ERR

if [[ "${EUID}" -eq 0 ]]; then
    fail "Run this script as your normal user, not as root. It will use sudo when needed."
fi

cd "$SCRIPT_DIR"

log "Requesting sudo access..."
sudo -v

log "Installing Ubuntu prerequisites..."
sudo apt update
sudo apt install -y \
    git \
    python3-pip \
    python3-venv \
    curl \
    ca-certificates \
    libxcb-xinerama0 \
    libxcb-cursor0

log "Installing uv using Astral's installer..."
curl -LsSf https://astral.sh/uv/install.sh | sh

export PATH="$HOME/.local/bin:$PATH"
if [[ -f "$HOME/.local/bin/env" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.local/bin/env"
fi

command -v uv >/dev/null 2>&1 || fail "'uv' was installed but is not recognized on PATH."
command -v uvx >/dev/null 2>&1 || fail "'uvx' was installed but is not recognized on PATH."

uv --version
uvx --version
ok "uv and uvx are available."

CODE_BIN=""
for candidate in \
    "$(command -v code 2>/dev/null || true)" \
    /usr/bin/code \
    /usr/local/bin/code \
    /snap/bin/code \
    "$HOME/.local/bin/code"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        CODE_BIN="$candidate"
        break
    fi
done

if [[ -n "$CODE_BIN" ]]; then
    ok "VS Code command is available: $CODE_BIN"

    log "Checking Microsoft Python extension for VS Code..."
    if "$CODE_BIN" --list-extensions 2>/dev/null | grep -Fxq "$VSCODE_PYTHON_EXTENSION"; then
        ok "Microsoft Python extension is already installed: $VSCODE_PYTHON_EXTENSION"
    else
        log "Installing Microsoft Python extension for VS Code..."
        if "$CODE_BIN" --install-extension "$VSCODE_PYTHON_EXTENSION"; then
            ok "Installed VS Code extension: $VSCODE_PYTHON_EXTENSION"
        else
            warn "Could not install VS Code extension: $VSCODE_PYTHON_EXTENSION"
            warn "You can install it later with: $CODE_BIN --install-extension $VSCODE_PYTHON_EXTENSION"
        fi
    fi
else
    warn "VS Code was not found in PATH or the usual Ubuntu install locations."
    warn "The Microsoft Python extension could not be installed yet."
    warn "The launcher will still be created and will check again each time it is opened."
    warn "After installing VS Code, re-run this installer to install: $VSCODE_PYTHON_EXTENSION"
fi

###############################################################################
# Clone source repositories
###############################################################################

log "Checking Crazyflie Python library source..."
if [[ -e "$CFLIB_DIR" ]]; then
    if [[ -d "$CFLIB_DIR/.git" ]]; then
        ok "crazyflie-lib-python already exists; using the existing checkout."
    else
        fail "$CFLIB_DIR exists but is not a Git repository. Remove or rename it, then run the installer again."
    fi
else
    git clone "$CFLIB_REPO" "$CFLIB_DIR"
fi

log "Checking Bitcraze LPS Tools source..."
if [[ -e "$LPS_DIR" ]]; then
    if [[ -d "$LPS_DIR/.git" ]]; then
        ok "lps-tools already exists; using the existing checkout."
    else
        fail "$LPS_DIR exists but is not a Git repository. Remove or rename it, then run the installer again."
    fi
else
    git clone "$LPS_REPO" "$LPS_DIR"
fi

###############################################################################
# Separate Python environments
#
# IMPORTANT:
# cflib and lps-tools currently require incompatible PyUSB versions.
# They must NOT be installed into the same virtual environment.
###############################################################################

log "Creating Crazyflie/cflib virtual environment..."
if [[ ! -d "$CFLIB_VENV" ]]; then
    python3 -m venv "$CFLIB_VENV"
else
    ok "Crazyflie virtual environment already exists: $CFLIB_VENV"
fi

log "Upgrading pip in the Crazyflie/cflib environment..."
"$CFLIB_VENV/bin/python" -m pip install --upgrade pip

log "Installing crazyflie-lib-python in editable mode..."
"$CFLIB_VENV/bin/python" -m pip install -e "$CFLIB_DIR"

log "Checking Crazyflie/cflib dependency consistency..."
"$CFLIB_VENV/bin/python" -m pip check

log "Creating LPS Tools virtual environment..."
if [[ ! -d "$LPS_VENV" ]]; then
    python3 -m venv "$LPS_VENV"
else
    ok "LPS Tools virtual environment already exists: $LPS_VENV"
fi

log "Upgrading pip in the LPS Tools environment..."
"$LPS_VENV/bin/python" -m pip install --upgrade pip

log "Installing LPS Tools with PyQt5 support..."
"$LPS_VENV/bin/python" -m pip install -e "$LPS_DIR[pyqt5]"

log "Checking LPS Tools dependency consistency..."
"$LPS_VENV/bin/python" -m pip check

###############################################################################
# Launchers
###############################################################################

log "Creating command-line launchers..."
mkdir -p "$WRAPPER_DIR"
mkdir -p "$STARTER_PROGRAMS_DIR"
mkdir -p "$VSCODE_SETTINGS_DIR"

log "Creating VS Code settings for starter_programs..."
cat > "$VSCODE_SETTINGS_FILE" <<SETTINGS_EOF
{
    "python.defaultInterpreterPath": "$CFLIB_VENV/bin/python",
    "python.terminal.activateEnvironment": true,
    "terminal.integrated.cwd": "$STARTER_PROGRAMS_DIR",
    "terminal.integrated.env.linux": {
        "VIRTUAL_ENV": "$CFLIB_VENV",
        "PATH": "$CFLIB_VENV/bin:\${env:PATH}"
    }
}
SETTINGS_EOF

cat > "$CFCLIENT_WRAPPER" <<'CFCLIENT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="$HOME/.local/bin:$PATH"
exec uvx cfclient "$@"
CFCLIENT_EOF
chmod +x "$CFCLIENT_WRAPPER"

cat > "$LPS_WRAPPER" <<LPS_EOF
#!/usr/bin/env bash
set -Eeuo pipefail
exec "$LPS_VENV/bin/python" -m lpstools "\$@"
LPS_EOF
chmod +x "$LPS_WRAPPER"

cat > "$VSCODE_WRAPPER" <<VSCODE_EOF
#!/usr/bin/env bash
set -Eeuo pipefail

LOG_FILE="\${XDG_CACHE_HOME:-\$HOME/.cache}/cmra-crazyflie-code.log"
mkdir -p "\$(dirname "\$LOG_FILE")"

# Desktop launchers often have a smaller PATH than an interactive terminal.
# Search the common Ubuntu VS Code locations explicitly instead of depending on it.
CODE_BIN=""
for candidate in \
    /usr/bin/code \
    /usr/local/bin/code \
    /snap/bin/code \
    "\$HOME/.local/bin/code"; do
    if [[ -x "\$candidate" ]]; then
        CODE_BIN="\$candidate"
        break
    fi
done

if [[ -z "\$CODE_BIN" ]] && command -v code >/dev/null 2>&1; then
    CODE_BIN="\$(command -v code)"
fi

show_error() {
    local message="\$1"
    printf '%s: %s\n' "\$(date -Is)" "\$message" >>"\$LOG_FILE"
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "Crazyflie Starter Programs" "\$message" || true
    elif [[ -x /usr/bin/notify-send ]]; then
        /usr/bin/notify-send "Crazyflie Starter Programs" "\$message" || true
    fi
}

if [[ -z "\$CODE_BIN" ]]; then
    show_error "Could not find the VS Code 'code' executable. Checked /usr/bin, /usr/local/bin, /snap/bin, and ~/.local/bin."
    exit 1
fi

if [[ ! -x "$CFLIB_VENV/bin/python" ]]; then
    show_error "Crazyflie Python environment is missing: $CFLIB_VENV"
    exit 1
fi

if [[ ! -d "$STARTER_PROGRAMS_DIR" ]]; then
    show_error "starter_programs folder is missing: $STARTER_PROGRAMS_DIR"
    exit 1
fi

# Give VS Code and any child processes the Crazyflie environment immediately.
# .vscode/settings.json also pins the interpreter and terminal environment if an
# existing VS Code process receives the new window request.
export VIRTUAL_ENV="$CFLIB_VENV"
export PATH="$CFLIB_VENV/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:\$HOME/.local/bin"
unset PYTHONHOME || true

printf '%s: launching %s --new-window %s\n' "\$(date -Is)" "\$CODE_BIN" "$STARTER_PROGRAMS_DIR" >>"\$LOG_FILE"
exec "\$CODE_BIN" --new-window "$STARTER_PROGRAMS_DIR" "\$@" >>"\$LOG_FILE" 2>&1
VSCODE_EOF
chmod +x "$VSCODE_WRAPPER"
ok "Created: $CFCLIENT_WRAPPER"
ok "Created: $LPS_WRAPPER"
ok "Created: $VSCODE_WRAPPER"

###############################################################################
# Desktop/application shortcuts
###############################################################################

log "Creating desktop/application shortcuts..."
mkdir -p "$APP_DIR"

CFCLIENT_DESKTOP_FILE="$APP_DIR/$CFCLIENT_DESKTOP_NAME"
cat > "$CFCLIENT_DESKTOP_FILE" <<DESKTOP_EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Crazyflie Client
Comment=Launch the Crazyflie client with uvx
Exec=$CFCLIENT_WRAPPER
Icon=applications-engineering
Terminal=false
Categories=Development;Education;
StartupNotify=true
DESKTOP_EOF
chmod +x "$CFCLIENT_DESKTOP_FILE"

LPS_DESKTOP_FILE="$APP_DIR/$LPS_DESKTOP_NAME"
cat > "$LPS_DESKTOP_FILE" <<DESKTOP_EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=LPS Tools
Comment=Launch Bitcraze LPS Tools
Exec=$LPS_WRAPPER
Icon=applications-engineering
Terminal=false
Categories=Development;Education;
StartupNotify=true
DESKTOP_EOF
chmod +x "$LPS_DESKTOP_FILE"

VSCODE_DESKTOP_FILE="$APP_DIR/$VSCODE_DESKTOP_NAME"
cat > "$VSCODE_DESKTOP_FILE" <<DESKTOP_EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Crazyflie Starter Programs
Comment=Open starter_programs in VS Code using the Crazyflie Python environment
Exec="$VSCODE_WRAPPER"
TryExec=$VSCODE_WRAPPER
Path=$STARTER_PROGRAMS_DIR
Icon=com.visualstudio.code
Terminal=false
Categories=Development;Education;IDE;
StartupNotify=true
DESKTOP_EOF
chmod +x "$VSCODE_DESKTOP_FILE"

if command -v xdg-user-dir >/dev/null 2>&1; then
    DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
else
    DESKTOP_DIR=""
fi
DESKTOP_DIR="${DESKTOP_DIR:-$HOME/Desktop}"

mkdir -p "$DESKTOP_DIR"

cp "$CFCLIENT_DESKTOP_FILE" "$DESKTOP_DIR/$CFCLIENT_DESKTOP_NAME"
cp "$LPS_DESKTOP_FILE" "$DESKTOP_DIR/$LPS_DESKTOP_NAME"
cp "$VSCODE_DESKTOP_FILE" "$DESKTOP_DIR/$VSCODE_DESKTOP_NAME"

chmod +x \
    "$DESKTOP_DIR/$CFCLIENT_DESKTOP_NAME" \
    "$DESKTOP_DIR/$LPS_DESKTOP_NAME" \
    "$DESKTOP_DIR/$VSCODE_DESKTOP_NAME"

if command -v gio >/dev/null 2>&1; then
    gio set "$DESKTOP_DIR/$CFCLIENT_DESKTOP_NAME" metadata::trusted true >/dev/null 2>&1 || true
    gio set "$DESKTOP_DIR/$LPS_DESKTOP_NAME" metadata::trusted true >/dev/null 2>&1 || true
    gio set "$DESKTOP_DIR/$VSCODE_DESKTOP_NAME" metadata::trusted true >/dev/null 2>&1 || true
fi

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
fi

ok "Desktop shortcuts created in: $DESKTOP_DIR"
ok "If GNOME still shows the desktop file as untrusted, right-click it once and choose 'Allow Launching'."

###############################################################################
# Crazyflie / LPS device permissions
###############################################################################

log "Configuring Crazyflie and LPS USB permissions..."

GROUP_MEMBERSHIP_CHANGED=0

# Make sure plugdev exists before installing udev rules that reference it.
if ! getent group plugdev >/dev/null 2>&1; then
    sudo groupadd --system plugdev
fi

# Give the current user access to USB/serial devices.
for group in plugdev dialout; do
    if id -nG "$USER" | tr ' ' '\n' | grep -qx "$group"; then
        ok "$USER is already a member of the $group group."
    else
        sudo adduser "$USER" "$group"
        GROUP_MEMBERSHIP_CHANGED=1
        ok "Added $USER to the $group group."
    fi
done

###############################################################################
# Crazyflie / Crazyradio udev rules
###############################################################################

log "Installing Crazyflie / Crazyradio udev rules..."

sudo tee /etc/udev/rules.d/99-bitcraze.rules >/dev/null <<'UDEV_EOF'
# Crazyradio (normal operation)
SUBSYSTEM=="usb", ATTRS{idVendor}=="1915", ATTRS{idProduct}=="7777", MODE="0664", GROUP="plugdev"

# Crazyradio bootloader
SUBSYSTEM=="usb", ATTRS{idVendor}=="1915", ATTRS{idProduct}=="0101", MODE="0664", GROUP="plugdev"

# Crazyflie over USB
SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="5740", MODE="0664", GROUP="plugdev"
UDEV_EOF

ok "Installed /etc/udev/rules.d/99-bitcraze.rules"

###############################################################################
# LPS udev rules
###############################################################################

log "Installing LPS USB bootloader rules..."

sudo tee /etc/udev/rules.d/99-lps.rules >/dev/null <<'UDEV_EOF'
SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="df11", MODE="0664", GROUP="plugdev"
UDEV_EOF

ok "Installed /etc/udev/rules.d/99-lps.rules"

###############################################################################
# Reload udev
###############################################################################

log "Reloading udev rules..."

sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=usb

ok "udev rules reloaded."

###############################################################################
# Functional tests
###############################################################################

log "Testing Crazyflie Python imports..."
"$CFLIB_VENV/bin/python" - <<'PY'
import cflib
import usb
from cflib.crazyflie import Crazyflie
from cflib.positioning.motion_commander import MotionCommander

print(f"cflib import OK: {cflib.__file__}")
print(f"PyUSB version: {getattr(usb, '__version__', 'unknown')}")
print(f"Crazyflie class import OK: {Crazyflie.__name__}")
print(f"MotionCommander import OK: {MotionCommander.__name__}")
PY
ok "Crazyflie Python environment passed its import test."

log "Testing LPS Tools Python imports..."
"$LPS_VENV/bin/python" - <<'PY'
import lpstools
import serial
import usb

print(f"lpstools import OK: {lpstools.__file__}")
print(f"pyserial import OK: {serial.__file__}")
print(f"PyUSB version: {getattr(usb, '__version__', 'unknown')}")
PY
ok "LPS Tools Python environment passed its import test."

###############################################################################
# Summary / usage guide
###############################################################################

cat <<SUMMARY_EOF

===============================================================================
CMRA Crazyflie + LPS installation completed successfully
===============================================================================

INSTALL LOCATIONS
-----------------
Project directory:
  $SCRIPT_DIR

Crazyflie Python source:
  $CFLIB_DIR

Crazyflie/cflib virtual environment:
  $CFLIB_VENV

LPS Tools source:
  $LPS_DIR

LPS Tools virtual environment:
  $LPS_VENV

Crazyflie Client launcher:
  $CFCLIENT_WRAPPER

LPS Tools launcher:
  $LPS_WRAPPER

Crazyflie VS Code launcher:
  $VSCODE_WRAPPER

Starter programs folder:
  $STARTER_PROGRAMS_DIR

VS Code starter folder:
  $STARTER_PROGRAMS_DIR

VS Code Python extension:
  $VSCODE_PYTHON_EXTENSION


===============================================================================
1. START THE CRAZYFLIE CLIENT
===============================================================================

EASIEST METHOD - from any terminal:

  cmra-cfclient

You can also run:

  uvx cfclient

Or launch:

  "Crazyflie Client"

from the Ubuntu application menu or from the desktop shortcut.


IMPORTANT:
The graphical Crazyflie Client launched with uvx has its own uv-managed Python
environment. You do NOT need to activate .venv-cflib just to open cfclient.


===============================================================================
2. ENTER THE CRAZYFLIE / CFLIB PYTHON VIRTUAL ENVIRONMENT
===============================================================================

Use this environment when you are writing or running Python programs that
import cflib.

Activate it:

  cd "$SCRIPT_DIR"
  source "$CFLIB_VENV/bin/activate"

After activation, your shell prompt should usually show the environment name.

Verify which Python is active:

  which python

It should print:

  $CFLIB_VENV/bin/python

Check Python:

  python --version

Check cflib:

  python -c "import cflib; print(cflib.__file__)"

Check dependencies:

  python -m pip check

List installed packages:

  python -m pip list


===============================================================================
3. RUN A PYTHON SCRIPT THAT USES CFLIB
===============================================================================

First activate the environment:

  cd "$SCRIPT_DIR"
  source "$CFLIB_VENV/bin/activate"

Then run your script:

  python your_script.py

For example, if your script is:

  $SCRIPT_DIR/test_flight.py

run:

  python "$SCRIPT_DIR/test_flight.py"


YOU CAN ALSO RUN WITHOUT ACTIVATING THE ENVIRONMENT:

  "$CFLIB_VENV/bin/python" your_script.py

This is useful in shell scripts, launchers, cron jobs, and automation.


===============================================================================
4. LEAVE A VIRTUAL ENVIRONMENT
===============================================================================

Run:

  deactivate

You should then return to your normal system Python environment.


===============================================================================
5. OPEN STARTER PROGRAMS IN VS CODE WITH THE CRAZYFLIE ENVIRONMENT
===============================================================================

EASIEST METHOD - from any terminal:

  cmra-crazyflie-code

Or launch:

  "Crazyflie Starter Programs"

from the Ubuntu application menu or from the desktop shortcut.

This opens only the folder:

  $STARTER_PROGRAMS_DIR

using the generated workspace:

  $STARTER_PROGRAMS_DIR

The launcher activates:

  $CFLIB_VENV

and the workspace explicitly selects:

  $CFLIB_VENV/bin/python

for Python plus the same environment for VS Code integrated terminals. This also
keeps the correct Crazyflie environment when another VS Code window is already open.


===============================================================================
6. START LPS TOOLS
===============================================================================

EASIEST METHOD - from any terminal:

  cmra-lps-tools

You can also launch:

  "LPS Tools"

from the Ubuntu application menu or desktop shortcut.


===============================================================================
7. ENTER THE LPS TOOLS VIRTUAL ENVIRONMENT
===============================================================================

Activate it:

  cd "$SCRIPT_DIR"
  source "$LPS_VENV/bin/activate"

Verify Python:

  which python

It should print:

  $LPS_VENV/bin/python

Check dependencies:

  python -m pip check

Start LPS Tools while this environment is active:

  python -m lpstools

When finished:

  deactivate


===============================================================================
8. START LPS TOOLS WITHOUT ACTIVATING THE ENVIRONMENT
===============================================================================

You can directly run:

  "$LPS_VENV/bin/python" -m lpstools

or simply:

  cmra-lps-tools


===============================================================================
9. WHY THERE ARE TWO PYTHON VIRTUAL ENVIRONMENTS
===============================================================================

Do NOT combine these environments.

crazyflie-lib-python and lps-tools currently require different versions of
PyUSB. Keeping them separate prevents pip from repeatedly upgrading and
downgrading PyUSB and prevents "pip check" dependency failures.

Use:

  .venv-cflib  -> Python code using cflib
  .venv-lps    -> LPS Tools


===============================================================================
10. UPDATE THE CRAZYFLIE PYTHON LIBRARY
===============================================================================

Go to the source checkout:

  cd "$CFLIB_DIR"

See whether you have local changes:

  git status

Pull the newest source:

  git pull --ff-only

Reinstall/update the editable package:

  "$CFLIB_VENV/bin/python" -m pip install -e "$CFLIB_DIR"

Check dependencies:

  "$CFLIB_VENV/bin/python" -m pip check


===============================================================================
11. UPDATE LPS TOOLS
===============================================================================

Go to the source checkout:

  cd "$LPS_DIR"

See whether you have local changes:

  git status

Pull the newest source:

  git pull --ff-only

Reinstall/update it:

  "$LPS_VENV/bin/python" -m pip install -e "$LPS_DIR[pyqt5]"

Check dependencies:

  "$LPS_VENV/bin/python" -m pip check


===============================================================================
12. RE-RUN THIS INSTALLER
===============================================================================

This installer is designed to be re-runnable.

From the project directory:

  cd "$SCRIPT_DIR"
  ./install.sh

It will reuse the existing repositories and virtual environments.


===============================================================================
13. COMPLETELY REBUILD ONLY THE CFLIB ENVIRONMENT
===============================================================================

From the project directory:

  cd "$SCRIPT_DIR"
  rm -rf "$CFLIB_VENV"
  python3 -m venv "$CFLIB_VENV"
  "$CFLIB_VENV/bin/python" -m pip install --upgrade pip
  "$CFLIB_VENV/bin/python" -m pip install -e "$CFLIB_DIR"
  "$CFLIB_VENV/bin/python" -m pip check


===============================================================================
14. COMPLETELY REBUILD ONLY THE LPS TOOLS ENVIRONMENT
===============================================================================

From the project directory:

  cd "$SCRIPT_DIR"
  rm -rf "$LPS_VENV"
  python3 -m venv "$LPS_VENV"
  "$LPS_VENV/bin/python" -m pip install --upgrade pip
  "$LPS_VENV/bin/python" -m pip install -e "$LPS_DIR[pyqt5]"
  "$LPS_VENV/bin/python" -m pip check


===============================================================================
15. USEFUL TROUBLESHOOTING COMMANDS
===============================================================================

Check uv:

  uv --version
  uvx --version
  which uv
  which uvx

Check the Crazyflie environment:

  "$CFLIB_VENV/bin/python" --version
  "$CFLIB_VENV/bin/python" -m pip check
  "$CFLIB_VENV/bin/python" -m pip list
  "$CFLIB_VENV/bin/python" -c "import cflib, usb; print(cflib.__file__); print(usb.__version__)"

Check the LPS environment:

  "$LPS_VENV/bin/python" --version
  "$LPS_VENV/bin/python" -m pip check
  "$LPS_VENV/bin/python" -m pip list
  "$LPS_VENV/bin/python" -c "import lpstools, usb; print(lpstools.__file__); print(usb.__version__)"

Check your Linux groups:

  groups

Check USB devices:

  lsusb

Check serial devices:

  ls -l /dev/ttyACM* /dev/ttyUSB* 2>/dev/null || true


===============================================================================
16. QUICK REFERENCE
===============================================================================

Open Crazyflie Client:
  cmra-cfclient

Open LPS Tools:
  cmra-lps-tools

Open starter_programs in VS Code with the cflib environment:
  cmra-crazyflie-code

Enter cflib environment:
  source "$CFLIB_VENV/bin/activate"

Enter LPS environment:
  source "$LPS_VENV/bin/activate"

Leave either environment:
  deactivate

Run a cflib Python script without activating:
  "$CFLIB_VENV/bin/python" your_script.py

Run LPS Tools without activating:
  "$LPS_VENV/bin/python" -m lpstools

===============================================================================
SUMMARY_EOF

if [[ -d "$SCRIPT_DIR/.venv" ]]; then
    printf '\n'
    warn "An older combined environment still exists at: $SCRIPT_DIR/.venv"
    warn "The new installer does not use it. After confirming the new setup works,"
    warn "you may remove it with: rm -rf \"$SCRIPT_DIR/.venv\""
fi

if [[ "${GROUP_MEMBERSHIP_CHANGED:-0}" -eq 1 ]]; then
    printf '\n'
    printf 'IMPORTANT: Your Linux device-access group membership was updated.\n'
    printf 'Log out of Ubuntu and log back in before using LPS USB/serial devices.\n'
fi

printf '\nInstallation complete.\n'