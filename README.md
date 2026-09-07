# bwrap-sandbox

A security-hardened, zero-daemon sandbox built on [Bubblewrap (`bwrap`)](https://github.com/containers/bubblewrap) designed to run autonomous AI coding agents (such as Antigravity and Claude Code) in full autonomous (*YOLO*) mode with minimal overhead and strict boundaries.

---

## Key Features

* **Zero-Daemon, Near-Zero Overhead:** Runs natively via Linux kernel namespaces without Docker daemons, background agents, or VM virtualization costs (< 2 MB RAM usage, sub-10ms startup).
* **Ephemeral `$HOME` (`tmpfs`):** Masks your real home directory with a temporary in-RAM filesystem. Sensitive folders (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.docker`, shell histories) do not exist inside the sandbox.
* **Agent Permission Profiles:** Selectively persist authentication and cache states for specific coding agents (`antigravity`, `claude`) while leaving everything else isolated.
* **Native Toolchain Access:** Mounts host compilers, interpreters, and user-level tools (`gcc`, `python`, `node`, `nvm`, `cargo`, `go`, linters) in **read-only** mode so the agent can build and test without modifying system binaries.
* **Network Isolation by Default:** Blocks all inbound and outbound network connectivity unless explicitly granted via `--net`.
* **Workspace Hardening:** Mounts only the target workspace as read-write. Protects against `.git/hooks` poisoning vectors by locking hook execution and paths.
* **Terminal Injection Defense:** Uses `--new-session` to detach the controlling TTY, neutralizing `ioctl(TIOCSTI)` attacks that attempt to push keystrokes back to the host shell.
* **Environment Sanitization:** Executes `--clearenv` to scrub all host secrets, selectively passing only required UI/locale variables and explicit AI API keys when network is enabled.

---

## Prerequisites

Bubblewrap must be installed on the Linux host:

```bash
# Debian / Ubuntu
sudo apt update && sudo apt install bubblewrap

# Fedora
sudo dnf install bubblewrap

# Arch Linux
sudo pacman -S bubblewrap

```

> **Ubuntu 24.04 LTS Notice:** If you encounter `bwrap: No permissions to creating new namespace`, enable unprivileged user namespaces via sysctl:
> ```bash
> sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
> 
> ```
> 
> 

---

## Installation

1. Save the script as `bwrap-sandbox.sh`.
2. Make it executable:

```bash
chmod +x bwrap-sandbox.sh

```

3. *(Optional)* Move it to your local path for global access:

```bash
mkdir -p ~/.local/bin
cp bwrap-sandbox.sh ~/.local/bin/bwrap-sandbox

```

---

## Usage

```text
Usage: bwrap-sandbox [OPTIONS] [-- COMMAND [ARGS...]]

Options:
  -p, --profile NAME   Agent permission profile (antigravity, claude, none)
      --list-profiles  List available permission profiles
  -n, --net            Allow outbound network access (Default: OFF / isolated)
  -d, --dir PATH       Target workspace directory (Default: current working directory)
  -h, --help           Show help message

```

The `--` delimiter is used to separate script options from the command passed to the sandbox.

---

## Examples

### 1. Interactive Inspection (Offline)

Launch a clean subshell in the current project directory with no network access:

```bash
./bwrap-sandbox.sh

```


### 2. Run Claude Code with Internet Access

Run Claude Code with outbound network enabled for API calls and package installations:

```bash
./bwrap-sandbox.sh -p claude --net -- claude

```

### 3. Target a Specific Workspace

Open a sandbox scoped to an arbitrary folder:

```bash
./bwrap-sandbox.sh -d /path/to/project --net -p antigravity -- agy

```

---

## Profiles

Profiles govern which state and credential directories are exposed from your host home directory:

| Profile | Mounted Host Paths (Read-Write if present) | Purpose |
| --- | --- | --- |
| `antigravity` | `~/.antigravity`, `~/.gemini` | Preserves login tokens, session memory, and configurations. |
| `claude` | `~/.claude`, `~/.claude.json` | Preserves Claude authentication and workspace state. |
| `none` | *(None)* | Pure isolated sandbox; no agent metadata escapes RAM. |

List profiles at any time:

```bash
./bwrap-sandbox.sh --list-profiles

```

---

## Security Architecture

```
+-------------------------------------------------------------+
| HOST SYSTEM                                                 |
|  ~/.ssh, ~/.aws, /etc/shadow (Completely Hidden)            |
|  /usr, /bin, ~/.cargo/bin (Mounted Read-Only)               |
+-------------------------------------------------------------+
                              |
                              v
+-------------------------------------------------------------+
| BWRAP SANDBOX                                               |
|                                                             |
|  [Filesystem]                                               |
|   ├── /                  (Read-Only Root)                   |
|   ├── /tmp, /dev/shm     (Ephemeral RAM / tmpfs)            |
|   ├── $HOME              (Ephemeral RAM / tmpfs)            |
|   ├── $HOME/.antigravity (Mounted RW only if profile used)  |
|   └── /workspace         (Mounted RW - Current project)     |
|         └── .git/hooks   (Locked Read-Only)                 |
|                                                             |
|  [Isolation]                                                |
|   ├── Network Namespace  (Disabled by default)              |
|   ├── PID Namespace      (Sandbox root is PID 1)            |
|   ├── Environment        (clearenv: sanitized variables)    |
|   └── Terminal           (setsid: no TIOCSTI injection)     |
+-------------------------------------------------------------+

```

### Defense Mechanisms in Detail

* **Git Hook Trap Neutralization:** Autonomous agents can attempt privilege escalation outside the sandbox by dropping malicious scripts into `.git/hooks/pre-commit`. The sandbox enforces `--ro-bind` on `.git/hooks` and sets `GIT_CONFIG_PARAMETERS='core.hooksPath=/dev/null'`, rendering hook injection impossible.
* **Memory & Process Cleanup (`--die-with-parent`):** If the parent terminal closes or encounters `SIGKILL`, the kernel immediately tears down every subprocess created by the agent.
* **Usr-Merge Compatibility:** Automatically identifies and maps relative symlinks for `/bin`, `/sbin`, `/lib`, and `/lib64`, preventing mount failure on modern Debian, Ubuntu, and Arch systems.

---

## Best Practices for Agent Usage

1. **Development vs. Production Secrets:** Never export production tokens into your terminal before launching the sandbox. Rely on local `.env.development` files or pass test keys with hard spending limits.
2. **Network Discipline:** Run offline whenever possible (`./bwrap-sandbox.sh -p antigravity -- antigravity`). Only pass `--net` when the agent actively needs to query external LLM APIs or install dependencies.
3. **Commit Verification:** While the sandbox prevents unauthorized host modification, inspect file changes (`git status`, `git diff`) from your host terminal before committing code generated by the agent.
