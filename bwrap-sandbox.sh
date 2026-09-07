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
PROFILE=""
COMMAND=()

AVAILABLE_PROFILES=("antigravity" "claude" "none")

# ------------------------------------------------------------------------------
# Help & Usage
# ------------------------------------------------------------------------------
list_profiles() {
    cat <<EOF
Available Agent Profiles:
  antigravity    Mounts ~/.antigravity and ~/.gemini (read-write if present)
  claude         Mounts ~/.claude and ~/.claude.json (read-write if present)
  none           No agent-specific files or directories mounted (default)
EOF
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [-- COMMAND [ARGS...]]

A security-hardened Bubblewrap sandbox for AI coding agents.

Options:
  -p, --profile NAME   Agent permission profile (Options: antigravity, claude, none)
      --list-profiles  List available permission profiles and descriptions
  -n, --net            Allow network access (Default: OFF / isolated)
  -d, --dir PATH       Target workspace directory (Default: current directory)
  -h, --help           Show this help message

Examples:
  $(basename "$0") --list-profiles
  $(basename "$0") -p antigravity -- antigravity
  $(basename "$0") -p claude --net -- claude
  $(basename "$0") --net                                # Interactive bash without profile
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
    -p | --profile)
        PROFILE="$2"
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

# Validate selected profile
if [ -n "$PROFILE" ]; then
    PROFILE_VALID=false
    for valid_profile in "${AVAILABLE_PROFILES[@]}"; do
        if [ "$PROFILE" = "$valid_profile" ]; then
            PROFILE_VALID=true
            break
        fi
    done

    if [ "$PROFILE_VALID" = false ]; then
        echo "Error: Invalid profile '$PROFILE'." >&2
        echo "Valid profiles: ${AVAILABLE_PROFILES[*]}" >&2
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
# Core Security Configurations & Edge Cases
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
# Host Toolchain Detection & Safe Mapping
# Expose user-installed compilers/runtimes without exposing sensitive files
# ------------------------------------------------------------------------------
DETECTED_USER_PATHS=()

USER_TOOLS=(
    ".local/bin"
    ".cargo/bin"
    ".nvm"
    ".asdf"
    ".pyenv"
    ".rustup"
    ".fnm"
    ".volta"
    ".bun/bin"
    "go/bin"
)

for tool in "${USER_TOOLS[@]}"; do
    if [ -d "$HOME/$tool" ]; then
        BWRAP_ARGS+=("--ro-bind" "$HOME/$tool" "$HOME/$tool")
        if [[ "$tool" == *"bin"* ]]; then
            DETECTED_USER_PATHS+=("$HOME/$tool")
        fi
    fi
done

# Build sanitized PATH
CLEAN_PATH="$(
    IFS=:
    echo "${DETECTED_USER_PATHS[*]}"
):/usr/local/bin:/usr/bin:/bin"

# ------------------------------------------------------------------------------
# Agent Permission Profiles
# Conditionally exposes configuration and state files/directories per agent
# ------------------------------------------------------------------------------
PROFILE_PATHS=()

case "$PROFILE" in
    antigravity)
        PROFILE_PATHS=(
            "$HOME/.antigravity"
            "$HOME/.gemini"
        )
        ;;
    claude)
        PROFILE_PATHS=(
            "$HOME/.claude"
            "$HOME/.claude.json"
        )
        ;;
    none|"")
        ;;
esac

for target_path in "${PROFILE_PATHS[@]}"; do
    if [ -e "$target_path" ]; then
        BWRAP_ARGS+=("--bind" "$target_path" "$target_path")
    fi
done

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
# Clean Environment Variables (Anti-Leakage)
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

# If network is enabled, forward AI API keys for the coding agent
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
exec bwrap "${BWRAP_ARGS[@]}" "${BWRAP_ENV[@]}" "${COMMAND[@]}"