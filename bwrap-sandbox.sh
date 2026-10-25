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
ALLOW_GUI=false                # Enabled by --gui or by any active profile ('gui = true')
ALLOW_USERNS=false             # Enabled by --allow-userns or by any active profile ('allow_userns = true')
FORWARD_TERMINAL_ENV=false     # Enabled by --terminal-env or by any active profile ('terminal_env = true')
RESOLVE_SYMLINKS=""            # "" (disabled) | "ro" | "rw"
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

# ------------------------------------------------------------------------------
# Process Display Name (argv[0]) & Early Execution Setup
# ------------------------------------------------------------------------------
# Determine the target command name from arguments
TARGET_CMD_NAME=""
found_sep=false
is_info_call=false

for arg in "$@"; do
    if [ "$arg" = "--" ]; then
        found_sep=true
        continue
    fi
    if [ "$found_sep" = true ]; then
        if [ -z "$TARGET_CMD_NAME" ]; then
            TARGET_CMD_NAME="$(basename "$arg")"
        fi
        continue
    fi
    case "$arg" in
        -h|--help|--list-profiles|--init)
            is_info_call=true
            ;;
    esac
done

if [ "$is_info_call" = false ]; then
    if [ -z "$TARGET_CMD_NAME" ]; then
        TARGET_CMD_NAME="$(basename "${SHELL:-bash}")"
    fi

    # Update process display name (argv[0]) via native Bash exec -a
    if [ -z "${_BWRAP_REEXEC:-}" ] && [ "$TARGET_CMD_NAME" != "bash" ]; then
        export _BWRAP_REEXEC=1
        exec -a "$TARGET_CMD_NAME" "${BASH:-/bin/bash}" "$SOURCE" "$@"
    fi
fi
unset _BWRAP_REEXEC

DEFAULT_PROFILES_FILE="$SCRIPT_DIR/profiles.conf"
PROFILES_EXAMPLE="$SCRIPT_DIR/profiles.example.conf"
PROFILES_FILE="$DEFAULT_PROFILES_FILE"

DEFAULT_WHITELIST="$SCRIPT_DIR/allowed-domains.txt"
WHITELIST_EXAMPLE="$SCRIPT_DIR/allowed-domains.example.txt"

DEFAULT_SYMLINK_BLOCKLIST="$SCRIPT_DIR/symlink-blocklist.txt"
SYMLINK_BLOCKLIST_EXAMPLE="$SCRIPT_DIR/symlink-blocklist.example.txt"

# Data structures for profile discovery & configuration
AVAILABLE_PROFILES=()
declare -A PROFILE_DESCRIPTIONS=()
SELECTED_ENV_PATTERNS=()
SELECTED_SETENV=()             # Fixed "NAME=VALUE" assignments declared via 'setenv'

# Data structures for profile mounts & permissions
declare -A MOUNT_PERMS=()       # Path -> "ro" | "rw" | "tmpfs" (Last profile wins)
ORDERED_MOUNT_PATHS=()          # Preserves registration order
ENABLE_DBUS_AUTH=false          # Enabled if requested by any active profile (Keyring/Secrets)
ENABLE_DBUS_NOTIFICATIONS=false # Enabled if requested by any active profile (Desktop notifications)
declare -A PROTECTED_SYMLINKS=() # Protected symlink path -> original target (verified and restored on exit)

# ------------------------------------------------------------------------------
# Logging (--log-level error|warn|info|debug, Default: info)
# Errors are always printed. All log output goes to stderr.
# ------------------------------------------------------------------------------
LOG_LEVEL=2 # 0=error 1=warn 2=info 3=debug

# Usage: set_log_level <name> (returns 1 on invalid level)
set_log_level() {
    case "$1" in
        error) LOG_LEVEL=0 ;;
        warn) LOG_LEVEL=1 ;;
        info) LOG_LEVEL=2 ;;
        debug) LOG_LEVEL=3 ;;
        *) return 1 ;;
    esac
}

log_warn() {
    if [ "$LOG_LEVEL" -ge 1 ]; then echo "Warning: $*" >&2; fi
}

# Info messages carry their own prefix ('[+]', '[i]')
log_info() {
    if [ "$LOG_LEVEL" -ge 2 ]; then echo "$*" >&2; fi
}

log_debug() {
    if [ "$LOG_LEVEL" -ge 3 ]; then echo "[debug] $*" >&2; fi
}

# Cleanup tracker for proxy and sandbox processes
PROXY_PID=""
PROXY_DIR=""
NET_PROXY_PID=""
NET_PROXY_DIR=""
SANDBOX_RUNTIME_DIR=""
BWRAP_PID=""
TITLE_RESTORE_NEEDED=false

# Symlinks cannot be mounted read-only (bwrap follows them) and stay replaceable through their
# writable parent directory, so protected symlinks are verified after the sandbox exits. A replaced
# entry is preserved as '<path>.sandbox-replaced.<timestamp>' for inspection and the link is restored.
restore_protected_symlinks() {
    local link original current backup
    for link in "${!PROTECTED_SYMLINKS[@]}"; do
        original="${PROTECTED_SYMLINKS["$link"]}"
        if [ -L "$link" ] && [ "$(readlink "$link")" = "$original" ]; then
            log_debug "Protected symlink unchanged: $link -> $original"
            continue
        fi

        if [ -e "$link" ] || [ -L "$link" ]; then
            current="$( [ -L "$link" ] && echo "symlink to '$(readlink "$link")'" || echo "regular $( [ -d "$link" ] && echo directory || echo file)" )"
            backup="$link.sandbox-replaced.$(date +%Y%m%d-%H%M%S)"
            mv -- "$link" "$backup"
            log_warn "Protected symlink '$link' was replaced inside the sandbox ($current). Restored link to '$original'; the replacement was kept at '$backup'."
        else
            log_warn "Protected symlink '$link' was removed inside the sandbox. Restored link to '$original'."
        fi
        ln -s -- "$original" "$link"
    done
}

cleanup() {
    local sig="${1:-0}"
    trap - EXIT INT TERM HUP WINCH

    if [ "$TITLE_RESTORE_NEEDED" = true ] && { [ -t 1 ] || [ -t 2 ]; }; then
        # Restore terminal window title from stack
        printf '\033[23;0t' 2>/dev/null || true
        if [ -n "${TMUX:-}" ]; then
            # Re-enable tmux automatic window renaming
            printf '\033k\033\\' 2>/dev/null || true
        fi
        TITLE_RESTORE_NEEDED=false
    fi

    if [ -n "$BWRAP_PID" ]; then
        kill "$BWRAP_PID" 2>/dev/null || true
        wait "$BWRAP_PID" 2>/dev/null || true
        BWRAP_PID=""
    fi

    # Runs only after the sandbox has exited, so the agent cannot race the restoration
    restore_protected_symlinks

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

# ------------------------------------------------------------------------------
# Terminal Window Resize Signal Forwarder (SIGWINCH)
# Relays window geometry change signals from the host terminal to the sandboxed
# process group without breaking session isolation (--new-session / anti-TIOCSTI).
# ------------------------------------------------------------------------------
forward_winch() {
    if [ -n "${BWRAP_PID:-}" ]; then
        local children=""
        if [ -f "/proc/$BWRAP_PID/task/$BWRAP_PID/children" ]; then
            children="$(cat "/proc/$BWRAP_PID/task/$BWRAP_PID/children" 2>/dev/null || true)"
        fi
        if [ -z "$children" ] && command -v pgrep >/dev/null 2>&1; then
            children="$(pgrep -P "$BWRAP_PID" 2>/dev/null || true)"
        fi
        for cpid in $children; do
            kill -WINCH "-$cpid" 2>/dev/null || kill -WINCH "$cpid" 2>/dev/null || true
            if command -v pkill >/dev/null 2>&1; then
                pkill -WINCH -P "$cpid" 2>/dev/null || true
            fi
        done
        if command -v pkill >/dev/null 2>&1; then
            pkill -WINCH -P "$BWRAP_PID" 2>/dev/null || true
        fi
    fi
}

trap 'cleanup 0' EXIT
trap 'cleanup 2' INT
trap 'cleanup 15' TERM
trap 'cleanup 1' HUP
trap 'forward_winch' WINCH

# ------------------------------------------------------------------------------
# Mount Helper Function
# ------------------------------------------------------------------------------
# Usage: set_mount <"ro"|"rw"|"tmpfs"> <path>
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

# Usage: protect_path <path>
# Mounts a path read-only, even when it lives inside a read-write mount (e.g. hooks in ~/.claude).
# A missing path would otherwise be skipped and could then be created by the agent, so an empty
# placeholder is created on the host first (directory if the path ends with '/', file otherwise;
# '{}' for .json files). Placeholders are only created when the parent directory already exists.
protect_path() {
    local path="$1"
    local is_dir=false
    if [[ "$path" == */ ]]; then
        is_dir=true
        path="${path%/}"
    fi

    # bwrap follows a symlink destination, so the link itself cannot be mounted read-only: its real
    # target is protected instead and the link is verified (and restored) on exit
    if [ -L "$path" ]; then
        local link_target
        PROTECTED_SYMLINKS["$path"]="$(readlink "$path")"
        link_target="$(realpath -e "$path" 2>/dev/null || true)"
        log_debug "Cannot mount symlink '$path' read-only (bwrap follows it); protecting its target '${link_target:-<missing>}' and verifying the link on exit."
        if [ -n "$link_target" ]; then
            set_mount "ro" "$link_target"
        fi
        return 0
    fi

    if [ ! -e "$path" ] && [ ! -L "$path" ] && [ -d "$(dirname "$path")" ]; then
        if [ "$is_dir" = true ]; then
            mkdir "$path"
        elif [[ "$path" == *.json ]]; then
            echo '{}' > "$path"
        else
            : > "$path"
        fi
        log_info "[+] Created read-only placeholder: $path"
    fi
    set_mount "ro" "$path"
}

# Usage: mount_tmpfs <path>
# Hides a directory behind an empty, writable tmpfs inside the sandbox, e.g. a registry that tools must
# write to inside a read-only mount (~/.cache/ms-playwright/b). Nothing written there reaches the host.
# bwrap cannot create a mount point inside a read-only mount, so a missing directory is created on the
# host first (only if its parent directory exists).
mount_tmpfs() {
    local path="${1%/}"
    if [ ! -e "$path" ] && [ ! -L "$path" ] && [ -d "$(dirname "$path")" ]; then
        mkdir "$path"
        log_info "[+] Created tmpfs mount point: $path"
    fi
    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -d "$path" ]; }; then
        log_warn "Cannot mount tmpfs on '$path': not a directory. Skipping."
        return 0
    fi
    set_mount "tmpfs" "$path"
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
    elif [[ "$p" == "\${HOME}"* ]]; then
        p="$HOME${p#\$\{HOME\}}"
    fi
    # If path is relative, resolve it against TARGET_DIR to ensure valid absolute sandbox binds
    if [[ "$p" != /* ]]; then
        p="$(cd "${TARGET_DIR:-$(pwd)}" 2>/dev/null && realpath -m "$p" 2>/dev/null || realpath -m "$p")"
    fi
    printf "%s\n" "$p"
}

# ------------------------------------------------------------------------------
# Configuration Initialization & Profile Discovery (100% Native Bash)
# ------------------------------------------------------------------------------
ensure_configs() {
    local explicit_init="${1:-false}"
    local created_any=false
    # Explicit --init reports to stdout; automatic initialization respects the log level
    local report="log_info"
    [ "$explicit_init" = true ] && report="echo"

    if [ ! -f "$DEFAULT_PROFILES_FILE" ] && [ -f "$PROFILES_EXAMPLE" ]; then
        cp "$PROFILES_EXAMPLE" "$DEFAULT_PROFILES_FILE"
        $report "[+] Initialized configuration: $DEFAULT_PROFILES_FILE"
        created_any=true
    fi

    if [ ! -f "$DEFAULT_WHITELIST" ] && [ -f "$WHITELIST_EXAMPLE" ]; then
        cp "$WHITELIST_EXAMPLE" "$DEFAULT_WHITELIST"
        $report "[+] Initialized whitelist: $DEFAULT_WHITELIST"
        created_any=true
    fi

    if [ ! -f "$DEFAULT_SYMLINK_BLOCKLIST" ] && [ -f "$SYMLINK_BLOCKLIST_EXAMPLE" ]; then
        cp "$SYMLINK_BLOCKLIST_EXAMPLE" "$DEFAULT_SYMLINK_BLOCKLIST"
        $report "[+] Initialized symlink blocklist: $DEFAULT_SYMLINK_BLOCKLIST"
        created_any=true
    fi

    if [ "$explicit_init" = true ]; then
        if [ "$created_any" = false ]; then
            echo "[i] Configuration files already exist:"
            echo "    Profiles:  $DEFAULT_PROFILES_FILE"
            echo "    Whitelist: $DEFAULT_WHITELIST"
            echo "    Symlink blocklist: $DEFAULT_SYMLINK_BLOCKLIST"
        else
            echo "[✔] Initialization complete."
            echo "    You can now customize your profiles in '$DEFAULT_PROFILES_FILE',"
            echo "    your domain whitelist in '$DEFAULT_WHITELIST'"
            echo "    and your symlink blocklist in '$DEFAULT_SYMLINK_BLOCKLIST'."
        fi
    fi
}

load_available_profiles() {
    local file="$1"
    AVAILABLE_PROFILES=()
    PROFILE_DESCRIPTIONS=()

    if [ ! -f "$file" ]; then
        AVAILABLE_PROFILES=("dev-tools" "antigravity" "claude" "openai" "deepseek" "mistral" "groq" "none")
        PROFILE_DESCRIPTIONS["dev-tools"]="Mounts host user toolchains (~/.cargo/bin, ~/.nvm, ~/.pyenv, mise, etc.) [Read-Only]"
        PROFILE_DESCRIPTIONS["antigravity"]="Mounts ~/.antigravity, ~/.antigravity-ide, ~/.gemini, configs and caches [RW], agy binary, Chrome and Playwright [RO], and filters D-Bus Keyring/Notifications"
        PROFILE_DESCRIPTIONS["claude"]="Mounts ~/.claude, ~/.claude.json and Claude Code installation [RW], Playwright cache and Google Chrome [RO]"
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

        if [[ "$line" =~ ^\[([a-zA-Z0-9_.-]+(:[a-zA-Z0-9_.-]+)?)\]$ ]]; then
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

        if [[ "$line" =~ ^\[([a-zA-Z0-9_.-]+(:[a-zA-Z0-9_.-]+)?)\]$ ]]; then
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
                if [ "$mode" != "ro" ] && [ "$mode" != "rw" ]; then
                    log_warn "Invalid mount mode '$mode' in profile '$profile' (expected 'ro' or 'rw'). Skipping."
                else
                    local exp_path
                    exp_path="$(expand_path "$raw_path")"
                    set_mount "$mode" "$exp_path"
                fi
            elif [[ "$line" =~ ^protect[[:space:]]*=[[:space:]]*(.+)$ ]]; then
                local protect_raw="${BASH_REMATCH[1]}"
                local protect_exp
                protect_exp="$(expand_path "${protect_raw%/}")"
                # expand_path drops the trailing slash that marks directory placeholders
                [[ "$protect_raw" == */ ]] && protect_exp="$protect_exp/"
                protect_path "$protect_exp"
            elif [[ "$line" =~ ^tmpfs[[:space:]]*=[[:space:]]*(.+)$ ]]; then
                mount_tmpfs "$(expand_path "${BASH_REMATCH[1]}")"
            elif [[ "$line" =~ ^env[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                local env_pat="${BASH_REMATCH[1]}"
                env_pat="${env_pat#"${env_pat%%[![:space:]]*}"}"
                env_pat="${env_pat%"${env_pat##*[![:space:]]}"}"
                SELECTED_ENV_PATTERNS+=("$env_pat")
            elif [[ "$line" =~ ^setenv[[:space:]]*=[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
                SELECTED_SETENV+=("${BASH_REMATCH[1]}=${BASH_REMATCH[2]}")
            elif [[ "$line" =~ ^setenv[[:space:]]*= ]]; then
                log_warn "Invalid setenv directive '$line' in profile '$profile' (expected 'setenv = NAME=VALUE'). Skipping."
            elif [[ "$line" =~ ^dbus_auth[[:space:]]*=[[:space:]]*(true|yes|1)$ ]]; then
                ENABLE_DBUS_AUTH=true
            elif [[ "$line" =~ ^dbus_notifications[[:space:]]*=[[:space:]]*(true|yes|1)$ ]]; then
                ENABLE_DBUS_NOTIFICATIONS=true
            elif [[ "$line" =~ ^gui[[:space:]]*=[[:space:]]*(true|yes|1)$ ]]; then
                ALLOW_GUI=true
            elif [[ "$line" =~ ^allow_userns[[:space:]]*=[[:space:]]*(true|yes|1)$ ]]; then
                ALLOW_USERNS=true
            elif [[ "$line" =~ ^terminal_env[[:space:]]*=[[:space:]]*(true|yes|1)$ ]]; then
                FORWARD_TERMINAL_ENV=true
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
            set_mount "ro" "$HOME/.asdf/shims"
            set_mount "ro" "$HOME/.pyenv"
            set_mount "ro" "$HOME/.pyenv/shims"
            set_mount "ro" "$HOME/.rustup"
            set_mount "ro" "$HOME/.fnm"
            set_mount "ro" "$HOME/.volta"
            set_mount "ro" "$HOME/.bun/bin"
            set_mount "ro" "$HOME/go/bin"
            set_mount "ro" "$HOME/.local/share/mise"
            set_mount "ro" "$HOME/.local/share/mise/shims"
            set_mount "ro" "$HOME/.local/share/mise/bin"
            set_mount "ro" "$HOME/.config/mise"
            set_mount "ro" "$HOME/.tool-versions"
            set_mount "ro" "$HOME/.mise.toml"
            set_mount "ro" "$HOME/.local/share/uv"
            ;;
        antigravity)
            set_mount "rw" "$HOME/.antigravity"
            set_mount "rw" "$HOME/.antigravity-ide"
            set_mount "rw" "$HOME/.gemini"
            set_mount "rw" "$HOME/.config/antigravity"
            set_mount "rw" "$HOME/.config/Antigravity"
            set_mount "rw" "$HOME/.config/Antigravity IDE"
            set_mount "rw" "$HOME/.cache/antigravity"
            set_mount "ro" "$HOME/.local/bin/agy"
            set_mount "ro" "$HOME/.cache/ms-playwright-go"
            set_mount "ro" "$HOME/.cache/ms-playwright"
            mount_tmpfs "$HOME/.cache/ms-playwright/b"
            set_mount "ro" "/opt/google/chrome"
            SELECTED_ENV_PATTERNS+=("GEMINI_*" "ANTIGRAVITY_*" "GOOGLE_API_KEY" "GOOGLE_APPLICATION_CREDENTIALS")
            ENABLE_DBUS_AUTH=true
            ENABLE_DBUS_NOTIFICATIONS=true
            ;;
        claude)
            set_mount "rw" "$HOME/.claude"
            set_mount "rw" "$HOME/.claude.json"
            set_mount "rw" "$HOME/.local/state/claude"
            set_mount "rw" "$HOME/.local/share/claude"
            set_mount "ro" "$HOME/.local/bin/claude"
            set_mount "ro" "$HOME/.cache/ms-playwright"
            mount_tmpfs "$HOME/.cache/ms-playwright/b"
            set_mount "ro" "/opt/google/chrome"
            SELECTED_ENV_PATTERNS+=("ANTHROPIC_*" "CLAUDE_CODE_OAUTH_TOKEN")
            ENABLE_DBUS_NOTIFICATIONS=true
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

profile_exists() {
    local p
    for p in "${AVAILABLE_PROFILES[@]}"; do
        [ "$p" = "$1" ] && return 0
    done
    return 1
}

# Variants ('base:variant', e.g. 'claude:strict') inherit their base profile: the base is applied
# first and the variant section is layered on top (last mount registration wins on conflicts).
apply_profile() {
    local profile="$1"

    if ! profile_exists "$profile"; then
        echo "Error: Unknown profile '$profile'." >&2
        echo "Available profiles: ${AVAILABLE_PROFILES[*]}" >&2
        exit 1
    fi

    if [[ "$profile" == *:* ]]; then
        local base="${profile%%:*}"
        if ! profile_exists "$base"; then
            echo "Error: Profile variant '$profile' requires a base profile section [$base]." >&2
            exit 1
        fi
        log_debug "Applying profile '$profile' (inherits '$base')"
        apply_profile_from_config "$base" "$PROFILES_FILE"
        apply_profile_from_config "$profile" "$PROFILES_FILE"
    elif [ -f "$PROFILES_FILE" ]; then
        log_debug "Applying profile '$profile'"
        apply_profile_from_config "$profile" "$PROFILES_FILE"
    else
        log_debug "Applying built-in profile '$profile' (no $(basename "$PROFILES_FILE") found)"
        apply_profile_fallback "$profile"
    fi
}

# ------------------------------------------------------------------------------
# Help & Usage
# ------------------------------------------------------------------------------
list_profiles() {
    echo "Available Agent Profiles (from $(basename "$PROFILES_FILE")):"
    local p v
    for p in "${AVAILABLE_PROFILES[@]}"; do
        [[ "$p" == *:* ]] && continue
        printf "  %-14s %s\n" "$p" "${PROFILE_DESCRIPTIONS["$p"]:-No description provided}"
        # Variants are listed under their base profile
        for v in "${AVAILABLE_PROFILES[@]}"; do
            if [[ "$v" == "$p":* ]]; then
                printf "    %-12s %s\n" ":${v#*:}" "${PROFILE_DESCRIPTIONS["$v"]:-No description provided}"
            fi
        done
    done
    # Variants whose base section is missing (invalid until the base is defined)
    for v in "${AVAILABLE_PROFILES[@]}"; do
        if [[ "$v" == *:* ]] && ! profile_exists "${v%%:*}"; then
            printf "  %-14s %s\n" "$v" "(Invalid: missing base profile [${v%%:*}])"
        fi
    done
    cat <<EOF

Note: You can pass multiple profiles (e.g. -p dev-tools -p antigravity).
      Variants are selected with 'profile:variant' (e.g. -p dev-tools,claude:strict) and
      inherit their base profile, applying their own directives on top.
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
      --init               Initialize profiles.conf, allowed-domains.txt and symlink-blocklist.txt from templates and exit
  -n, --net                Allow unrestricted network access (Default: OFF / isolated)
  -nf, --net-filtered      Allow domain-filtered network access via strict proxy
  -g, --gui                Expose X11/Wayland display and clipboard (Warning: reduces isolation)
      --allow-userns       Allow nested user namespaces, e.g. for Chrome's own sandbox
                           (Warning: exposes more kernel attack surface)
      --terminal-env       Forward host terminal identification and color variables
                           (TERM_PROGRAM, VTE_VERSION, LS_COLORS, TERMINFO, etc.)
      --resolve-symlinks[=ro|rw]
                           Mount targets of workspace symlinks pointing outside the project
                           ('read'/'write' are aliases; Default: ro; paths listed in
                           symlink-blocklist.txt are never mounted)
  -w, --whitelist PATH     Domain whitelist file (Default: allowed-domains.txt)
  -d, --dir PATH           Target workspace directory (Default: current directory)
      --log-level LEVEL    Log verbosity: error, warn, info or debug (Default: info; errors are always shown)
  -h, --help               Show this help message

Examples:
  $(basename "$0") --init
  $(basename "$0") --list-profiles
  $(basename "$0") -p dev-tools,antigravity -nf -g -- agy
  $(basename "$0") -p dev-tools,antigravity -nf -- agy
  $(basename "$0") -p dev-tools,claude -nf -- claude
  $(basename "$0") -p dev-tools,claude:strict -nf -- claude
  $(basename "$0") -p dev-tools,claude -nf -w ./my-domains.txt -- claude
  $(basename "$0") -p dev-tools --net -- cargo build
  $(basename "$0") -p dev-tools,claude -nf --resolve-symlinks -- claude
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Early Option Handling & Profile Config Loading
# ------------------------------------------------------------------------------
# Handle --init early before full option parsing (ignoring anything after --)
for arg in "$@"; do
    if [ "$arg" = "--" ]; then
        break
    fi
    if [ "$arg" = "--init" ]; then
        ensure_configs true
        exit 0
    fi
done

# Pre-scan arguments for custom config file (ignoring anything after --)
for ((i=1; i<=$#; i++)); do
    if [ "${!i}" = "--" ]; then
        break
    fi
    case "${!i}" in
        -c|--config)
            next_idx=$((i + 1))
            if [ $next_idx -le $# ] && [ "${!next_idx}" != "--" ]; then
                PROFILES_FILE="${!next_idx}"
            fi
            ;;
        # Log level is needed before configuration initialization and profile loading
        --log-level|--log-level=*)
            if [ "${!i}" = "--log-level" ]; then
                next_idx=$((i + 1))
                level_name="${!next_idx:-}"
                if [ -z "$level_name" ] || [ "$level_name" = "--" ]; then
                    echo "Error: Option '--log-level' requires an argument." >&2
                    exit 1
                fi
            else
                level_name="${!i#*=}"
            fi
            if ! set_log_level "$level_name"; then
                echo "Error: Invalid log level '$level_name' (expected 'error', 'warn', 'info' or 'debug')." >&2
                exit 1
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
        if [[ $# -lt 2 || "$2" == "--" ]]; then
            echo "Error: Option '$1' requires an argument." >&2
            exit 1
        fi
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
        if [[ $# -lt 2 || "$2" == "--" ]]; then
            echo "Error: Option '$1' requires an argument." >&2
            exit 1
        fi
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
    -g | --gui)
        ALLOW_GUI=true
        shift
        ;;
    --allow-userns)
        ALLOW_USERNS=true
        shift
        ;;
    --terminal-env)
        FORWARD_TERMINAL_ENV=true
        shift
        ;;
    --log-level)
        # Already validated and applied by the pre-scan
        if [[ $# -lt 2 || "$2" == "--" ]]; then
            echo "Error: Option '$1' requires an argument." >&2
            exit 1
        fi
        shift 2
        ;;
    --log-level=*)
        shift
        ;;
    --resolve-symlinks)
        RESOLVE_SYMLINKS="ro"
        shift
        ;;
    --resolve-symlinks=*)
        case "${1#*=}" in
            ro | read) RESOLVE_SYMLINKS="ro" ;;
            rw | write) RESOLVE_SYMLINKS="rw" ;;
            *)
                echo "Error: Invalid value '${1#*=}' for '--resolve-symlinks' (expected 'ro'/'read' or 'rw'/'write')." >&2
                exit 1
                ;;
        esac
        shift
        ;;
    -w | --whitelist)
        if [[ $# -lt 2 || "$2" == "--" ]]; then
            echo "Error: Option '$1' requires an argument." >&2
            exit 1
        fi
        WHITELIST_FILE="$2"
        shift 2
        ;;
    -d | --dir)
        if [[ $# -lt 2 || "$2" == "--" ]]; then
            echo "Error: Option '$1' requires an argument." >&2
            exit 1
        fi
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

# Never resolve workspace symlinks without a blocklist
if [ -n "$RESOLVE_SYMLINKS" ] && [ ! -f "$DEFAULT_SYMLINK_BLOCKLIST" ]; then
    echo "Error: Symlink blocklist not found: '$DEFAULT_SYMLINK_BLOCKLIST'" >&2
    echo "Run '$(basename "$0") --init' to create it from the template." >&2
    exit 1
fi

# Resolve absolute path for workspace
TARGET_DIR="$(cd "$TARGET_DIR" && pwd -P)"

# Guard: Prevent running directly on sensitive system directories or $HOME
case "$TARGET_DIR" in
    /|/etc|/etc/*|/usr|/usr/*|/bin|/sbin|/lib*|/boot|/boot/*|/sys|/sys/*|/proc|/proc/*|/dev|/dev/*|/var|/root|"$HOME")
        echo "Security Error: Running sandbox on system directory or HOME ('$TARGET_DIR') is strictly forbidden." >&2
        echo "This would expose your host system or credentials to the sandbox." >&2
        echo "Please specify a dedicated project workspace directory via '-d PATH' or run from within a subfolder." >&2
        exit 1
        ;;
esac

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
    "--unshare-user"    # Always create a user namespace (required by --disable-userns, added after profiles are applied)
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

# Ephemeral sandbox runtime files (clean /etc/hosts with IPv4 & IPv6 loopback, plus synthetic /etc/passwd and /etc/group)
SANDBOX_RUNTIME_DIR="$(mktemp -d /tmp/bwrap-rt-XXXXXX)"
chmod 0755 "$SANDBOX_RUNTIME_DIR"

HOST_NAME="$(hostname 2>/dev/null || echo "sandbox")"
cat <<EOF > "$SANDBOX_RUNTIME_DIR/hosts"
127.0.0.1 localhost $HOST_NAME
::1 localhost ip6-localhost ip6-loopback
EOF

# Synthetic POSIX identity to satisfy Node.js (os.userInfo()), Python (pwd.getpwuid()), git committer detection, and whoami
USER_NAME="${USER:-sandbox}"
USER_UID="$(id -u 2>/dev/null || echo "1000")"
USER_GID="$(id -g 2>/dev/null || echo "1000")"

cat <<EOF > "$SANDBOX_RUNTIME_DIR/passwd"
root:x:0:0:root:/root:/bin/bash
${USER_NAME}:x:${USER_UID}:${USER_GID}:${USER_NAME}:${HOME}:/bin/bash
EOF

cat <<EOF > "$SANDBOX_RUNTIME_DIR/group"
root:x:0:
${USER_NAME}:x:${USER_GID}:
EOF

chmod 0644 "$SANDBOX_RUNTIME_DIR/hosts" "$SANDBOX_RUNTIME_DIR/passwd" "$SANDBOX_RUNTIME_DIR/group"

# Essential system configuration (read-only)
BWRAP_ARGS+=(
    "--ro-bind" "$SANDBOX_RUNTIME_DIR/hosts" "/etc/hosts"
    "--ro-bind" "$SANDBOX_RUNTIME_DIR/passwd" "/etc/passwd"
    "--ro-bind" "$SANDBOX_RUNTIME_DIR/group" "/etc/group"
    "--ro-bind-try" "/etc/nsswitch.conf" "/etc/nsswitch.conf"
    "--ro-bind-try" "/etc/alternatives" "/etc/alternatives"
    "--ro-bind-try" "/etc/ld.so.cache" "/etc/ld.so.cache"
    "--ro-bind-try" "/etc/ld.so.conf" "/etc/ld.so.conf"
    "--ro-bind-try" "/etc/ld.so.conf.d" "/etc/ld.so.conf.d"
    "--ro-bind-try" "/etc/localtime" "/etc/localtime"
    "--ro-bind-try" "/etc/fonts" "/etc/fonts"
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

# Nested user namespaces are blocked unless requested via --allow-userns or 'allow_userns = true'
if [ "$ALLOW_USERNS" = true ]; then
    log_info "[i] Nested user namespaces are allowed (exposes more kernel attack surface to the sandbox)"
else
    BWRAP_ARGS+=("--disable-userns") # Mitigates kernel LPE exploits reachable through unprivileged user namespaces
fi

# ------------------------------------------------------------------------------
# Automatically Resolve Symlink Targets (e.g. Dotfiles Repositories)
# If a mounted directory or file contains symlinks pointing outside the mount
# (e.g. ~/.config/mise/config.toml -> ~/configs/.config/mise/config.toml),
# mount the real target path read-only so the symlink does not break inside the sandbox.
# ------------------------------------------------------------------------------
is_mount_covered() {
    local check_path="$1"
    for existing in "${ORDERED_MOUNT_PATHS[@]}"; do
        if [ "$check_path" = "$existing" ]; then
            return 0
        fi
        if [ -d "$existing" ] && [[ "$check_path" == "$existing"/* ]]; then
            return 0
        fi
    done
    case "$check_path" in
        /usr|/usr/*|/bin|/bin/*|/lib|/lib/*|/lib64|/lib64/*|/sbin|/sbin/*|/etc|/etc/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*)
            return 0
            ;;
    esac
    if [[ "$check_path" == "$TARGET_DIR" || "$check_path" == "$TARGET_DIR"/* ]]; then
        return 0
    fi
    return 1
}

RESOLVED_SYMLINK_TARGETS=()
for mp in "${ORDERED_MOUNT_PATHS[@]}"; do
    # Host contents of a tmpfs mount are hidden inside the sandbox, so their symlinks never resolve there
    [ "${MOUNT_PERMS["$mp"]}" = "tmpfs" ] && continue
    if [ -h "$mp" ]; then
        r="$(realpath "$mp" 2>/dev/null || true)"
        if [ -n "$r" ] && [ -e "$r" ]; then
            if ! is_mount_covered "$r"; then
                RESOLVED_SYMLINK_TARGETS+=("$r")
            fi
        fi
    elif [ -d "$mp" ]; then
        while IFS= read -r l; do
            r="$(realpath "$l" 2>/dev/null || true)"
            if [ -n "$r" ] && [ -e "$r" ]; then
                if ! is_mount_covered "$r"; then
                    RESOLVED_SYMLINK_TARGETS+=("$r")
                fi
            fi
        done < <(find "$mp" -maxdepth 3 -type l 2>/dev/null || true)
    fi
done

for st in "${RESOLVED_SYMLINK_TARGETS[@]}"; do
    if ! is_mount_covered "$st"; then
        set_mount "ro" "$st"
    fi
done

# A file mount is redundant when a parent directory is already mounted with the same mode
# (e.g. ~/.local/bin/claude from 'claude' and ~/.local/bin from 'dev-tools'). Binding it anyway
# would target a symlink inside the parent mount and break bwrap.
is_redundant_file_mount() {
    local file_path="$1"
    local file_mode="${MOUNT_PERMS["$file_path"]}"
    [ -d "$file_path" ] && return 1
    for existing in "${ORDERED_MOUNT_PATHS[@]}"; do
        if [ -d "$existing" ] && [[ "$file_path" == "$existing"/* ]] && [ "${MOUNT_PERMS["$existing"]}" = "$file_mode" ]; then
            return 0
        fi
    done
    return 1
}

DETECTED_USER_PATHS=()

for target_path in "${ORDERED_MOUNT_PATHS[@]}"; do
    mode="${MOUNT_PERMS["$target_path"]}"
    if is_redundant_file_mount "$target_path"; then
        log_debug "Skipping redundant mount [$mode] $target_path (covered by a parent directory mount)"
        continue
    fi
    log_debug "Mount [$mode] $target_path"
    if [ "$mode" = "rw" ]; then
        BWRAP_ARGS+=("--bind" "$target_path" "$target_path")
    elif [ "$mode" = "ro" ]; then
        BWRAP_ARGS+=("--ro-bind" "$target_path" "$target_path")
    elif [ "$mode" = "tmpfs" ]; then
        BWRAP_ARGS+=("--tmpfs" "$target_path")
        continue # Starts empty, so it never contributes executables to PATH
    fi

    path_entry=""
    if [[ ("$target_path" == *"bin"* || "$target_path" == *"shims"*) && -d "$target_path" ]]; then
        path_entry="$target_path"
    elif [ -f "$target_path" ] && [ -x "$target_path" ] && [[ "$(basename "$(dirname "$target_path")")" == "bin" ]]; then
        # Single executable mounted on its own (e.g. ~/.local/bin/claude): expose its parent bin directory
        path_entry="$(dirname "$target_path")"
    fi
    if [ -n "$path_entry" ] && [[ " ${DETECTED_USER_PATHS[*]} " != *" $path_entry "* ]]; then
        DETECTED_USER_PATHS+=("$path_entry")
    fi
done

# Build sanitized PATH (prevent leading colon which POSIX treats as current working directory)
CLEAN_PATH="/usr/local/bin:/usr/bin:/bin"
if [ ${#DETECTED_USER_PATHS[@]} -gt 0 ]; then
    CLEAN_PATH="$(IFS=:; echo "${DETECTED_USER_PATHS[*]}"):$CLEAN_PATH"
fi

# ------------------------------------------------------------------------------
# Workspace Symlink Resolution (--resolve-symlinks)
# Symlinks inside the project pointing outside of it (e.g. shared libraries,
# 'npm link' packages, files kept in a dotfiles repository) are broken inside
# the sandbox because their targets are not mounted. When enabled, each external
# target is mounted in the requested mode, refusing sensitive host paths since a
# cloned repository may contain hostile links (e.g. 'keys -> ~/.ssh').
# ------------------------------------------------------------------------------
# Usage: path_within <parent> <path> (true if path is parent or lies inside it)
path_within() {
    [ "$1" = "/" ] || [ "$2" = "$1" ] || [[ "$2" == "$1"/* ]]
}

# Lexically normalizes an absolute path (resolves '.' and '..' without following symlinks)
# into NORMALIZED_PATH, avoiding a subprocess per symlink on large workspaces.
normalize_path() {
    local part IFS='/'
    local -a parts=() out=()
    # Split on '/' via word splitting with globbing disabled (no here-string temp file per call)
    set -f
    parts=($1)
    set +f
    for part in "${parts[@]}"; do
        case "$part" in
            "" | .) ;;
            ..) [ ${#out[@]} -gt 0 ] && unset 'out[-1]' ;;
            *) out+=("$part") ;;
        esac
    done
    NORMALIZED_PATH="/${out[*]}"
}

SYMLINK_BLOCKED_PATHS=()       # Never mounted, neither directly nor through a parent directory
SYMLINK_RW_BLOCKED_PATHS=()    # Additionally refused when mounting read-write

# Loads symlink-blocklist.txt ('<path>' blocks every mode, 'rw:<path>' blocks read-write only)
load_symlink_blocklist() {
    local file="$1"
    local line raw_path resolved rw_only entry
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        raw_path="$line"
        rw_only=false
        if [[ "$line" =~ ^rw:(.*)$ ]]; then
            rw_only=true
            raw_path="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[a-zA-Z]+: ]]; then
            log_warn "Invalid prefix in symlink blocklist entry '$line' (only 'rw:' is supported). Skipping."
            continue
        fi
        raw_path="${raw_path#"${raw_path%%[![:space:]]*}"}"
        raw_path="${raw_path//\$\{SANDBOX_DIR\}/$SCRIPT_DIR}"
        raw_path="${raw_path//\$SANDBOX_DIR/$SCRIPT_DIR}"

        if [[ "$raw_path" != /* && "$raw_path" != "~" && "$raw_path" != "~/"* && "$raw_path" != "\$HOME"* && "$raw_path" != "\${HOME}"* ]]; then
            log_warn "Symlink blocklist entry '$line' is not an absolute path. Skipping."
            continue
        fi
        normalize_path "$(expand_path "$raw_path")"
        # Entries that are themselves symlinks (e.g. ~/.zshrc -> ~/dotfiles/zshrc) also block their real location
        resolved="$(realpath -q -e -- "$NORMALIZED_PATH" 2>/dev/null || true)"
        for entry in "$NORMALIZED_PATH" "$resolved"; do
            [ -z "$entry" ] && continue
            if [ "$rw_only" = true ]; then
                SYMLINK_RW_BLOCKED_PATHS+=("$entry")
            else
                SYMLINK_BLOCKED_PATHS+=("$entry")
            fi
        done
    done < "$file"
}

# Prints the reason a symlink target must not be mounted (returns 1 if allowed)
symlink_block_reason() {
    local p="$1"
    local blocked
    for blocked in "${SYMLINK_BLOCKED_PATHS[@]}"; do
        if path_within "$blocked" "$p" || path_within "$p" "$blocked"; then
            echo "blocked host path '$blocked'"
            return 0
        fi
    done
    if [ "$RESOLVE_SYMLINKS" = "rw" ]; then
        for blocked in "${SYMLINK_RW_BLOCKED_PATHS[@]}"; do
            if path_within "$blocked" "$p" || path_within "$p" "$blocked"; then
                echo "path '$blocked' is blocked for read-write mounts"
                return 0
            fi
        done
    fi
    if path_within "$p" "$TARGET_DIR"; then
        echo "target contains the workspace itself"
        return 0
    fi
    # Mounting a parent of a profile mount would shadow it (and override its ro/rw mode)
    for blocked in "${ORDERED_MOUNT_PATHS[@]}"; do
        if [ "$p" != "$blocked" ] && path_within "$p" "$blocked"; then
            echo "target contains profile mount '$blocked'"
            return 0
        fi
    done
    return 1
}

declare -A WORKSPACE_LINK_SOURCES=() # Sandbox destination (path the link points to) -> resolved host source

if [ -n "$RESOLVE_SYMLINKS" ]; then
    load_symlink_blocklist "$DEFAULT_SYMLINK_BLOCKLIST"

    while IFS= read -r -d '' link && IFS= read -r -d '' raw_target; do
        [ -z "$raw_target" ] && continue
        if [[ "$raw_target" != /* ]]; then
            raw_target="${link%/*}/$raw_target"
        fi
        normalize_path "$raw_target"
        dest="$NORMALIZED_PATH"

        # Internal links already work (chains through the workspace are handled by the next link)
        if path_within "$TARGET_DIR" "$dest" || [ -n "${WORKSPACE_LINK_SOURCES["$dest"]:-}" ]; then
            continue
        fi

        # Already visible inside the sandbox (system directories or profile mounts keep their own mode)
        if is_mount_covered "$dest"; then
            continue
        fi

        rel_link="${link#"$TARGET_DIR"/}"
        src="$(realpath -e "$link" 2>/dev/null || true)"
        if [ -z "$src" ]; then
            continue # Broken on the host as well
        fi

        if [ -S "$src" ] || [ -b "$src" ] || [ -c "$src" ] || [ -p "$src" ]; then
            reason="sockets, devices and FIFOs are never exposed"
        else
            # Check both the path the link points to and its fully resolved location
            reason="$(symlink_block_reason "$dest" || symlink_block_reason "$src" || true)"
        fi

        if [ -n "$reason" ]; then
            log_warn "Skipping workspace symlink '$rel_link' -> '$dest': $reason."
            continue
        fi

        WORKSPACE_LINK_SOURCES["$dest"]="$src"
        log_info "[+] Resolved workspace symlink '$rel_link' -> '$dest' [$RESOLVE_SYMLINKS]"
    done < <(find "$TARGET_DIR" -name .git -prune -o -type l -printf '%p\0%l\0' 2>/dev/null || true)

    # Mount parents before children, skipping targets already covered by a mounted parent directory
    mounted_link_dirs=()
    while IFS= read -r -d '' dest; do
        [ -z "$dest" ] && continue
        covered=false
        for parent_dir in "${mounted_link_dirs[@]}"; do
            if path_within "$parent_dir" "$dest"; then
                covered=true
                break
            fi
        done
        [ "$covered" = true ] && continue

        src="${WORKSPACE_LINK_SOURCES["$dest"]}"
        if [ "$RESOLVE_SYMLINKS" = "rw" ]; then
            BWRAP_ARGS+=("--bind" "$src" "$dest")
        else
            BWRAP_ARGS+=("--ro-bind" "$src" "$dest")
        fi
        [ -d "$src" ] && mounted_link_dirs+=("$dest")
    done < <(printf '%s\0' "${!WORKSPACE_LINK_SOURCES[@]}" | sort -z)
fi

# ------------------------------------------------------------------------------
# Workspace Security: Mount Project & Defend Git Hooks
# ------------------------------------------------------------------------------
# Mount target project workspace as read-write
BWRAP_ARGS+=(
    "--bind" "$TARGET_DIR" "$TARGET_DIR"
    "--chdir" "$TARGET_DIR"
)

# Edge Case: Prevent Git Hook & Config Poisoning (Workspace Escape Vectors)
# If .git exists:
# 1. Make .git/hooks read-only so agent cannot insert malicious hook triggers
# 2. Make .git/config read-only so agent cannot inject core.fsmonitor, core.hooksPath,
#    diff.external, core.pager, or credential.helper to achieve host execution upon exiting.
if [ -d "$TARGET_DIR/.git" ]; then
    mkdir -p "$TARGET_DIR/.git/hooks"
    BWRAP_ARGS+=("--ro-bind" "$TARGET_DIR/.git/hooks" "$TARGET_DIR/.git/hooks")
    if [ -f "$TARGET_DIR/.git/config" ]; then
        BWRAP_ARGS+=("--ro-bind" "$TARGET_DIR/.git/config" "$TARGET_DIR/.git/config")
    fi
elif [ -f "$TARGET_DIR/.git" ]; then
    # Git worktree or submodule pointer file
    BWRAP_ARGS+=("--ro-bind" "$TARGET_DIR/.git" "$TARGET_DIR/.git")

    # Resolve gitdir from pointer file (e.g. "gitdir: /path/to/gitdir" or "gitdir: ../path")
    RAW_GITDIR=""
    if grep -qE '^[[:space:]]*gitdir:[[:space:]]*' "$TARGET_DIR/.git" 2>/dev/null; then
        RAW_GITDIR="$(sed -n -E 's/^[[:space:]]*gitdir:[[:space:]]*(.*)$/\1/p' "$TARGET_DIR/.git" | head -n 1)"
        RAW_GITDIR="${RAW_GITDIR#"${RAW_GITDIR%%[![:space:]]*}"}"
        RAW_GITDIR="${RAW_GITDIR%"${RAW_GITDIR##*[![:space:]]}"}"
    fi

    if [ -n "$RAW_GITDIR" ]; then
        if [[ "$RAW_GITDIR" == /* ]]; then
            WT_GITDIR="$(realpath -m "$RAW_GITDIR" 2>/dev/null || echo "$RAW_GITDIR")"
        else
            WT_GITDIR="$(cd "$TARGET_DIR" && realpath -m "$RAW_GITDIR" 2>/dev/null || echo "$TARGET_DIR/$RAW_GITDIR")"
        fi

        if [ -d "$WT_GITDIR" ]; then
            # Determine common git dir (e.g. bare repo root or main repo .git)
            COMMON_GITDIR="$WT_GITDIR"
            if [ -f "$WT_GITDIR/commondir" ]; then
                RAW_COMMONDIR="$(cat "$WT_GITDIR/commondir" 2>/dev/null || true)"
                RAW_COMMONDIR="${RAW_COMMONDIR#"${RAW_COMMONDIR%%[![:space:]]*}"}"
                RAW_COMMONDIR="${RAW_COMMONDIR%"${RAW_COMMONDIR##*[![:space:]]}"}"
                if [ -n "$RAW_COMMONDIR" ]; then
                    if [[ "$RAW_COMMONDIR" == /* ]]; then
                        COMMON_GITDIR="$(realpath -m "$RAW_COMMONDIR" 2>/dev/null || echo "$RAW_COMMONDIR")"
                    else
                        COMMON_GITDIR="$(cd "$WT_GITDIR" && realpath -m "$RAW_COMMONDIR" 2>/dev/null || echo "$WT_GITDIR/$RAW_COMMONDIR")"
                    fi
                fi
            fi

            # Mount common gitdir (stores objects, refs, packed-refs, etc.)
            if [ -d "$COMMON_GITDIR" ]; then
                if [ -z "${MOUNT_PERMS["$COMMON_GITDIR"]:-}" ]; then
                    BWRAP_ARGS+=("--bind" "$COMMON_GITDIR" "$COMMON_GITDIR")
                fi
                # Defend git hooks & config in common gitdir against agent poisoning
                mkdir -p "$COMMON_GITDIR/hooks"
                BWRAP_ARGS+=("--ro-bind" "$COMMON_GITDIR/hooks" "$COMMON_GITDIR/hooks")
                if [ -f "$COMMON_GITDIR/config" ]; then
                    BWRAP_ARGS+=("--ro-bind" "$COMMON_GITDIR/config" "$COMMON_GITDIR/config")
                fi
            fi

            # Mount worktree-specific gitdir if distinct from common gitdir
            if [ "$WT_GITDIR" != "$COMMON_GITDIR" ]; then
                if [[ "$WT_GITDIR" != "$COMMON_GITDIR"/* ]] && [ -d "$WT_GITDIR" ]; then
                    BWRAP_ARGS+=("--bind" "$WT_GITDIR" "$WT_GITDIR")
                fi
                # Defend pointer files and worktree config
                if [ -f "$WT_GITDIR/commondir" ]; then
                    BWRAP_ARGS+=("--ro-bind" "$WT_GITDIR/commondir" "$WT_GITDIR/commondir")
                fi
                if [ -f "$WT_GITDIR/gitdir" ]; then
                    BWRAP_ARGS+=("--ro-bind" "$WT_GITDIR/gitdir" "$WT_GITDIR/gitdir")
                fi
                if [ -f "$WT_GITDIR/config.worktree" ]; then
                    BWRAP_ARGS+=("--ro-bind" "$WT_GITDIR/config.worktree" "$WT_GITDIR/config.worktree")
                fi
            fi
        fi
    fi
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

# Terminal identification and color preferences (--terminal-env or 'terminal_env = true').
# They only describe the host terminal, and tools inside the sandbox rely on them to
# pick color depth, color themes and hyperlink (OSC 8) handling the same way they do
# on the host. TMUX/TMUX_PANE only identify the multiplexer: the tmux server socket
# lives in the host /tmp, which the sandbox replaces with a private tmpfs, so it
# stays unreachable. KITTY_* is left out because it refers to kitty remote control.
if [ "$FORWARD_TERMINAL_ENV" = true ]; then
    TERMINAL_ENV_VARS=(
        "COLORTERM" "TERM_PROGRAM" "TERM_PROGRAM_VERSION" "TMUX" "TMUX_PANE"
        "VTE_VERSION" "KONSOLE_VERSION" "WT_SESSION"
        "COLORFGBG" "LS_COLORS" "NO_COLOR" "FORCE_COLOR" "FORCE_HYPERLINK"
        "CLICOLOR" "CLICOLOR_FORCE"
    )
    for var in "${TERMINAL_ENV_VARS[@]}"; do
        if [ -n "${!var:-}" ]; then
            BWRAP_ENV+=("--setenv" "$var" "${!var}")
        fi
    done

    # Terminals such as kitty ship their own terminfo entry outside the system
    # database; without it, TERM=xterm-kitty cannot be resolved inside the sandbox.
    if [ -n "${TERMINFO:-}" ] && [ -d "$TERMINFO" ]; then
        BWRAP_ARGS+=("--ro-bind" "$TERMINFO" "$TERMINFO")
        BWRAP_ENV+=("--setenv" "TERMINFO" "$TERMINFO")
    fi
fi

# ------------------------------------------------------------------------------
# Secure D-Bus Filtering via xdg-dbus-proxy (Appended AFTER --clearenv)
# ------------------------------------------------------------------------------
if [ "$ENABLE_DBUS_AUTH" = true ] || [ "$ENABLE_DBUS_NOTIFICATIONS" = true ]; then
    USER_UID="$(id -u)"
    HOST_BUS="/run/user/$USER_UID/bus"

    if [ -S "$HOST_BUS" ]; then
        if command -v xdg-dbus-proxy >/dev/null 2>&1; then
            PROXY_DIR="$(mktemp -d /tmp/bwrap-dbus-XXXXXX)"
            PROXY_BUS="$PROXY_DIR/bus"

            PROXY_ARGS=(
                "unix:path=$HOST_BUS" "$PROXY_BUS"
                "--filter"
            )

            # Granular D-Bus filtering: Keyring vs Desktop Notifications
            if [ "$ENABLE_DBUS_AUTH" = true ]; then
                PROXY_ARGS+=(
                    "--talk=org.freedesktop.secrets"
                    "--talk=org.gnome.keyring"
                )
            fi

            if [ "$ENABLE_DBUS_NOTIFICATIONS" = true ]; then
                PROXY_ARGS+=(
                    "--talk=org.freedesktop.Notifications"
                )
            fi

            # Block systemd and all other host interfaces
            xdg-dbus-proxy "${PROXY_ARGS[@]}" </dev/null &
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
            log_warn "'xdg-dbus-proxy' is not installed. D-Bus filtering disabled (Run: sudo apt install xdg-dbus-proxy)."
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

    SANDBOX_NO_PROXY="localhost,127.0.0.1,::1"
    # If the user explicitly declared localhost/127.0.0.1 rules in the whitelist,
    # do NOT bypass the proxy for localhost so traffic reaches the filtering proxy!
    if [ -f "$WHITELIST_FILE" ]; then
        if grep -Eq '^[[:space:]]*(\*\.)?(localhost|127\.0\.0\.1|::1)' "$WHITELIST_FILE"; then
            SANDBOX_NO_PROXY=""
        fi
    fi

    BWRAP_ENV+=(
        "--setenv" "HTTP_PROXY" "http://127.0.0.1:$SANDBOX_PROXY_PORT"
        "--setenv" "HTTPS_PROXY" "http://127.0.0.1:$SANDBOX_PROXY_PORT"
        "--setenv" "ALL_PROXY" "http://127.0.0.1:$SANDBOX_PROXY_PORT"
        "--setenv" "http_proxy" "http://127.0.0.1:$SANDBOX_PROXY_PORT"
        "--setenv" "https_proxy" "http://127.0.0.1:$SANDBOX_PROXY_PORT"
        "--setenv" "NO_PROXY" "$SANDBOX_NO_PROXY"
        "--setenv" "no_proxy" "$SANDBOX_NO_PROXY"
    )
fi

# ------------------------------------------------------------------------------
# GUI & Clipboard Support (--gui)
# ------------------------------------------------------------------------------
if [ "$ALLOW_GUI" = true ]; then
    HAS_GUI_DISPLAY=false
    HAS_X11_DISPLAY=false

    # 1. Wayland Display Server
    WAYLAND_SOCK=""
    if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        WAYLAND_SOCK="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
    elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "${XDG_RUNTIME_DIR:-}/wayland-0" ]; then
        WAYLAND_DISPLAY="wayland-0"
        WAYLAND_SOCK="$XDG_RUNTIME_DIR/wayland-0"
    fi

    if [ -n "$WAYLAND_SOCK" ] && [ -S "$WAYLAND_SOCK" ]; then
        USER_UID="$(id -u)"
        BWRAP_ARGS+=(
            "--dir" "/run/user/$USER_UID"
            "--bind" "$WAYLAND_SOCK" "/run/user/$USER_UID/$WAYLAND_DISPLAY"
        )
        BWRAP_ENV+=(
            "--setenv" "WAYLAND_DISPLAY" "$WAYLAND_DISPLAY"
            "--setenv" "XDG_RUNTIME_DIR" "/run/user/$USER_UID"
        )
        HAS_GUI_DISPLAY=true
    fi

    # 2. X11 Display Server
    if [ -n "${DISPLAY:-}" ]; then
        if [ -d "/tmp/.X11-unix" ]; then
            BWRAP_ARGS+=("--bind" "/tmp/.X11-unix" "/tmp/.X11-unix")
            BWRAP_ENV+=("--setenv" "DISPLAY" "$DISPLAY")
            HAS_GUI_DISPLAY=true
            HAS_X11_DISPLAY=true

            # Forward XAUTHORITY if present, or fallback to ~/.Xauthority
            HOST_XAUTH="${XAUTHORITY:-$HOME/.Xauthority}"
            if [ -f "$HOST_XAUTH" ]; then
                BWRAP_ARGS+=("--ro-bind" "$HOST_XAUTH" "$HOST_XAUTH")
                BWRAP_ENV+=("--setenv" "XAUTHORITY" "$HOST_XAUTH")
            fi
        fi
    fi

    if [ "$HAS_GUI_DISPLAY" = false ]; then
        log_warn "GUI access was requested ('--gui' or 'gui = true'), but no active X11 or Wayland display was detected on the host."
    elif [ "$HAS_X11_DISPLAY" = true ]; then
        log_info "[i] GUI access is enabled with X11 (sandboxed processes can log keystrokes, capture and inject input into other X11 windows; the clipboard is shared with the host)"
    else
        log_info "[i] GUI access is enabled (Wayland only; the clipboard is shared with the host)"
    fi
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

# Fixed per-profile assignments (setenv = NAME=VALUE) take precedence over forwarded host values
for assignment in "${SELECTED_SETENV[@]}"; do
    BWRAP_ENV+=("--setenv" "${assignment%%=*}" "${assignment#*=}")
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
        TRIES=0
        while ! (echo > /dev/tcp/127.0.0.1/'"$SANDBOX_PROXY_PORT"') 2>/dev/null; do
            if ! kill -0 "$RELAY_PID" 2>/dev/null; then
                echo "Error: Failed to start sandbox network relay." >&2
                exit 1
            fi
            TRIES=$((TRIES + 1))
            if [ "$TRIES" -ge 100 ]; then
                echo "Error: Timed out waiting for sandbox network relay on port '"$SANDBOX_PROXY_PORT"'." >&2
                exit 1
            fi
            sleep 0.05
        done
        exec "$@"
    '
    FINAL_CMD=("/bin/bash" "-c" "$INNER_WRAPPER" "--" "${COMMAND[@]}")
else
    FINAL_CMD=("${COMMAND[@]}")
fi

# ------------------------------------------------------------------------------
# Terminal Window Title & Process Execution
# ------------------------------------------------------------------------------
if [ -t 1 ] || [ -t 2 ]; then
    DISPLAY_TITLE="$(basename "${COMMAND[0]}")"
    # Push current title onto stack & set title via OSC 0
    printf '\033[22;0t\033]0;%s\007' "$DISPLAY_TITLE" 2>/dev/null || true
    if [ -n "${TMUX:-}" ]; then
        printf '\033k%s\033\\' "$DISPLAY_TITLE" 2>/dev/null || true
    fi
    TITLE_RESTORE_NEEDED=true
fi

EXIT_CODE=0
bwrap "${BWRAP_ARGS[@]}" "${BWRAP_ENV[@]}" "${FINAL_CMD[@]}" <&0 &
BWRAP_PID=$!

# Resilient wait loop: caught signals (such as SIGWINCH) cause 'wait' to return
# immediately with exit code > 128 (156 for SIGWINCH). Loop until bwrap actually
# terminates so window resizes do not prematurely kill the sandbox session.
while kill -0 "$BWRAP_PID" 2>/dev/null; do
    if wait "$BWRAP_PID" 2>/dev/null; then
        EXIT_CODE=0
        break
    else
        ret=$?
        if ! kill -0 "$BWRAP_PID" 2>/dev/null; then
            EXIT_CODE=$ret
            break
        fi
    fi
done
BWRAP_PID=""

exit "${EXIT_CODE:-0}"
