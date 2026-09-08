#!/usr/bin/env bash
# ==============================================================================
# Security-Hardened Bubblewrap Sandbox for AI Coding Agents
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Default Settings & State
# ------------------------------------------------------------------------------
ALLOW_NET=false
ALLOW_NET_FILTERED=false
WHITELIST_FILE=""
TARGET_DIR="$(pwd)"
SELECTED_PROFILES=()
COMMAND=()

# Resolve canonical directory of the script (following symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
DEFAULT_PROFILES_FILE="$SCRIPT_DIR/profiles.conf"
PROFILES_EXAMPLE="$SCRIPT_DIR/profiles.example.conf"
PROFILES_FILE="$DEFAULT_PROFILES_FILE"

DEFAULT_WHITELIST="$SCRIPT_DIR/allowed-domains.txt"
WHITELIST_EXAMPLE="$SCRIPT_DIR/allowed-domains.example.txt"

# Data structures for profile discovery & configuration
AVAILABLE_PROFILES=()
declare -A PROFILE_DESCRIPTIONS=()
SELECTED_ENV_PATTERNS=()

# Data structures for profile mounts & permissions
declare -A MOUNT_PERMS=()       # Path -> "ro" | "rw" (Last profile wins)
ORDERED_MOUNT_PATHS=()          # Preserves registration order
ENABLE_FILTERED_DBUS=false      # Enabled if requested by any active profile

# Cleanup tracker for proxy and sandbox processes
PROXY_PID=""
PROXY_DIR=""
NET_PROXY_PID=""
NET_PROXY_DIR=""
SANDBOX_RUNTIME_DIR=""
BWRAP_PID=""

cleanup() {
    local sig="${1:-0}"
    trap - EXIT INT TERM HUP

    if [ -n "$BWRAP_PID" ]; then
        kill "$BWRAP_PID" 2>/dev/null || true
        wait "$BWRAP_PID" 2>/dev/null || true
        BWRAP_PID=""
    fi

    if [ -n "$PROXY_PID" ]; then
        kill "$PROXY_PID" 2>/dev/null || true
        wait "$PROXY_PID" 2>/dev/null || true
        PROXY_PID=""
    fi

    if [ -n "$PROXY_DIR" ] && [ -d "$PROXY_DIR" ]; then
        rm -rf "$PROXY_DIR"
        PROXY_DIR=""
    fi

    if [ -n "$NET_PROXY_PID" ]; then
        kill "$NET_PROXY_PID" 2>/dev/null || true
        wait "$NET_PROXY_PID" 2>/dev/null || true
        NET_PROXY_PID=""
    fi

    if [ -n "$NET_PROXY_DIR" ] && [ -d "$NET_PROXY_DIR" ]; then
        rm -rf "$NET_PROXY_DIR"
        NET_PROXY_DIR=""
    fi

    if [ -n "$SANDBOX_RUNTIME_DIR" ] && [ -d "$SANDBOX_RUNTIME_DIR" ]; then
        rm -rf "$SANDBOX_RUNTIME_DIR"
        SANDBOX_RUNTIME_DIR=""
    fi

    if [ "$sig" -ne 0 ]; then
        kill -s "$sig" $$ 2>/dev/null || exit $((128 + sig))
    fi
}
trap 'cleanup 0' EXIT
trap 'cleanup 2' INT
trap 'cleanup 15' TERM
trap 'cleanup 1' HUP

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
# Path Expansion Helper
# ------------------------------------------------------------------------------
expand_path() {
    local p="$1"
    if [[ "$p" == "~" ]]; then
        p="$HOME"
    elif [[ "$p" == "~/"* ]]; then
        p="$HOME/${p#\~/}"
    elif [[ "$p" == "\$HOME"* ]]; then
        p="$HOME${p#\$HOME}"
    fi
    printf "%s\n" "$p"
}

# ------------------------------------------------------------------------------
# Configuration Initialization & Profile Discovery (100% Native Bash)
# ------------------------------------------------------------------------------
ensure_configs() {
    local explicit_init="${1:-false}"
    local created_any=false

    if [ ! -f "$DEFAULT_PROFILES_FILE" ] && [ -f "$PROFILES_EXAMPLE" ]; then
        cp "$PROFILES_EXAMPLE" "$DEFAULT_PROFILES_FILE"
        echo "[+] Initialized configuration: $DEFAULT_PROFILES_FILE"
        created_any=true
    fi

    if [ ! -f "$DEFAULT_WHITELIST" ] && [ -f "$WHITELIST_EXAMPLE" ]; then
        cp "$WHITELIST_EXAMPLE" "$DEFAULT_WHITELIST"
        echo "[+] Initialized whitelist: $DEFAULT_WHITELIST"
        created_any=true
    fi

    if [ "$explicit_init" = true ]; then
        if [ "$created_any" = false ]; then
            echo "[i] Configuration files already exist:"
            echo "    Profiles:  $DEFAULT_PROFILES_FILE"
            echo "    Whitelist: $DEFAULT_WHITELIST"
        else
            echo "[✔] Initialization complete."
            echo "    You can now customize your profiles in '$DEFAULT_PROFILES_FILE'"
            echo "    and your domain whitelist in '$DEFAULT_WHITELIST'."
        fi
    fi
}

load_available_profiles() {
    local file="$1"
    AVAILABLE_PROFILES=()
    PROFILE_DESCRIPTIONS=()

    if [ ! -f "$file" ]; then
        AVAILABLE_PROFILES=("dev-tools" "antigravity" "claude" "openai" "deepseek" "mistral" "groq" "none")
        PROFILE_DESCRIPTIONS["dev-tools"]="Mounts host user toolchains (~/.cargo/bin, ~/.nvm, ~/.pyenv, etc.) [Read-Only]"
        PROFILE_DESCRIPTIONS["antigravity"]="Mounts ~/.antigravity, ~/.gemini [RW], Playwright cache [RO], and filters D-Bus Keyring"
        PROFILE_DESCRIPTIONS["claude"]="Mounts ~/.claude, ~/.claude.json, and ~/.config/claude [Read-Write]"
        PROFILE_DESCRIPTIONS["openai"]="Forwards OpenAI API credentials"
        PROFILE_DESCRIPTIONS["deepseek"]="Forwards DeepSeek API credentials"
        PROFILE_DESCRIPTIONS["mistral"]="Forwards Mistral API credentials"
        PROFILE_DESCRIPTIONS["groq"]="Forwards Groq API credentials"
        PROFILE_DESCRIPTIONS["none"]="No extra mounts or environment variables applied (default)"
        return 0
    fi

    local current_sec=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^# || "$line" =~ ^\; ]] && continue

        if [[ "$line" =~ ^\[([a-zA-Z0-9_.-]+)\]$ ]]; then
            current_sec="${BASH_REMATCH[1]}"
            AVAILABLE_PROFILES+=("$current_sec")
            PROFILE_DESCRIPTIONS["$current_sec"]=""
        elif [ -n "$current_sec" ]; then
            if [[ "$line" =~ ^description[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                PROFILE_DESCRIPTIONS["$current_sec"]="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$file"
}

# ------------------------------------------------------------------------------
# Profile Application (Config-Driven with Fallback)
# ------------------------------------------------------------------------------
apply_profile_from_config() {
    local profile="$1"
    local file="$2"
    local in_section=false

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^# || "$line" =~ ^\; ]] && continue

        if [[ "$line" =~ ^\[([a-zA-Z0-9_.-]+)\]$ ]]; then
            if [ "${BASH_REMATCH[1]}" = "$profile" ]; then
                in_section=true
            else
                if [ "$in_section" = true ]; then
                    break
                fi
            fi
            continue
        fi

        if [ "$in_section" = true ]; then
            if [[ "$line" =~ ^mount[[:space:]]*=[[:space:]]*([a-zA-Z]+):(.*)$ ]]; then
                local mode="${BASH_REMATCH[1]}"
                local raw_path="${BASH_REMATCH[2]}"
                raw_path="${raw_path#"${raw_path%%[![:space:]]*}"}"
                raw_path="${raw_path%"${raw_path##*[![:space:]]}"}"
                local exp_path
                exp_path="$(expand_path "$raw_path")"
                set_mount "$mode" "$exp_path"
            elif [[ "$line" =~ ^env[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                local env_pat="${BASH_REMATCH[1]}"
                env_pat="${env_pat#"${env_pat%%[![:space:]]*}"}"
                env_pat="${env_pat%"${env_pat##*[![:space:]]}"}"
                SELECTED_ENV_PATTERNS+=("$env_pat")
            elif [[ "$line" =~ ^filtered_dbus[[:space:]]*=[[:space:]]*(true|yes|1)$ ]]; then
                ENABLE_FILTERED_DBUS=true
            fi
        fi
    done < "$file"
}

apply_profile_fallback() {
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
            set_mount "ro" "$HOME/.cache/ms-playwright-go"
            set_mount "ro" "$HOME/.cache/ms-playwright"
            SELECTED_ENV_PATTERNS+=("GEMINI_API_KEY" "ANTIGRAVITY_*")
            ENABLE_FILTERED_DBUS=true
            ;;
        claude)
            set_mount "rw" "$HOME/.claude"
            set_mount "rw" "$HOME/.claude.json"
            set_mount "rw" "$HOME/.config/claude"
            set_mount "rw" "$HOME/.local/share/claude"
            set_mount "rw" "$HOME/.local/state/claude"
            SELECTED_ENV_PATTERNS+=("ANTHROPIC_API_KEY")
            ;;
        openai)
            SELECTED_ENV_PATTERNS+=("OPENAI_API_KEY")
            ;;
        deepseek)
            SELECTED_ENV_PATTERNS+=("DEEPSEEK_API_KEY")
            ;;
        mistral)
            SELECTED_ENV_PATTERNS+=("MISTRAL_API_KEY")
            ;;
        groq)
            SELECTED_ENV_PATTERNS+=("GROQ_API_KEY")
            ;;
        none)
            ;;
    esac
}

apply_profile() {
    local profile="$1"
    local found=false
    for p in "${AVAILABLE_PROFILES[@]}"; do
        if [ "$p" = "$profile" ]; then
            found=true
            break
        fi
    done

    if [ "$found" = false ]; then
        echo "Error: Unknown profile '$profile'." >&2
        echo "Available profiles: ${AVAILABLE_PROFILES[*]}" >&2
        exit 1
    fi

    if [ -f "$PROFILES_FILE" ]; then
        apply_profile_from_config "$profile" "$PROFILES_FILE"
    else
        apply_profile_fallback "$profile"
    fi
}

# ------------------------------------------------------------------------------
# Help & Usage
# ------------------------------------------------------------------------------
list_profiles() {
    echo "Available Agent Profiles (from $(basename "$PROFILES_FILE")):"
    for p in "${AVAILABLE_PROFILES[@]}"; do
        local desc="${PROFILE_DESCRIPTIONS["$p"]:-No description provided}"
        printf "  %-14s %s\n" "$p" "$desc"
    done
    cat <<EOF

Note: You can pass multiple profiles (e.g. -p dev-tools -p antigravity).
      If path permissions conflict, the last profile specified takes precedence.
      Profiles and forwarded environment variables are configured in:
      $PROFILES_FILE
EOF
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [-- COMMAND [ARGS...]]

A security-hardened Bubblewrap sandbox for AI coding agents.

Options:
  -p, --profile NAME       Permission profile (Can be repeated or comma-separated)
      --list-profiles      List available permission profiles and descriptions
  -c, --config PATH        Path to profiles configuration file (Default: profiles.conf)
      --init               Initialize profiles.conf and allowed-domains.txt from templates and exit
  -n, --net                Allow unrestricted network access (Default: OFF / isolated)
  -nf, --net-filtered      Allow domain-filtered network access via strict proxy
  -w, --whitelist PATH     Domain whitelist file (Default: allowed-domains.txt)
  -d, --dir PATH           Target workspace directory (Default: current directory)
  -h, --help               Show this help message

Examples:
  $(basename "$0") --init
  $(basename "$0") --list-profiles
  $(basename "$0") -p dev-tools,antigravity -nf -- agy
  $(basename "$0") -p dev-tools,claude -nf -- claude
  $(basename "$0") -p dev-tools,claude -nf -w ./my-domains.txt -- claude
  $(basename "$0") -p dev-tools --net -- cargo build
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Early Option Handling & Profile Config Loading
# ------------------------------------------------------------------------------
# Handle --init early before full option parsing
for arg in "$@"; do
    if [ "$arg" = "--init" ]; then
        ensure_configs true
        exit 0
    fi
done

# Pre-scan arguments for custom config file
for ((i=1; i<=$#; i++)); do
    case "${!i}" in
        -c|--config)
            next_idx=$((i + 1))
            if [ $next_idx -le $# ]; then
                PROFILES_FILE="${!next_idx}"
            fi
            ;;
    esac
done

# If using default profiles file, auto-create if missing
if [ "$PROFILES_FILE" = "$DEFAULT_PROFILES_FILE" ]; then
    ensure_configs false
fi

if [ "$PROFILES_FILE" != "$DEFAULT_PROFILES_FILE" ] && [ ! -f "$PROFILES_FILE" ]; then
    echo "Error: Profiles configuration file not found: '$PROFILES_FILE'" >&2
    exit 1
fi

# Load available profiles and their descriptions
load_available_profiles "$PROFILES_FILE"

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
    -c | --config)
        PROFILES_FILE="$2"
        shift 2
        ;;
    --init)
        ensure_configs true
        exit 0
        ;;
    -n | --net)
        ALLOW_NET=true
        shift
        ;;
    -nf | --net-filtered)
        ALLOW_NET_FILTERED=true
        shift
        ;;
    -w | --whitelist)
        WHITELIST_FILE="$2"
        shift 2
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

# Validate network exclusivity
if [ "$ALLOW_NET" = true ] && [ "$ALLOW_NET_FILTERED" = true ]; then
    echo "Error: Cannot specify both '--net' (unrestricted) and '--net-filtered' (domain-filtered)." >&2
    exit 1
fi

if [ "$ALLOW_NET_FILTERED" = true ]; then
    WHITELIST_FILE="${WHITELIST_FILE:-$DEFAULT_WHITELIST}"
    if [ ! -f "$WHITELIST_FILE" ]; then
        echo "Error: Whitelist file not found: '$WHITELIST_FILE'" >&2
        exit 1
    fi
fi

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

# Ephemeral sandbox runtime files (clean /etc/hosts with IPv4 & IPv6 loopback)
SANDBOX_RUNTIME_DIR="$(mktemp -d /tmp/bwrap-rt-XXXXXX)"
chmod 0755 "$SANDBOX_RUNTIME_DIR"

HOST_NAME="$(hostname 2>/dev/null || echo "sandbox")"
cat <<EOF > "$SANDBOX_RUNTIME_DIR/hosts"
127.0.0.1 localhost $HOST_NAME
::1 localhost ip6-localhost ip6-loopback
EOF
chmod 0644 "$SANDBOX_RUNTIME_DIR/hosts"

# Essential system configuration (read-only)
BWRAP_ARGS+=(
    "--ro-bind" "$SANDBOX_RUNTIME_DIR/hosts" "/etc/hosts"
    "--ro-bind-try" "/etc/nsswitch.conf" "/etc/nsswitch.conf"
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
GIT_CONFIG_OVERRIDE="'core.hooksPath=/dev/null'"
if [ "$ALLOW_NET_FILTERED" = true ]; then
    GIT_CONFIG_OVERRIDE="$GIT_CONFIG_OVERRIDE 'url.https://github.com/.insteadOf=git@github.com:' 'url.https://gitlab.com/.insteadOf=git@gitlab.com:'"
fi

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
    "--setenv" "GIT_CONFIG_PARAMETERS" "$GIT_CONFIG_OVERRIDE"
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
                --talk=org.gnome.keyring </dev/null &
            PROXY_PID=$!

            # Wait until proxy socket is created to prevent race conditions
            while [ ! -S "$PROXY_BUS" ]; do
                if ! kill -0 "$PROXY_PID" 2>/dev/null; then
                    echo "Error: Failed to start xdg-dbus-proxy." >&2
                    exit 1
                fi
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
# Secure Domain-Filtered Network Proxy (Option B)
# ------------------------------------------------------------------------------
SANDBOX_PROXY_PORT=18080
SANDBOX_NET_DIR=""
SANDBOX_NET_SOCK=""
SANDBOX_NET_RELAY=""

if [ "$ALLOW_NET_FILTERED" = true ]; then
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Error: 'python3' is required for network filtering proxy." >&2
        exit 1
    fi

    USER_UID="$(id -u)"
    NET_PROXY_DIR="$(mktemp -d /tmp/bwrap-net-XXXXXX)"
    chmod 0700 "$NET_PROXY_DIR"
    NET_PROXY_SOCK="$NET_PROXY_DIR/proxy.sock"

    # Start domain-filtering proxy on the host listening directly on Unix socket
    python3 "$SCRIPT_DIR/net-proxy.py" --proxy "$NET_PROXY_SOCK" "$WHITELIST_FILE" </dev/null >/dev/null 2>&1 &
    NET_PROXY_PID=$!

    # Wait until proxy socket is created to prevent race conditions
    while [ ! -S "$NET_PROXY_SOCK" ]; do
        if ! kill -0 "$NET_PROXY_PID" 2>/dev/null; then
            echo "Error: Failed to start domain-filtering network proxy." >&2
            exit 1
        fi
        sleep 0.02
    done

    # Mount proxy socket and relay helper inside sandbox
    SANDBOX_NET_DIR="/run/user/$USER_UID/net"
    SANDBOX_NET_SOCK="$SANDBOX_NET_DIR/proxy.sock"
    SANDBOX_NET_RELAY="$SANDBOX_NET_DIR/net-proxy.py"

    BWRAP_ARGS+=(
        "--dir" "/run/user/$USER_UID"
        "--dir" "$SANDBOX_NET_DIR"
        "--ro-bind" "$NET_PROXY_SOCK" "$SANDBOX_NET_SOCK"
        "--ro-bind" "$SCRIPT_DIR/net-proxy.py" "$SANDBOX_NET_RELAY"
    )

    BWRAP_ENV+=(
        "--setenv" "HTTP_PROXY" "http://127.0.0.1:$SANDBOX_PROXY_PORT"
        "--setenv" "HTTPS_PROXY" "http://127.0.0.1:$SANDBOX_PROXY_PORT"
        "--setenv" "ALL_PROXY" "http://127.0.0.1:$SANDBOX_PROXY_PORT"
        "--setenv" "http_proxy" "http://127.0.0.1:$SANDBOX_PROXY_PORT"
        "--setenv" "https_proxy" "http://127.0.0.1:$SANDBOX_PROXY_PORT"
        "--setenv" "NO_PROXY" "localhost,127.0.0.1,::1"
        "--setenv" "no_proxy" "localhost,127.0.0.1,::1"
    )
fi

# ------------------------------------------------------------------------------
# Per-Profile Environment Variable Forwarding (Appended AFTER --clearenv)
# ------------------------------------------------------------------------------
# Only variables explicitly declared via 'env' in selected profiles are forwarded.
# Wildcards (e.g. ANTIGRAVITY_*) are dynamically expanded against exported variables.
declare -A FORWARDED_ENV_VARS=()

for pat in "${SELECTED_ENV_PATTERNS[@]}"; do
    if [[ "$pat" == *"*"* ]]; then
        prefix="${pat%%\**}"
        for var in $(compgen -v "$prefix" 2>/dev/null || true); do
            if [[ "$var" == $pat ]]; then
                if [ -z "${FORWARDED_ENV_VARS["$var"]:-}" ]; then
                    if [ -n "${!var:-}" ] && [[ "$(declare -p "$var" 2>/dev/null || true)" =~ ^declare\ -[a-z]*x ]]; then
                        FORWARDED_ENV_VARS["$var"]=1
                        BWRAP_ENV+=("--setenv" "$var" "${!var}")
                    fi
                fi
            fi
        done
    else
        if [ -z "${FORWARDED_ENV_VARS["$pat"]:-}" ]; then
            if [ -n "${!pat:-}" ] && [[ "$(declare -p "$pat" 2>/dev/null || true)" =~ ^declare\ -[a-z]*x ]]; then
                FORWARDED_ENV_VARS["$pat"]=1
                BWRAP_ENV+=("--setenv" "$pat" "${!pat}")
            fi
        fi
    fi
done

# ------------------------------------------------------------------------------
# Execution
# ------------------------------------------------------------------------------
if [ "$ALLOW_NET_FILTERED" = true ]; then
    INNER_WRAPPER='
        if command -v socat >/dev/null 2>&1; then
            socat TCP-LISTEN:'"$SANDBOX_PROXY_PORT"',bind=127.0.0.1,fork UNIX-CONNECT:"'"$SANDBOX_NET_SOCK"'" >/dev/null 2>&1 &
        else
            python3 "'"$SANDBOX_NET_RELAY"'" --relay '"$SANDBOX_PROXY_PORT"' "'"$SANDBOX_NET_SOCK"'" >/dev/null 2>&1 &
        fi
        RELAY_PID=$!
        while ! (echo > /dev/tcp/127.0.0.1/'"$SANDBOX_PROXY_PORT"') 2>/dev/null; do
            if ! kill -0 "$RELAY_PID" 2>/dev/null; then
                echo "Error: Failed to start sandbox network relay." >&2
                exit 1
            fi
            sleep 0.01
        done
        exec "$@"
    '
    FINAL_CMD=("/bin/bash" "-c" "$INNER_WRAPPER" "--" "${COMMAND[@]}")
else
    FINAL_CMD=("${COMMAND[@]}")
fi

EXIT_CODE=0
bwrap "${BWRAP_ARGS[@]}" "${BWRAP_ENV[@]}" "${FINAL_CMD[@]}" <&0 &
BWRAP_PID=$!
wait "$BWRAP_PID" 2>/dev/null || EXIT_CODE=$?
BWRAP_PID=""

exit "${EXIT_CODE:-0}"
