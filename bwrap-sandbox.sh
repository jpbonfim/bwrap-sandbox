#!/usr/bin/env bash
# ==============================================================================
# Security-Hardened Bubblewrap Sandbox for AI Coding Agents
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Default Settings & State
# ------------------------------------------------------------------------------
ALLOW_NET=false
TARGET_DIR="$(pwd)"
SELECTED_PROFILES=()
COMMAND=()

AVAILABLE_PROFILES=("dev-tools" "antigravity" "claude" "none")

# Data structures for profile mounts & permissions
declare -A MOUNT_PERMS=()       # Path -> "ro" | "rw" (Last profile wins)
ORDERED_MOUNT_PATHS=()          # Preserves registration order
ENABLE_FILTERED_DBUS=false      # Enabled if requested by any active profile

# Cleanup tracker for proxy
PROXY_PID=""
PROXY_DIR=""

cleanup() {
    if [ -n "$PROXY_PID" ]; then
        kill "$PROXY_PID" 2>/dev/null || true
    fi
    if [ -n "$PROXY_DIR" ] && [ -d "$PROXY_DIR" ]; then
        rm -rf "$PROXY_DIR"
    fi
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# Mount Helper Function
# ------------------------------------------------------------------------------
# Usage: set_mount <"ro"|"rw"> <path>
set_mount() {
    local mode="$1"
    local path="$2"

    if [ -e "$path" ]; then
        if [ -z "${MOUNT_PERMS["$path"]:-}" ]; then
            ORDERED_MOUNT_PATHS+=("$path")
        fi
        MOUNT_PERMS["$path"]="$mode"
    fi
}

# ------------------------------------------------------------------------------
# Profile Definitions
# ------------------------------------------------------------------------------
apply_profile() {
    local profile="$1"
    case "$profile" in
        dev-tools)
            set_mount "ro" "$HOME/.local/bin"
            set_mount "ro" "$HOME/.cargo/bin"
            set_mount "ro" "$HOME/.nvm"
            set_mount "ro" "$HOME/.asdf"
            set_mount "ro" "$HOME/.pyenv"
            set_mount "ro" "$HOME/.rustup"
            set_mount "ro" "$HOME/.fnm"
            set_mount "ro" "$HOME/.volta"
            set_mount "ro" "$HOME/.bun/bin"
            set_mount "ro" "$HOME/go/bin"
            ;;

        antigravity)
            set_mount "rw" "$HOME/.antigravity"
            set_mount "rw" "$HOME/.gemini"
            ENABLE_FILTERED_DBUS=true
            ;;

        claude)
            set_mount "rw" "$HOME/.claude"
            set_mount "rw" "$HOME/.claude.json"
            set_mount "rw" "$HOME/.config/claude"
            set_mount "rw" "$HOME/.local/share/claude"
            set_mount "rw" "$HOME/.local/state/claude"
            ;;

        none)
            ;;

        *)
            echo "Error: Unknown profile '$profile'." >&2
            echo "Available profiles: ${AVAILABLE_PROFILES[*]}" >&2
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Help & Usage
# ------------------------------------------------------------------------------
list_profiles() {
    cat <<EOF
Available Agent Profiles:
  dev-tools      Mounts host user toolchains (~/.cargo/bin, ~/.nvm, ~/.pyenv, etc.) [Read-Only]
  antigravity    Mounts ~/.antigravity, ~/.gemini [RW], Playwright cache [RO], and filters D-Bus Keyring
  claude         Mounts ~/.claude, ~/.claude.json, and ~/.config/claude [Read-Write]
  none           No extra mounts applied (default)

Note: You can pass multiple profiles (e.g. -p dev-tools -p antigravity).
      If path permissions conflict, the last profile specified takes precedence.
EOF
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [-- COMMAND [ARGS...]]

A security-hardened Bubblewrap sandbox for AI coding agents.

Options:
  -p, --profile NAME   Permission profile (Can be repeated or comma-separated)
      --list-profiles  List available permission profiles and descriptions
  -n, --net            Allow network access (Default: OFF / isolated)
  -d, --dir PATH       Target workspace directory (Default: current directory)
  -h, --help           Show this help message

Examples:
  $(basename "$0") --list-profiles
  $(basename "$0") -p dev-tools,antigravity --net -- agy
  $(basename "$0") -p dev-tools,claude --net -- claude
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
    -p | --profile)
        IFS=',' read -ra SPLIT_PROFILES <<< "$2"
        for p in "${SPLIT_PROFILES[@]}"; do
            SELECTED_PROFILES+=("$p")
        done
        shift 2
        ;;
    --list-profiles)
        list_profiles
        exit 0
        ;;
    -n | --net)
        ALLOW_NET=true
        shift
        ;;
    -d | --dir)
        TARGET_DIR="$2"
        shift 2
        ;;
    -h | --help)
        usage
        ;;
    --)
        shift
        COMMAND=("$@")
        break
        ;;
    *)
        echo "Error: Unknown argument '$1'" >&2
        usage
        ;;
    esac
done

# Resolve absolute path for workspace
TARGET_DIR="$(cd "$TARGET_DIR" && pwd -P)"

# Default to user's shell or bash if no command specified
if [ ${#COMMAND[@]} -eq 0 ]; then
    COMMAND=("${SHELL:-/bin/bash}")
fi

# Ensure bwrap is installed
if ! command -v bwrap >/dev/null 2>&1; then
    echo "Error: 'bwrap' (bubblewrap) is not installed. Run: sudo apt install bubblewrap" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Core Security Configurations & Base Mounts
# ------------------------------------------------------------------------------
BWRAP_ARGS=(
    # 1. Process & Kernel Isolation
    "--unshare-all"     # Unshare user, pid, ipc, uts, cgroup namespaces
    "--die-with-parent" # Kill all sandbox processes if parent process exits
    "--new-session"     # Disconnect controlling tty (Mitigates TIOCSTI terminal injection)

    # 2. Base Virtual Filesystems
    "--dev" "/dev"       # Clean minimal /dev (null, zero, urandom, etc.)
    "--proc" "/proc"     # Isolated /proc matching the new PID namespace
    "--tmpfs" "/tmp"     # Ephemeral, isolated /tmp in RAM
    "--tmpfs" "/dev/shm" # Ephemeral shared memory in RAM

    # 3. Mask Sensitive Host System Directories
    "--tmpfs" "$HOME" # Mask $HOME completely with ephemeral tmpfs
)

# ------------------------------------------------------------------------------
# Edge Case: Modern Usr-Merged Filesystem Structure
# Handles systems where /bin, /sbin, /lib, /lib64 are symlinks to /usr
# ------------------------------------------------------------------------------
BWRAP_ARGS+=("--ro-bind" "/usr" "/usr")

for sysdir in /bin /sbin /lib /lib64; do
    if [ -L "$sysdir" ]; then
        # Preserve relative symlink (e.g., usr/bin -> /bin)
        BWRAP_ARGS+=("--symlink" "$(readlink "$sysdir")" "$sysdir")
    elif [ -d "$sysdir" ]; then
        BWRAP_ARGS+=("--ro-bind" "$sysdir" "$sysdir")
    fi
done

# Essential system configuration (read-only)
BWRAP_ARGS+=(
    "--ro-bind-try" "/etc/alternatives" "/etc/alternatives"
    "--ro-bind-try" "/etc/ssl" "/etc/ssl"
    "--ro-bind-try" "/etc/pki" "/etc/pki"
    "--ro-bind-try" "/etc/ca-certificates" "/etc/ca-certificates"
    "--ro-bind-try" "/usr/share/ca-certificates" "/usr/share/ca-certificates"
)

# ------------------------------------------------------------------------------
# Apply Selected Profiles & Build Path Mounts
# ------------------------------------------------------------------------------
for profile in "${SELECTED_PROFILES[@]}"; do
    apply_profile "$profile"
done

DETECTED_USER_PATHS=()

for target_path in "${ORDERED_MOUNT_PATHS[@]}"; do
    mode="${MOUNT_PERMS["$target_path"]}"
    if [ "$mode" = "rw" ]; then
        BWRAP_ARGS+=("--bind" "$target_path" "$target_path")
    elif [ "$mode" = "ro" ]; then
        BWRAP_ARGS+=("--ro-bind" "$target_path" "$target_path")
    fi

    if [[ "$target_path" == *"bin"* && -d "$target_path" ]]; then
        DETECTED_USER_PATHS+=("$target_path")
    fi
done

# Build sanitized PATH
CLEAN_PATH="$(
    IFS=:
    echo "${DETECTED_USER_PATHS[*]}"
):/usr/local/bin:/usr/bin:/bin"

# ------------------------------------------------------------------------------
# Workspace Security: Mount Project & Defend Git Hooks
# ------------------------------------------------------------------------------
# Mount target project workspace as read-write
BWRAP_ARGS+=(
    "--bind" "$TARGET_DIR" "$TARGET_DIR"
    "--chdir" "$TARGET_DIR"
)

# Edge Case: Prevent Git Hook Poisoning (Workspace Escape Vector)
# If .git exists, make .git/hooks read-only so agent cannot insert malicious triggers
if [ -d "$TARGET_DIR/.git" ]; then
    mkdir -p "$TARGET_DIR/.git/hooks"
    BWRAP_ARGS+=("--ro-bind" "$TARGET_DIR/.git/hooks" "$TARGET_DIR/.git/hooks")
fi

# ------------------------------------------------------------------------------
# Network Isolation & DNS Handling
# ------------------------------------------------------------------------------
if [ "$ALLOW_NET" = true ]; then
    BWRAP_ARGS+=("--share-net")

    # Handle systemd-resolved and standard resolv.conf symlinks safely
    if [ -f /etc/resolv.conf ]; then
        RESOLV_REALPATH="$(realpath /etc/resolv.conf 2>/dev/null || echo "/etc/resolv.conf")"
        if [ "$RESOLV_REALPATH" != "/etc/resolv.conf" ] && [ -f "$RESOLV_REALPATH" ]; then
            BWRAP_ARGS+=("--ro-bind" "$RESOLV_REALPATH" "$RESOLV_REALPATH")
        fi
        BWRAP_ARGS+=("--ro-bind-try" "/etc/resolv.conf" "/etc/resolv.conf")
    fi
else
    BWRAP_ARGS+=("--unshare-net")
fi

# ------------------------------------------------------------------------------
# Base Environment Sanitization (--clearenv must be first!)
# ------------------------------------------------------------------------------
BWRAP_ENV=(
    "--clearenv"
    "--setenv" "USER" "${USER:-sandbox}"
    "--setenv" "LOGNAME" "${LOGNAME:-sandbox}"
    "--setenv" "HOME" "$HOME"
    "--setenv" "PATH" "$CLEAN_PATH"
    "--setenv" "TERM" "${TERM:-xterm-256color}"
    "--setenv" "LANG" "${LANG:-C.UTF-8}"
    "--setenv" "LC_ALL" "${LC_ALL:-C.UTF-8}"
    # Global Git override: force Git to ignore local hooks even if created elsewhere
    "--setenv" "GIT_CONFIG_PARAMETERS" "'core.hooksPath=/dev/null'"
)

# ------------------------------------------------------------------------------
# Secure D-Bus Filtering via xdg-dbus-proxy (Appended AFTER --clearenv)
# ------------------------------------------------------------------------------
if [ "$ENABLE_FILTERED_DBUS" = true ]; then
    USER_UID="$(id -u)"
    HOST_BUS="/run/user/$USER_UID/bus"

    if [ -S "$HOST_BUS" ]; then
        if command -v xdg-dbus-proxy >/dev/null 2>&1; then
            PROXY_DIR="$(mktemp -d /tmp/bwrap-dbus-XXXXXX)"
            PROXY_BUS="$PROXY_DIR/bus"

            # Proxy Keyring and Secret Service APIs; block host systemd1
            xdg-dbus-proxy "unix:path=$HOST_BUS" "$PROXY_BUS" \
                --filter \
                --talk=org.freedesktop.secrets \
                --talk=org.gnome.keyring &
            PROXY_PID=$!

            # Wait until proxy socket is created to prevent race conditions
            while [ ! -S "$PROXY_BUS" ]; do
                sleep 0.02
            done

            BWRAP_ARGS+=(
                "--dir" "/run/user/$USER_UID"
                "--bind" "$PROXY_BUS" "/run/user/$USER_UID/bus"
            )
            BWRAP_ENV+=(
                "--setenv" "XDG_RUNTIME_DIR" "/run/user/$USER_UID"
                "--setenv" "DBUS_SESSION_BUS_ADDRESS" "unix:path=/run/user/$USER_UID/bus"
            )
        else
            echo "Warning: 'xdg-dbus-proxy' is not installed. D-Bus filtering disabled." >&2
            echo "Run: sudo apt install xdg-dbus-proxy" >&2
        fi
    fi
fi

# ------------------------------------------------------------------------------
# AI Keys Forwarding (Appended AFTER --clearenv)
# ------------------------------------------------------------------------------
if [ "$ALLOW_NET" = true ]; then
    AI_KEYS=(
        "ANTHROPIC_API_KEY"
        "OPENAI_API_KEY"
        "GEMINI_API_KEY"
        "DEEPSEEK_API_KEY"
        "MISTRAL_API_KEY"
        "GROQ_API_KEY"
    )
    for key in "${AI_KEYS[@]}"; do
        if [ -n "${!key:-}" ]; then
            BWRAP_ENV+=("--setenv" "$key" "${!key}")
        fi
    done
    # Forward any Antigravity-specific environment variables
    for var in $(env | grep -E '^ANTIGRAVITY_' | cut -d= -f1); do
        BWRAP_ENV+=("--setenv" "$var" "${!var}")
    done
fi

# ------------------------------------------------------------------------------
# Execution
# ------------------------------------------------------------------------------
exec bwrap "${BWRAP_ARGS[@]}" "${BWRAP_ENV[@]}" "${COMMAND[@]}" || EXIT_CODE=$?
exit "${EXIT_CODE:-0}"