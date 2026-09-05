#!/usr/bin/env bash

set -u

# ============================================================
# GitHub Codespaces GUI
# XFCE + TigerVNC + noVNC
# Display: 1280x720
# ============================================================

VNC_DISPLAY=":1"
DISPLAY_NUM="${VNC_DISPLAY#:}"          # "1"
VNC_PORT="5901"
NOVNC_PORT="6080"

VNC_DIR="$HOME/.vnc"
STARTUP_SCRIPT="$HOME/start-codespace-gui.sh"
AUTOSTART_FILE="/usr/bin/on-autostart"  # executed by Codespaces at boot
AUTOSTART_LOG="$HOME/gui-autostart.log"
BASHRC="$HOME/.bashrc"
NOVNC_LOG="$HOME/noVNC.log"
NOVNC_WEB_DIR="/usr/share/novnc"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

error() {
    echo
    echo "ERROR: $1"
    echo
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

port_in_use() {
    ss -ltn 2>/dev/null | grep -q ":$1 "
}

# FIX: old pattern '/usr/bin/websockify.*6080' never matched, because
# the process is started as plain 'websockify'. Stale noVNC processes
# survived stop_gui() and kept port 6080 busy.
kill_websockify() {
    pkill -f 'websockify.*6080' 2>/dev/null || true
}

kill_xvnc() {
    vncserver -kill "$VNC_DISPLAY" 2>/dev/null || true
    # Fallback if the pid file is stale.
    pkill -f "Xvnc $VNC_DISPLAY " 2>/dev/null || true
}

# FIX: stale X lock files were never removed, so vncserver could refuse
# to start again ("Xvnc is already running") after an unclean shutdown.
clean_vnc_state() {
    rm -f "$VNC_DIR"/*:${DISPLAY_NUM}.pid 2>/dev/null || true
    rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}" 2>/dev/null || true
}

# ------------------------------------------------------------
# Check GUI components
# ------------------------------------------------------------

check_components() {

    local missing=()
    local cmd

    for cmd in \
        vncserver \
        vncpasswd \
        websockify \
        startxfce4 \
        dbus-launch \
        ss
    do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo
        echo "Missing GUI components:"
        printf '  - %s\n' "${missing[@]}"
        echo
        return 1
    fi

    return 0
}

# ------------------------------------------------------------
# Configure XFCE
# ------------------------------------------------------------

configure_xfce() {

    mkdir -p "$VNC_DIR"

    cat > "$VNC_DIR/xstartup" <<'EOF'
#!/bin/sh

unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_DESKTOP=xfce
export XDG_CONFIG_DIRS=/etc/xdg/xdg-xfce:/etc/xdg
export XDG_DATA_DIRS=/usr/share/xfce4:/usr/local/share:/usr/share

exec dbus-launch --exit-with-session startxfce4
EOF

    chmod +x "$VNC_DIR/xstartup"
}

# ------------------------------------------------------------
# VNC password
# ------------------------------------------------------------

# FIX: only prompt when we really have a TTY. Non-interactive contexts
# (boot autostart) now get a random password instead of hanging on
# the vncpasswd prompt.
ensure_vnc_password() {

    mkdir -p "$VNC_DIR"

    if [ -s "$VNC_DIR/passwd" ]; then
        return 0
    fi

    if [ -t 0 ]; then
        rm -f "$VNC_DIR/passwd"
        echo
        echo "No VNC password found. Create one now (max 8 characters)."
        echo
        vncpasswd
        if [ -s "$VNC_DIR/passwd" ]; then
            chmod 600 "$VNC_DIR/passwd"
            return 0
        fi
        return 1
    fi

    # Non-interactive: generate a random password.
    local pw
    pw="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 8)"

    if [ -n "$pw" ]; then
        printf '%s\n' "$pw" | vncpasswd -f > "$VNC_DIR/passwd" 2>/dev/null || true

        if [ ! -s "$VNC_DIR/passwd" ]; then
            printf '%s\n%s\nn\n' "$pw" "$pw" | vncpasswd 2>/dev/null || true
        fi

        if [ -s "$VNC_DIR/passwd" ]; then
            chmod 600 "$VNC_DIR/passwd"
            printf '%s\n' "$pw" > "$VNC_DIR/vnc-password.txt"
            chmod 600 "$VNC_DIR/vnc-password.txt"
            echo "Generated VNC password saved to: $VNC_DIR/vnc-password.txt"
            return 0
        fi
    fi

    rm -f "$VNC_DIR/passwd" 2>/dev/null || true
    return 1
}

# ------------------------------------------------------------
# Stop GUI
# ------------------------------------------------------------

stop_gui() {

    echo
    echo "Stopping GUI..."

    kill_websockify
    kill_xvnc

    sleep 2

    # Remove stale state only AFTER the processes are gone.
    clean_vnc_state

    echo
    echo "GUI stopped."
}

# ------------------------------------------------------------
# Start TigerVNC
# ------------------------------------------------------------

start_vnc() {

    echo
    echo "Starting TigerVNC..."

    # Defensive cleanup (in case this is called directly).
    kill_xvnc
    sleep 1
    clean_vnc_state

    vncserver "$VNC_DISPLAY" \
        -geometry 1280x720 \
        -depth 24 \
        -localhost yes

    sleep 3

    if ! port_in_use "$VNC_PORT"; then

        echo
        echo "TigerVNC failed to start on port $VNC_PORT."
        echo
        echo "Recent VNC log:"
        tail -n 50 "$VNC_DIR"/*.log 2>/dev/null || true

        return 1
    fi

    echo "TigerVNC running: display $VNC_DISPLAY / port $VNC_PORT"
    echo "Resolution: 1280x720"

    return 0
}

# ------------------------------------------------------------
# Start noVNC
# ------------------------------------------------------------

start_novnc() {

    echo
    echo "Starting noVNC..."

    kill_websockify
    sleep 2

    if port_in_use "$NOVNC_PORT"; then

        echo
        echo "ERROR: port $NOVNC_PORT is already occupied."
        echo
        ss -ltnp 2>/dev/null | grep ":$NOVNC_PORT" || true

        return 1
    fi

    (
        nohup websockify \
            --web="$NOVNC_WEB_DIR/" \
            "$NOVNC_PORT" \
            "localhost:$VNC_PORT" \
            > "$NOVNC_LOG" 2>&1 &
    )

    sleep 3

    if ! port_in_use "$NOVNC_PORT"; then

        echo
        echo "noVNC failed to start on port $NOVNC_PORT."
        echo
        echo "noVNC log:"
        cat "$NOVNC_LOG" 2>/dev/null || true

        return 1
    fi

    echo "noVNC running on port $NOVNC_PORT."

    return 0
}

# ------------------------------------------------------------
# Start complete GUI
# ------------------------------------------------------------

start_gui() {

    echo
    echo "=========================================="
    echo " Starting Codespaces GUI"
    echo " Resolution: 1280x720"
    echo "=========================================="

    if ! check_components; then
        error "GUI components are not installed. Choose option 1."
    fi

    configure_xfce

    if ! ensure_vnc_password; then
        error "Could not create a VNC password."
    fi

    # Always start from a clean state.
    stop_gui

    if ! start_vnc; then
        error "TigerVNC could not be started."
    fi

    if ! start_novnc; then
        echo
        echo "noVNC failed. Stopping VNC to leave a clean state."
        kill_xvnc
        clean_vnc_state
        error "noVNC could not be started."
    fi

    # Newer noVNC packages serve index.html at "/", older ones only vnc.html.
    local url_path="/vnc.html"
    if [ -f "$NOVNC_WEB_DIR/index.html" ]; then
        url_path="/"
    fi

    echo
    echo "=========================================="
    echo " GUI STARTED SUCCESSFULLY"
    echo "=========================================="
    echo
    echo "Desktop   : XFCE"
    echo "Resolution: 1280x720"
    echo "TigerVNC  : $VNC_DISPLAY / $VNC_PORT"
    echo "noVNC     : $NOVNC_PORT"
    echo "URL path  : $url_path"
    echo
    echo "Open Codespaces PORTS, forward port $NOVNC_PORT,"
    echo "then open the forwarded URL in your browser."
    echo "=========================================="
}

# ------------------------------------------------------------
# Install GUI components
# ------------------------------------------------------------

install_gui() {

    echo
    echo "=========================================="
    echo " Installing GUI Components"
    echo "=========================================="

    sudo apt update

    sudo DEBIAN_FRONTEND=noninteractive apt install -y \
        xfce4 \
        xfce4-goodies \
        dbus-x11 \
        xterm \
        tigervnc-standalone-server \
        novnc \
        websockify \
        iproute2 \
        procps

    echo
    echo "GUI components installed."
}

# ------------------------------------------------------------
# Configure auto-start (boot + shell fallback)
# ------------------------------------------------------------

configure_autostart() {

    echo
    echo "Configuring GUI auto-start..."

    local gui_user
    gui_user="$(whoami)"

    # --------------------------------------------------------
    # 1) Startup script: idempotent, safe for non-interactive use.
    # --------------------------------------------------------
    cat > "$STARTUP_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Auto-generated by the Codespaces GUI setup script.
# Starts the GUI if it is not already running. Safe to run
# repeatedly and concurrently (flock keeps a single instance).

VNC_DISPLAY=":1"
VNC_PORT="5901"
NOVNC_PORT="6080"
VNC_DIR="$HOME/.vnc"
NOVNC_LOG="$HOME/noVNC.log"

port_in_use() {
    ss -ltn 2>/dev/null | grep -q ":$1 "
}

# Single-instance lock (boot hook and .bashrc can overlap).
if command -v flock >/dev/null 2>&1; then
    exec 9>"/tmp/codespace-gui-startup.lock"
    if ! flock -n 9; then
        exit 0
    fi
fi

# Already running? Do nothing.
if port_in_use "$VNC_PORT" && port_in_use "$NOVNC_PORT"; then
    exit 0
fi

# Clean stale/duplicate processes.
pkill -f 'websockify.*6080' 2>/dev/null || true
vncserver -kill "$VNC_DISPLAY" 2>/dev/null || true
pkill -f "Xvnc $VNC_DISPLAY " 2>/dev/null || true

sleep 2

rm -f "$VNC_DIR"/*:1.pid 2>/dev/null || true
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

# Make sure a VNC password exists (random, non-interactive).
if [ ! -s "$VNC_DIR/passwd" ]; then
    mkdir -p "$VNC_DIR"
    VNC_PW="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 8)"
    if [ -n "$VNC_PW" ]; then
        printf '%s\n' "$VNC_PW" | vncpasswd -f > "$VNC_DIR/passwd" 2>/dev/null || true
        if [ ! -s "$VNC_DIR/passwd" ]; then
            printf '%s\n%s\nn\n' "$VNC_PW" "$VNC_PW" | vncpasswd 2>/dev/null || true
        fi
        if [ -s "$VNC_DIR/passwd" ]; then
            printf '%s\n' "$VNC_PW" > "$VNC_DIR/vnc-password.txt"
            chmod 600 "$VNC_DIR/passwd" "$VNC_DIR/vnc-password.txt"
        else
            rm -f "$VNC_DIR/passwd" 2>/dev/null
        fi
    fi
fi

# Start TigerVNC.
vncserver "$VNC_DISPLAY" \
    -geometry 1280x720 \
    -depth 24 \
    -localhost yes

sleep 3

if ! port_in_use "$VNC_PORT"; then
    exit 1
fi

# Start noVNC.
nohup websockify \
    --web=/usr/share/novnc/ \
    "$NOVNC_PORT" \
    "localhost:$VNC_PORT" \
    > "$NOVNC_LOG" 2>&1 &

sleep 3

if ! port_in_use "$NOVNC_PORT"; then
    exit 1
fi

exit 0
EOF

    chmod +x "$STARTUP_SCRIPT"

    # --------------------------------------------------------
    # 2) Boot hook: /usr/bin/on-autostart
    #    The Codespaces runner executes this file as ROOT every time
    #    the codespace is created or restarts, so the GUI comes up on
    #    boot even before any terminal is opened. We drop back to the
    #    user with 'su -l' so VNC runs as you (not root, HOME correct).
    # --------------------------------------------------------
    if command_exists sudo && command_exists su; then
        sudo tee "$AUTOSTART_FILE" >/dev/null <<EOF
#!/bin/sh
# Auto-generated by the Codespaces GUI setup script.
# Runs as root each time this codespace starts/restarts.
# Starts the XFCE desktop for user '$gui_user'.
exec su -l "$gui_user" -c "nohup '$STARTUP_SCRIPT' > '$AUTOSTART_LOG' 2>&1 &"
EOF
        sudo chmod +x "$AUTOSTART_FILE"
        echo "Boot auto-start : $AUTOSTART_FILE (codespace start/restart)"
    else
        echo "Boot auto-start : unavailable (no sudo/su), shell fallback only"
    fi

    # --------------------------------------------------------
    # 3) Fallback: first interactive shell (.bashrc)
    # --------------------------------------------------------
    [ -f "$BASHRC" ] || touch "$BASHRC"

    sed -i \
        '/# CODESPACE_GUI_AUTOSTART_START/,/# CODESPACE_GUI_AUTOSTART_END/d' \
        "$BASHRC" 2>/dev/null || true

    cat >> "$BASHRC" <<EOF

# CODESPACE_GUI_AUTOSTART_START
if [ "\${CODESPACES:-false}" = "true" ] && [ -x "$STARTUP_SCRIPT" ]; then
    ( "$STARTUP_SCRIPT" >/dev/null 2>&1 & )
fi
# CODESPACE_GUI_AUTOSTART_END
EOF

    echo "Shell fallback  : .bashrc (first terminal)"
    echo
    echo "Auto-start configured."
}

# ------------------------------------------------------------
# Main menu
# ------------------------------------------------------------

echo
echo "=========================================="
echo " GitHub Codespaces GUI"
echo " XFCE + TigerVNC + noVNC"
echo " Resolution: 1280x720"
echo "=========================================="
echo
echo "1) Install / Repair GUI + Start"
echo "2) Start GUI (already installed)"
echo "3) Stop GUI"
echo

read -r -p "Choose [1-3]: " CHOICE || CHOICE=""

case "$CHOICE" in

    1)
        install_gui
        configure_xfce
        start_gui
        configure_autostart
        echo
        echo "Auto-start: ENABLED (boot + shell fallback)"
        ;;

    2)
        start_gui
        ;;

    3)
        stop_gui
        ;;

    *)
        echo
        echo "Invalid choice. Please choose 1, 2, or 3."
        exit 1
        ;;

esac