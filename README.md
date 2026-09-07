# bwrap-sandbox

A security-hardened, zero-daemon sandbox built on [Bubblewrap (`bwrap`)](https://github.com/containers/bubblewrap) designed to run autonomous AI coding agents (such as Antigravity and Claude Code) in full autonomous (*YOLO*) mode with minimal overhead and strict boundaries.

---

## Key Features

* **Zero-Daemon, Near-Zero Overhead:** Runs natively via Linux kernel namespaces without Docker daemons, background agents, or VM virtualization costs (< 2 MB RAM usage, sub-10ms startup).
* **Ephemeral `$HOME` (`tmpfs`):** Masks your real home directory with a temporary in-RAM filesystem. Sensitive folders (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.docker`, shell histories) do not exist inside the sandbox.
* **Composable Permission Profiles:** Combine multiple profiles (e.g., `-p dev-tools,antigravity`) with fine-grained Read-Only (`ro`) and Read-Write (`rw`) controls. If conflicting permissions arise, the last specified profile takes precedence.
* **Filtered D-Bus Keyring Proxy:** Safely isolates Google OAuth and Secret Service tokens via `xdg-dbus-proxy`. Agents can query the GNOME Keyring without granting access to `systemd` or other host control interfaces.
* **Modular Toolchain Access (`dev-tools`):** Exposes host compilers, package managers, and runtimes (`~/.local/bin`, `~/.cargo/bin`, `~/.nvm`, `~/.pyenv`, `~/.asdf`, etc.) strictly in **read-only** mode so the agent can build and test without corrupting toolchain binaries.
* **Network Isolation by Default:** Blocks all inbound and outbound network connectivity unless explicitly granted via `--net`.
* **Workspace Hardening:** Mounts only the target workspace as read-write. Protects against `.git/hooks` poisoning vectors by locking hook execution and paths.
* **Terminal Injection Defense:** Uses `--new-session` to detach the controlling TTY, neutralizing `ioctl(TIOCSTI)` attacks that attempt to push keystrokes back to the host shell.
* **Environment Sanitization:** Runs `--clearenv` to scrub host secrets, selectively passing only required UI/locale variables and explicit AI API keys when network access is enabled.

---

## Prerequisites

Bubblewrap and the D-Bus filtering proxy must be installed on the Linux host:

```bash
# Debian / Ubuntu
sudo apt update && sudo apt install bubblewrap xdg-dbus-proxy

# Fedora
sudo dnf install bubblewrap xdg-dbus-proxy

# Arch Linux
sudo pacman -S bubblewrap xdg-dbus-proxy

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

A security-hardened Bubblewrap sandbox for AI coding agents.

Options:
  -p, --profile NAME   Permission profile (Can be repeated or comma-separated)
      --list-profiles  List available permission profiles and descriptions
  -n, --net            Allow outbound network access (Default: OFF / isolated)
  -d, --dir PATH       Target workspace directory (Default: current directory)
  -h, --help           Show this help message

```

The `--` delimiter separates script options from the command passed to the sandbox.

---

## Examples

### 1. Interactive Inspection (Offline)

Launch a clean subshell in the current project directory with no network access:

```bash
./bwrap-sandbox.sh

```

### 2. Run Antigravity CLI with Development Tools & Internet

Run Antigravity with your host compilers available, persistent credentials, and network access:

```bash
./bwrap-sandbox.sh -p dev-tools,antigravity --net -- agy

```

*(Alternatively using repeated flags: `./bwrap-sandbox.sh -p dev-tools -p antigravity --net -- agy`)*

### 3. Run Claude Code Offline

Allow Claude Code to refactor, run tests, and inspect code locally without outbound internet access:

```bash
./bwrap-sandbox.sh -p dev-tools,claude -- claude

```

### 4. Target a Specific Workspace

Scope execution to a specific project directory:

```bash
./bwrap-sandbox.sh -d /path/to/project -p dev-tools,antigravity --net -- agy

```

---

## Profiles

Profiles govern which host paths and IPC mechanisms are exposed. Multiple profiles can be combined; in case of path permission conflicts, the last profile evaluated wins.

| Profile | Mounts / Permissions | Purpose |
| --- | --- | --- |
| `dev-tools` | `~/.local/bin`, `~/.cargo/bin`, `~/.nvm`, `~/.pyenv`, `~/.asdf`, `~/.rustup`, `~/.fnm`, `~/.volta`, `~/.bun/bin`, `~/go/bin` **[RO]** | Exposes host toolchains to compile and test without risking modifications. |
| `antigravity` | `~/.antigravity` **[RW]**<br>

<br>`~/.gemini` **[RW]**<br>

<br>`~/.cache/ms-playwright-go` **[RO]**<br>

<br>`xdg-dbus-proxy` socket | Preserves Antigravity/Gemini state and uses filtered D-Bus for Google OAuth / GNOME Keyring access. |
| `claude` | `~/.claude` **[RW]**<br>

<br>`~/.claude.json` **[RW]**<br>

<br>`~/.config/claude` **[RW]** | Preserves Claude Code authentication and workspace session history. |
| `none` | *(None)* | Pure isolation; no host configs or toolchains escape RAM. |

List profiles and descriptions:

```bash
./bwrap-sandbox.sh --list-profiles

```

---

## Security Architecture

```
+-------------------------------------------------------------------------+
| HOST SYSTEM                                                             |
|  ~/.ssh, ~/.aws, /etc/shadow             (Completely Hidden)            |
|  /usr, /bin, ~/.cargo/bin                (Mounted Read-Only)            |
|  /run/user/$UID/bus                      (Protected by xdg-dbus-proxy)   |
+-------------------------------------------------------------------------+
                                    |
          +-------------------------+-------------------------+
          | (Filtered Proxy Socket)                           |
          v                                                   v
+------------------------------------+    +-------------------------------+
| xdg-dbus-proxy                     |    | BWRAP SANDBOX                 |
|  ALLOW: org.freedesktop.secrets    |    |  [Filesystem]                 |
|  ALLOW: org.gnome.keyring          |===>|   ├── /         (Read-Only)   |
|  BLOCK: org.freedesktop.systemd1   |    |   ├── /tmp      (Ephemeral)   |
|  BLOCK: Everything else            |    |   ├── $HOME     (RAM tmpfs)   |
+------------------------------------+    |   └── /workspace(Mounted RW)  |
                                          |         └── .git/hooks (RO)   |
                                          |  [Isolation]                  |
                                          |   ├── Network   (Default OFF) |
                                          |   ├── PID 1     (Isolated)    |
                                          |   └── Session   (No TIOCSTI)  |
                                          +-------------------------------+

```

### Defense Mechanisms in Detail

* **D-Bus Host Escape Neutralization:** Passing raw host D-Bus sockets into a sandbox allows attackers to instruct `systemd --user` to run commands outside all namespaces. The sandbox spawns a background `xdg-dbus-proxy` filtering out all calls except `org.freedesktop.secrets` and `org.gnome.keyring`, allowing OAuth authentication without compromise.
* **Git Hook Trap Neutralization:** Agents cannot escalate privileges outside the sandbox by dropping malicious triggers into `.git/hooks/pre-commit`. The sandbox enforces `--ro-bind` on `.git/hooks` and exports `GIT_CONFIG_PARAMETERS='core.hooksPath=/dev/null'`.
* **Process Termination Assurance (`--die-with-parent`):** If the parent shell or terminal terminates, the Linux kernel terminates every subprocess inside the sandbox namespace.
* **Automatic Resource Cleanup:** A bash `trap` cleans up the `xdg-dbus-proxy` background process and removes the temporary `/tmp/bwrap-dbus-XXXXXX` directory upon exit.
* **Usr-Merge Compatibility:** Automatically identifies and maps relative symlinks for `/bin`, `/sbin`, `/lib`, and `/lib64`, preventing mount failure on modern Debian, Ubuntu, and Arch Linux distributions.

---

## Best Practices for Agent Usage

1. **Development vs. Production Secrets:** Never export production tokens into your terminal before launching the sandbox. Rely on local `.env.development` files or pass test keys with hard spending limits.
2. **Network Discipline:** Run offline whenever possible. Only pass `--net` when the agent actively needs to query external LLM APIs or install dependencies.
3. **Commit Verification:** While the sandbox prevents unauthorized host modification, inspect file changes (`git status`, `git diff`) from your host terminal before committing code generated by the agent.
