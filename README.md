# bwrap-sandbox

A security-hardened, zero-daemon sandbox built on [Bubblewrap (`bwrap`)](https://github.com/containers/bubblewrap) designed to run autonomous AI coding agents (such as Antigravity and Claude Code) in full autonomous (*YOLO*) mode with minimal overhead and strict boundaries.

While completely agent-agnostic, it was actively developed and battle-tested with Google's Antigravity CLI (agy).

---

## Key Features

* **Zero-Daemon, Near-Zero Overhead:** Runs natively via Linux kernel namespaces without Docker daemons, background agents, or VM virtualization costs (< 2 MB RAM usage, sub-10ms startup).
* **Ephemeral `$HOME` (`tmpfs`):** Masks your real home directory with a temporary in-RAM filesystem. Sensitive folders (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.docker`, shell histories) do not exist inside the sandbox.
* **Composable Permission Profiles:** Combine multiple profiles (e.g., `-p dev-tools,antigravity`) with fine-grained Read-Only (`ro`) and Read-Write (`rw`) controls. If conflicting permissions arise, the last specified profile takes precedence.
* **Filtered D-Bus Keyring Proxy:** Safely isolates Google OAuth and Secret Service tokens via `xdg-dbus-proxy`. Agents can query the GNOME Keyring without granting access to `systemd` or other host control interfaces.
* **Modular Toolchain Access (`dev-tools`):** Exposes host compilers, package managers, and runtimes (`~/.local/bin`, `~/.cargo/bin`, `~/.nvm`, `~/.pyenv`, `~/.asdf`, etc.) strictly in **read-only** mode so the agent can build and test without corrupting toolchain binaries.
* **Strict Domain-Filtered Network Access (`-nf, --net-filtered`):** Enforces outbound domain whitelisting via an unshared network namespace (`--unshare-net`) and an ephemeral Unix domain socket proxy. Zero external port exposure on the host, blocks direct IP/raw-socket bypasses, and prevents lateral access to host `127.0.0.1` services.
* **Network Isolation by Default:** Blocks all inbound and outbound network connectivity unless explicitly granted via `--net-filtered` (domain-whitelisted) or `--net` (unrestricted).
* **Workspace Hardening:** Mounts only the target workspace as read-write. Protects against `.git/hooks` poisoning vectors by locking hook execution and paths.
* **Terminal Injection Defense:** Uses `--new-session` to detach the controlling TTY, neutralizing `ioctl(TIOCSTI)` attacks that attempt to push keystrokes back to the host shell.
* **Environment Sanitization:** Runs `--clearenv` to scrub host secrets, selectively passing only required UI/locale variables and explicit AI API keys when network access is enabled.

---

## Prerequisites

* **Bubblewrap (`bwrap`)**: Required for kernel namespace isolation (`sudo apt install bubblewrap`).
* **Python 3**: Only required if using domain-filtered network access (`-nf, --net-filtered`) to run `net-proxy.py`. All profile parsing, mounts, and sandbox controls are **100% native Bash**.
* **xdg-dbus-proxy**: Required only for profiles using filtered GNOME Keyring / Secret Service (`sudo apt install xdg-dbus-proxy`).
* **socat**: *(Optional, recommended)* Accelerates internal network loopback relay with minimal RAM overhead (~1.5 MB).

```bash
# Debian / Ubuntu
sudo apt update && sudo apt install bubblewrap xdg-dbus-proxy socat python3

# Fedora
sudo dnf install bubblewrap xdg-dbus-proxy socat python3

# Arch Linux
sudo pacman -S bubblewrap xdg-dbus-proxy socat python
```

> **Ubuntu 24.04 LTS Notice:** If you encounter `bwrap: No permissions to creating new namespace`, enable unprivileged user namespaces via sysctl:
> ```bash
> sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
> ```

---

## Installation & Initialization

1. Clone or download the repository:
```bash
git clone https://github.com/jpbonfim/bwrap-sandbox.git
cd bwrap-sandbox
chmod +x bwrap-sandbox.sh
```

2. Initialize your local configuration:
```bash
./bwrap-sandbox.sh --init
```
*(Alternatively, simply running `./bwrap-sandbox.sh` for the first time will automatically instantiate your configuration files).*

3. *(Optional)* Create a symlink in your user path for global access:
```bash
mkdir -p ~/.local/bin
ln -sf "$(pwd)/bwrap-sandbox.sh" ~/.local/bin/bwrap-sandbox
```
*(The script automatically resolves its canonical directory following symlinks, ensuring it seamlessly locates `profiles.conf`, `allowed-domains.txt`, and `net-proxy.py` from anywhere on your system).*

---

## Configuration

All profiles, permissions, and network domain rules are declarative and stored in local configuration files that are ignored by Git (`.gitignore`). This allows you to customize paths, API credentials, and whitelist domains locally without causing merge conflicts when pulling upstream updates.

| File | Status | Description |
| --- | --- | --- |
| `profiles.example.conf` | Versioned in Git | Template defining default profiles and permissions. |
| `profiles.conf` | Ignored by Git | Your active, locally editable profile configuration. |
| `allowed-domains.example.txt` | Versioned in Git | Template listing standard agent endpoints (Google, Anthropic, NPM, etc.). |
| `allowed-domains.txt` | Ignored by Git | Your active domain whitelist used by `-nf`. |

### Configuring Profiles (`profiles.conf`)

Profiles use standard INI syntax. Any section `[profile-name]` automatically becomes an available profile selectable via `-p profile-name`.

Supported directives:
* `description = <text>`: Summary shown in `--list-profiles`.
* `mount = <ro|rw>:<path>`: Directory or file to bind-mount. Supports `~` and `$HOME` expansion. Repeatable.
* `env = <NAME|PATTERN_*>`: Environment variable(s) to forward from the host. Supports wildcards (e.g., `ANTIGRAVITY_*`). Repeatable.
* `dbus_auth = true|false`: Enables filtered D-Bus proxy access to Secret Service / Keyring tokens (`org.freedesktop.secrets`, `org.gnome.keyring`).
* `dbus_notifications = true|false`: Enables filtered D-Bus proxy access to desktop notifications (`org.freedesktop.Notifications`).
* `filtered_dbus = true|false`: Legacy alias for `dbus_auth`.

**Example custom profile:**
```ini
[my-agent]
description = Custom agent workspace and Hugging Face credentials
mount = rw:~/.cache/huggingface
mount = ro:~/.config/my-agent
env = HF_TOKEN
env = MY_AGENT_*
```

Once saved, `my-agent` will instantly appear in `--list-profiles` and can be invoked with:
```bash
./bwrap-sandbox.sh -p dev-tools,my-agent -nf -- my-agent-cli
```

---

## Usage

```text
Usage: bwrap-sandbox [OPTIONS] [-- COMMAND [ARGS...]]

A security-hardened Bubblewrap sandbox for AI coding agents.

Options:
  -p, --profile NAME       Permission profile (Can be repeated or comma-separated)
      --list-profiles      List available permission profiles and descriptions
  -c, --config PATH        Path to profiles configuration file (Default: profiles.conf)
      --init               Initialize profiles.conf and allowed-domains.txt from templates and exit
  -n, --net                Allow unrestricted network access (Default: OFF / isolated)
  -nf, --net-filtered      Allow domain-filtered network access via strict proxy
  -g, --gui                Expose X11/Wayland display and clipboard (Warning: reduces isolation)
  -w, --whitelist PATH     Domain whitelist file (Default: allowed-domains.txt)
  -d, --dir PATH           Target workspace directory (Default: current directory)
  -h, --help               Show this help message
```

The `--` delimiter separates script options from the command passed to the sandbox.

> [!WARNING]
> **Security Implications of `--gui`:**
> Enabling GUI access (`-g, --gui`) forwards your host's X11 and/or Wayland display server and clipboard into the sandbox. This enables pasting images from the clipboard into terminal agents (e.g., `agy`), running headed browsers (`headless: false` in Playwright), and viewing graphical plots.
>
> However, **the legacy X11 protocol does not isolate clients**. On native X11 desktops, any process inside the sandbox could theoretically monitor host keystrokes (keylogging), capture screenshots of other windows, or inject synthetic input events into host terminals. Wayland provides strong per-client isolation and prevents these cross-client attacks. Only enable `--gui` when you explicitly require graphical or clipboard capabilities.

---

## Examples

### 1. Interactive Inspection (Offline)

Launch a clean subshell in the current project directory with no network access:

```bash
./bwrap-sandbox.sh

```

### 2. Run Antigravity CLI with Domain-Filtered Internet (Recommended)

Run Antigravity with your host compilers, persistent credentials, and network strictly constrained to whitelisted APIs (Google, Gemini, Anthropic, GitHub, NPM, PyPI, etc.):

```bash
./bwrap-sandbox.sh -p dev-tools,antigravity -nf -- agy

```

### 3. Run Claude Code with Custom Domain Whitelist

Run Claude Code with host toolchains and a custom domain whitelist file:

```bash
./bwrap-sandbox.sh -p dev-tools,claude -nf -w ./my-domains.txt -- claude

```

### 4. Run Claude Code Offline

Allow Claude Code to refactor, run tests, and inspect code locally without outbound internet access:

```bash
./bwrap-sandbox.sh -p dev-tools,claude -- claude

```

### 5. Run Unrestricted Build / Download Commands

When downloading from unwhitelisted package repositories or running unrestricted commands:

```bash
./bwrap-sandbox.sh -p dev-tools --net -- cargo build
```

### 6. Run Antigravity CLI with GUI & Clipboard Support

Run Antigravity with domain-filtered internet and GUI display enabled (allowing pasting clipboard images directly into the CLI via `Ctrl+V`, headed browser tests, etc.):

```bash
./bwrap-sandbox.sh -p dev-tools,antigravity -nf -g -- agy
```

---

## Profiles & Environment Isolation

Profiles govern which host paths, IPC mechanisms, and environment variables are exposed to the sandbox. Multiple profiles can be combined; in case of path permission conflicts, the last profile evaluated wins.

| Profile | Mounts / Permissions | Forwarded Environment Variables | Purpose |
| --- | --- | --- | --- |
| `dev-tools` | `~/.local/bin`, `~/.cargo/bin`, `~/.nvm`, `~/.pyenv`, `~/.asdf`, `~/.rustup`, `~/.fnm`, `~/.volta`, `~/.bun/bin`, `~/go/bin` **[RO]** | *(None)* | Exposes host toolchains to compile and test without modifying binaries. |
| `antigravity` | `~/.antigravity` **[RW]**<br>`~/.gemini` **[RW]**<br>`~/.cache/ms-playwright-go` **[RO]**<br>`xdg-dbus-proxy` socket | `GEMINI_API_KEY`<br>`ANTIGRAVITY_*` | Preserves Antigravity/Gemini state and uses filtered D-Bus for Google OAuth / GNOME Keyring. |
| `claude` | `~/.claude` **[RW]**<br>`~/.claude.json` **[RW]**<br>`~/.config/claude` **[RW]**<br>`~/.local/share/claude` **[RW]**<br>`~/.local/state/claude` **[RW]** | `ANTHROPIC_API_KEY` | Preserves Claude Code authentication and workspace session history. |
| `openai` | *(None)* | `OPENAI_API_KEY` | Forwards OpenAI API credentials to tools that require them. |
| `deepseek` | *(None)* | `DEEPSEEK_API_KEY` | Forwards DeepSeek API credentials. |
| `mistral` | *(None)* | `MISTRAL_API_KEY` | Forwards Mistral API credentials. |
| `groq` | *(None)* | `GROQ_API_KEY` | Forwards Groq API credentials. |
| `none` | *(None)* | *(None)* | Pure isolation; no host configs, credentials, or toolchains escape RAM. |

### Per-Profile Environment Variable Isolation

To prevent credential leakage and uphold the principle of least privilege, environment variables are passed into the sandbox **only** if they are explicitly matched by an `env` directive in one of the active profiles:

* Running `./bwrap-sandbox.sh -p dev-tools -- cargo build` passes **zero** API keys into the sandbox.
* Running `./bwrap-sandbox.sh -p claude -- claude` passes only `ANTHROPIC_API_KEY`, keeping your other credentials hidden.
* Running `./bwrap-sandbox.sh -p claude,openai -- my-script` passes both `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`.
* Profiles support wildcards (`env = ANTIGRAVITY_*`), forwarding all matching exported host variables.

Inspect current profiles and descriptions:
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
|  /run/user/$UID/bus                      (Protected by xdg-dbus-proxy)  |
|  /tmp/bwrap-net-XXXXXX/proxy.sock        (Unix Socket Domain Filter)    |
+-------------------------------------------------------------------------+
       |                                             |
       | (Filtered D-Bus Socket)                     | (Filtered Network Socket)
       v                                             v
+------------------------------------+   +--------------------------------+
| xdg-dbus-proxy                     |   | net-proxy.py (Host Mode)       |
|  ALLOW: org.freedesktop.secrets    |   |  ALLOW: Whitelisted Domains    |
|  ALLOW: org.gnome.keyring          |   |  BLOCK: All other domains(403) |
|  BLOCK: org.freedesktop.systemd1   |   +--------------------------------+
|  BLOCK: Everything else            |                   |
+------------------------------------+                   | (Bind-Mount)
                   |                                     v
                   |          +--------------------------------------------+
                   +=========>| BWRAP SANDBOX (--unshare-net)              |
                              |  [Filesystem]                              |
                              |   ├── /          (Read-Only)               |
                              |   ├── /tmp       (Ephemeral RAM tmpfs)     |
                              |   ├── $HOME      (RAM tmpfs)               |
                              |   └── /workspace (Mounted Read-Write)      |
                              |         └── .git/hooks (Read-Only)         |
                              |  [Network Relay]                           |
                              |   └── 127.0.0.1:18080 (socat/python relay) |
                              |  [Isolation]                               |
                              |   ├── Kernel Net: Isolated (unshared)      |
                              |   ├── PID 1     : Private PID namespace    |
                              |   └── Session   : Detached (No TIOCSTI)    |
                              +--------------------------------------------+
```

### Defense Mechanisms in Detail

* **Strict Domain & Port Whitelisting (`-nf`):** The sandbox stays in an unshared network namespace (`--unshare-net`). Outbound HTTP/HTTPS traffic is routed strictly through an internal loopback relay (`127.0.0.1:18080`) over a mounted Unix domain socket to `net-proxy.py` on the host. Unlisted domains or unlisted ports are rejected with `403 Forbidden`. Untrusted processes cannot bypass the filter via raw TCP/UDP sockets (which yield `Network is unreachable`), nor can they probe host ports (`127.0.0.1`) unless granular access is explicitly declared in `allowed-domains.txt` (e.g. `localhost:11434` for Ollama, `127.0.0.1:8000,8080`, or port ranges like `3000-3010`).
* **Git SSH Trap Mitigation:** Because SSH (port 22) cannot pass through an HTTP proxy, `GIT_CONFIG_PARAMETERS` automatically rewrites `git@github.com:` and `git@gitlab.com:` to `https://` URLs so `git clone` and `git fetch` seamlessly traverse the filtering proxy without developer intervention.
* **D-Bus Host Escape Neutralization & Fine-Grained Permissions:** Passing raw host D-Bus sockets into a sandbox allows attackers to instruct `systemd --user` to run commands outside all namespaces. Profiles requiring D-Bus spawn an isolated `xdg-dbus-proxy` filtering out all calls except explicitly permitted bus names, while completely blocking `org.freedesktop.systemd1` and other host APIs. Permissions are decoupled for least privilege:
  * `dbus_auth = true`: Filters and exposes `org.freedesktop.secrets` and `org.gnome.keyring` (used for OAuth tokens). *(Note: Allows processes inside the sandbox to query unlocked keyring credentials, so only enable it on profiles that strictly require host keyring integration).*
  * `dbus_notifications = true`: Filters and exposes `org.freedesktop.Notifications`, allowing desktop notifications (e.g. `notify-send`) without granting any credential or keyring access.
* **Process Termination Assurance (`--die-with-parent`):** If the parent shell or terminal terminates, the Linux kernel terminates every subprocess inside the sandbox namespace.
* **Automatic Resource Cleanup:** A bash `trap` cleans up the `xdg-dbus-proxy` and `net-proxy.py` background processes and removes temporary directories (`/tmp/bwrap-dbus-*`, `/tmp/bwrap-net-*`) upon exit.
* **Declarative Per-Profile Secret Scoping:** The sandbox runs `--clearenv` to scrub all host environment variables. Unlike traditional wrappers that unconditionally pass all API keys whenever network is enabled, `bwrap-sandbox` inspects the active profiles defined in `profiles.conf` and injects *only* the specific variables declared for those profiles (supporting exact names and wildcards). Toolchains, build runners, and unselected agents run with zero exposed keys.
* **Usr-Merge Compatibility:** Automatically identifies and maps relative symlinks for `/bin`, `/sbin`, `/lib`, and `/lib64`, preventing mount failure on modern Debian, Ubuntu, and Arch Linux distributions.

---

## Best Practices for Agent Usage

1. **Prefer `--net-filtered` (`-nf`) over `--net`:** Use `-nf` as your default network mode for AI agents. It protects your local network, blocks arbitrary telemetry/exfiltration, and limits token usage to whitelisted endpoints.
2. **Development vs. Production Secrets:** Never export production tokens into your terminal before launching the sandbox. Rely on local `.env.development` files or pass test keys with hard spending limits.
3. **Commit Verification:** While the sandbox prevents unauthorized host modification, inspect file changes (`git status`, `git diff`) from your host terminal before committing code generated by the agent.

---

## Contributing & Disclaimer

Contributions, feedback, and security reviews are warmly welcome!

> [!NOTE]
> **Honest Disclaimer:** I am not a cybersecurity specialist or kernel isolation expert. A major portion of this project was vibecoded alongside AI coding agents to solve a real practical need.
>
> If you notice potential sandbox escapes, permission bypasses, edge cases on your Linux distribution, or have suggestions for tighter default profiles and domain whitelists, please open an issue or submit a pull request! All ideas and improvements are appreciated.

---

## License

This project is licensed under the terms of the [GNU General Public License v3.0 (GPLv3)](LICENSE).


