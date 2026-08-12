#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
CFLIB_DIR="$SCRIPT_DIR/crazyflie-lib-python"
CFLIB_REPO="https://github.com/bitcraze/crazyflie-lib-python.git"
APP_DIR="$HOME/.local/share/applications"
WRAPPER_DIR="$HOME/.local/bin"
WRAPPER="$WRAPPER_DIR/cmra-cfclient"
DESKTOP_FILE_NAME="Crazyflie Client.desktop"

log() {
    printf '\n\033[1;34m[CMRA install]\033[0m %s\n' "$*"
}

ok() {
    printf '\033[1;32m[OK]\033[0m %s\n' "$*"
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

log "Creating the project Python virtual environment..."
if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
else
    ok "Virtual environment already exists at $VENV_DIR"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
ok "Activated virtual environment: $VIRTUAL_ENV"

log "Upgrading pip inside the project virtual environment..."
python -m pip install --upgrade pip
python -m pip --version

log "Installing uv using Astral's official installer..."
curl -LsSf https://astral.sh/uv/install.sh | sh

# The standalone uv installer normally places uv/uvx in ~/.local/bin and may
# update shell startup files. Add it explicitly here so this same process can
# verify and use uvx immediately.
export PATH="$HOME/.local/bin:$PATH"
if [[ -f "$HOME/.local/bin/env" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.local/bin/env"
fi

log "Verifying uv and uvx..."
command -v uv >/dev/null 2>&1 || fail "'uv' was installed but is not recognized on PATH."
command -v uvx >/dev/null 2>&1 || fail "'uvx' was installed but is not recognized on PATH."
uv --version
uvx --version
ok "uvx is recognized."

log "Creating a reliable launcher for 'uvx cfclient'..."
mkdir -p "$WRAPPER_DIR"
cat > "$WRAPPER" <<'WRAPPER_EOF'
#!/usr/bin/env bash
set -e
export PATH="$HOME/.local/bin:$PATH"
exec "$HOME/.local/bin/uvx" cfclient "$@"
WRAPPER_EOF
chmod +x "$WRAPPER"

log "Creating Crazyflie Client application/desktop shortcut..."
mkdir -p "$APP_DIR"
APP_DESKTOP_FILE="$APP_DIR/$DESKTOP_FILE_NAME"
cat > "$APP_DESKTOP_FILE" <<DESKTOP_EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Crazyflie Client
Comment=Launch the Crazyflie client with uvx
Exec=$WRAPPER
Icon=applications-engineering
Terminal=false
Categories=Development;Education;
StartupNotify=true
DESKTOP_EOF
chmod +x "$APP_DESKTOP_FILE"

# Create an actual desktop copy as requested. Prefer the user's configured
# desktop directory when xdg-user-dir is available.
if command -v xdg-user-dir >/dev/null 2>&1; then
    DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
else
    DESKTOP_DIR=""
fi
DESKTOP_DIR="${DESKTOP_DIR:-$HOME/Desktop}"
mkdir -p "$DESKTOP_DIR"
cp "$APP_DESKTOP_FILE" "$DESKTOP_DIR/$DESKTOP_FILE_NAME"
chmod +x "$DESKTOP_DIR/$DESKTOP_FILE_NAME"
# GNOME may require desktop launchers to be marked trusted. Do this when gio is available.
if command -v gio >/dev/null 2>&1; then
    gio set "$DESKTOP_DIR/$DESKTOP_FILE_NAME" metadata::trusted true >/dev/null 2>&1 || true
fi
ok "Desktop shortcut created at: $DESKTOP_DIR/$DESKTOP_FILE_NAME"

log "Cloning Crazyflie Python library..."
if [[ -e "$CFLIB_DIR" ]]; then
    if [[ -d "$CFLIB_DIR/.git" ]]; then
        ok "crazyflie-lib-python already exists; using the existing checkout."
    else
        fail "$CFLIB_DIR exists but is not a Git repository. Remove or rename it, then run the installer again."
    fi
else
    git clone "$CFLIB_REPO" "$CFLIB_DIR"
fi

log "Installing crazyflie-lib-python in editable mode into the project venv..."
cd "$CFLIB_DIR"
python -m pip install -e .

log "Checking installed Python dependency consistency..."
python -m pip check

log "Testing Crazyflie Python library imports..."
python - <<'PY'
import cflib
from cflib.crazyflie import Crazyflie
from cflib.positioning.motion_commander import MotionCommander

print(f"cflib import OK: {cflib.__file__}")
print(f"Crazyflie class import OK: {Crazyflie.__name__}")
print(f"MotionCommander import OK: {MotionCommander.__name__}")
PY
ok "Crazyflie Python libraries imported successfully."

cat <<SUMMARY_EOF

============================================================
CMRA Crazyflie installation completed successfully.
============================================================
Project:       $SCRIPT_DIR
Python venv:   $VENV_DIR
CFlib source:  $CFLIB_DIR
Launcher:      $WRAPPER
Desktop entry: $DESKTOP_DIR/$DESKTOP_FILE_NAME

To activate the project environment in a new terminal:
  source "$VENV_DIR/bin/activate"

To launch the Crazyflie client from a terminal:
  uvx cfclient

You can also launch "Crazyflie Client" from the desktop/application menu.
SUMMARY_EOF
