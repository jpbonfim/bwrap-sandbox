# bwrap-sandbox

A security-hardened, zero-daemon sandbox built on [Bubblewrap (`bwrap`)](https://github.com/containers/bubblewrap) designed to run autonomous AI coding agents (such as Antigravity and Claude Code) in full autonomous (*YOLO*) mode with minimal overhead and strict boundaries.

While completely agent-agnostic, it was actively developed and battle-tested with Google's Antigravity CLI (agy).

---

## Key Features

* **Zero-Daemon, Near-Zero Overhead:** Runs natively via Linux kernel namespaces without Docker daemons, background agents, or VM virtualization costs (< 2 MB RAM usage, sub-10ms startup).
* **Ephemeral `$HOME` (`tmpfs`):** Masks your real home directory with a temporary in-RAM filesystem. Sensitive folders (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.docker`, shell histories) do not exist inside the sandbox.
* **Composable Permission Profiles:** Combine multiple profiles (e.g., `-p dev-tools,antigravity`) with fine-grained Read-Only (`ro`) and Read-Write (`rw`) controls. If conflicting permissions arise, the last specified profile takes precedence.
* **Filtered D-Bus Keyring Proxy:** Safely isolates Google OAuth and Secret Service tokens via `xdg-dbus-proxy`. Agents can query the GNOME Keyring without granting access to `systemd` or other host control interfaces.
* **Modular Toolchain Access (`dev-tools`):** Exposes host compilers, package managers, and runtimes (`~/.local/bin`, `~/.cargo/bin`, `~/.nvm`, `~/.pyenv`, `~/.asdf`, `mise`, etc.) strictly in **read-only** mode so the agent can build and test without corrupting toolchain binaries.
* **Strict Domain-Filtered Network Access (`-nf, --net-filtered`):** Enforces outbound domain whitelisting via an unshared network namespace (`--unshare-net`) and an ephemeral Unix domain socket proxy. Zero external port exposure on the host, blocks direct IP/raw-socket bypasses, and prevents lateral access to host `127.0.0.1` services.
* **Network Isolation by Default:** Blocks all inbound and outbound network connectivity unless explicitly granted via `--net-filtered` (domain-whitelisted) or `--net` (unrestricted).
* **Workspace Hardening:** Mounts only the target workspace as read-write. Protects against Git hook and config poisoning by mounting the metadata that decides which hooks and config host-side Git uses read-only, while commits keep working inside the sandbox.
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
| `symlink-blocklist.example.txt` | Versioned in Git | Template listing sensitive host paths (credentials, shell startup files, system paths, etc.). |
| `symlink-blocklist.txt` | Ignored by Git | Your active blocklist of host paths never mounted by `--resolve-symlinks`. |

### Configuring Profiles (`profiles.conf`)

Profiles use standard INI syntax. Any section `[profile-name]` automatically becomes an available profile selectable via `-p profile-name`.

Supported directives:
* `description = <text>`: Summary shown in `--list-profiles`.
* `mount = <ro|rw>:<path>`: Directory or file to bind-mount. Supports `~` and `$HOME` expansion. Repeatable.
* `protect = <path>[/]`: Mounts a path read-only, even inside a read-write mount (e.g. `~/.claude/settings.json` inside `~/.claude`). Since a missing path could otherwise be created by the agent, an empty placeholder is created on the host first (a directory when the path ends with `/`, otherwise a file, `{}` for `.json`), only if its parent directory exists. Protected paths cannot be modified, renamed or replaced. Symlinks (e.g. files managed by a dotfiles repository) cannot be mounted read-only because bwrap follows them, and the link itself stays replaceable through its writable parent directory: their real target is protected instead, and after the sandbox exits the link is verified. If it was replaced or removed, the link is restored and any replacement is kept as `<path>.sandbox-replaced.<timestamp>` for inspection (a warning is shown). Repeatable.
* `tmpfs = <path>`: Mounts an empty, writable tmpfs over a directory, typically inside a read-only mount (e.g. `~/.cache/ms-playwright/b`, the registry where `@playwright/mcp` records running browsers). Writes stay in the sandbox's RAM and are discarded on exit, so nothing written there is ever read by tools on the host. A missing directory is created on the host first (only if its parent exists), since bwrap cannot create a mount point inside a read-only mount. Repeatable.
* `env = <NAME|PATTERN_*>`: Environment variable(s) to forward from the host. Supports wildcards (e.g., `ANTIGRAVITY_*`). Repeatable.
* `setenv = <NAME>=<VALUE>`: Fixed environment variable set inside the sandbox regardless of the host environment (e.g., `DISABLE_AUTOUPDATER=1`). Repeatable.
* `dbus_auth = true|false`: Enables filtered D-Bus proxy access to Secret Service / Keyring tokens (`org.freedesktop.secrets`, `org.gnome.keyring`).
* `dbus_notifications = true|false`: Enables filtered D-Bus proxy access to desktop notifications (`org.freedesktop.Notifications`).
* `gui = true|false`: Exposes the host X11/Wayland display and clipboard, same as `--gui`.
* `allow_userns = true|false`: Allows processes inside the sandbox to create nested user namespaces, same as `--allow-userns` (see the security warning below).
* `terminal_env = true|false`: Forwards host terminal identification and color variables (`COLORTERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `TMUX`, `TMUX_PANE`, `VTE_VERSION`, `KONSOLE_VERSION`, `WT_SESSION`, `COLORFGBG`, `LS_COLORS`, `NO_COLOR`, `FORCE_COLOR`, `FORCE_HYPERLINK`, `CLICOLOR`, `CLICOLOR_FORCE`) and mounts `$TERMINFO` read-only when it points to a directory, same as `--terminal-env`. Tools inside the sandbox use them to pick color depth, color themes and hyperlink handling (Claude Code, for example, limits colors to 256 and wraps escape sequences differently when `TMUX` is set). The tmux server socket stays unreachable, since the sandbox has a private `/tmp`; `KITTY_*` is never forwarded, since it refers to kitty remote control.

The `dbus_*`, `gui`, `allow_userns` and `terminal_env` switches are enabled as soon as any active profile sets them to `true`; `false` (or omitting them) never disables a switch enabled by another profile or by a command-line flag.

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

### Profile Variants (`profile:variant`)

A section named `[profile:variant]` defines a variant of `[profile]`, selected with `-p profile:variant`. Variants inherit their base profile: the base section is applied first and the variant's directives are layered on top, so a variant only lists what changes (on conflicting mounts, the last registration wins, e.g. `rw` in the base becomes `ro` in the variant). `--list-profiles` shows variants grouped under their base profile.

```ini
[my-agent:strict]
description = Custom agent with read-only configuration
protect = ~/.config/my-agent/hooks/
mount = ro:~/.cache/huggingface
```

```bash
./bwrap-sandbox.sh -p dev-tools,my-agent:strict -nf -- my-agent-cli
```

The default template ships `standard` and `strict` variants for `claude` and `antigravity`. The `standard` variants additionally enable `gui` and `allow_userns` for headed browsers (see [Security Implications of `--gui`](#security-implications-of---gui) and [Security Implications of `--allow-userns`](#security-implications-of---allow-userns)), so `-p claude` and `-p claude:standard` are **not** equivalent. The `:` separator needs no shell quoting, unlike brackets, which zsh treats as glob patterns.

---

## Usage

```text
Usage: bwrap-sandbox [OPTIONS] [-- COMMAND [ARGS...]]

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
```

The `--` delimiter separates script options from the command passed to the sandbox.

Use `--log-level debug` to inspect which profiles were applied and every mount with its `ro`/`rw` mode, or `--log-level warn`/`error` to silence informational reports.

> [!WARNING]
> #### Security Implications of `--gui`
> Enabling GUI access (`-g, --gui`, or `gui = true` in a profile) forwards your host's X11 and/or Wayland display server and clipboard into the sandbox. This enables pasting images from the clipboard into terminal agents (e.g., `agy`), running headed browsers (`headless: false` in Playwright), and viewing graphical plots.
>
> * **X11 does not isolate clients.** Any process inside the sandbox can log keystrokes sent to other X11 windows, capture their contents and inject synthetic input into them (XTest). If a host terminal runs under X11, injected keystrokes execute commands **outside the sandbox**, which amounts to a full sandbox escape. On a Wayland session the X11 socket belongs to Xwayland, so only applications running through Xwayland are exposed (list them with `xlsclients` on the host); native Wayland applications stay isolated.
> * **Wayland isolates clients** from each other's input and screen contents. Screen capture requires the desktop portal, which the filtered D-Bus proxy does not expose.
> * **Both protocols share the clipboard.** A sandboxed process can replace what you copied with a malicious command that runs when you paste it into a host terminal (clipboard poisoning), and it can read clipboard contents when it has focus.
> * **Both protocols allow spoofed windows.** The sandbox can open a window imitating a password, keyring or sudo prompt and capture what you type into it.
>
> Only enable `--gui` when you explicitly require graphical or clipboard capabilities (headless browsers do not need it), and check pasted commands before running them in a host terminal.

> [!WARNING]
> #### Security Implications of `--allow-userns`
> By default the sandbox passes `--disable-userns` to bwrap, so processes inside it cannot create nested user namespaces. `--allow-userns` (or `allow_userns = true` in a profile) lifts this restriction, which is required by software that builds its own sandbox, such as Chrome/Chromium (otherwise it must run with `--no-sandbox`).
>
> Creating a namespace does not by itself escape bwrap: nested namespaces stay confined to the sandbox. The risk is that an unprivileged user namespace grants capabilities (e.g. `CAP_NET_ADMIN`, `CAP_SYS_ADMIN`) over kernel subsystems normally reserved for root, such as netfilter/nf_tables, mounts and some filesystems. Many Linux local privilege escalation exploits (e.g. CVE-2024-1086 in nf_tables) are reachable only through this path. With nested user namespaces allowed, **any code running in the sandbox, including commands an agent runs because of a prompt injection, can reach that attack surface, and a working kernel exploit escapes the sandbox entirely and gains root on the host**.
>
> Trade-off for headed browsers: keeping `--disable-userns` and running the browser with `--no-sandbox` (e.g. `@playwright/mcp --no-sandbox`) exposes only what the bwrap sandbox already exposes to a compromised page, while `--allow-userns` keeps the browser's sandbox but weakens the outer boundary. Prefer `--no-sandbox` when the browser only visits trusted sites, keep the host kernel up to date, and enable `--allow-userns` only for sessions that need it. On Ubuntu, AppArmor (`kernel.apparmor_restrict_unprivileged_userns`) may still block nested namespaces.

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

### 3. Run Claude Code with Domain-Filtered Internet

Run Claude Code with host toolchains, persistent sessions/credentials, and network constrained to whitelisted APIs:

```bash
./bwrap-sandbox.sh -p dev-tools,claude -nf -- claude --dangerously-skip-permissions

# Strict variant: hooks, settings, skills, agents, commands, plugins, instructions and binary are read-only
./bwrap-sandbox.sh -p dev-tools,claude:strict -nf -- claude --dangerously-skip-permissions
```

Notes for the `claude` profile:
* **Headed browsers (`claude:standard`):** The `standard` variant enables `gui` and `allow_userns`, so Playwright can open a visible Chrome window with Chrome's own sandbox. Use the base `claude` profile when you don't need a browser, to keep `--disable-userns` and the display closed.
* **Notifications:** The profile enables `dbus_notifications`, so hooks can send desktop notifications (e.g. `notify-send` from a `Stop` hook). Only `org.freedesktop.Notifications` is reachable through the filtered D-Bus proxy; keyring and systemd access stay blocked.
* **Authentication:** On Linux, Claude Code stores OAuth credentials in `~/.claude/.credentials.json`, which is shared with the host, so no keyring/D-Bus access is required. If you are already logged in on the host, the sandbox reuses that session (token refreshes go through `platform.claude.com`, included in the default whitelist). To log in from inside the sandbox, run `/login`: the browser cannot be launched from the sandbox, so open the printed URL on the host and paste the authorization code back into the terminal. API key users can export `ANTHROPIC_API_KEY` instead (all `ANTHROPIC_*` variables and `CLAUDE_CODE_OAUTH_TOKEN` are forwarded).
* **Updates:** The Claude Code installation (`~/.local/share/claude`) is mounted read-write for convenience, so Claude Code can update itself. This also means the agent can modify the executable you run on the host. The `strict` variant mounts it read-only and disables auto-updates (`DISABLE_AUTOUPDATER=1`); run `claude update` on the host instead.
* **Strict variant (`claude:strict`):** protects the files an agent could use to persist or execute code: `~/.claude/settings.json` (hooks, statusline, permissions), `CLAUDE.md`, `skills/`, `agents/`, `commands/`, `output-styles/`, `plugins/`, `hooks/` (common location for hook scripts) and `chrome/` (the Claude in Chrome native messaging host, executed by the browser on the host). Sessions, history and OAuth credentials stay writable. Trade-offs: `/config`, `/model` and similar commands cannot persist settings, and plugins cannot be installed or synced. Not covered: MCP servers in `~/.claude.json` (Claude Code must write this file) and project-level configuration in the workspace (`.claude/`, `.mcp.json`), which shows up in `git diff`.
* **Strict variant (`antigravity:strict`):** protects `~/.gemini/config/` (hooks, MCP config, skills, scripts, plugins; per-project state stays writable), the Antigravity CLI `settings.json`, global instructions (`GEMINI.md`, `AGENTS.md`), Antigravity authentication config (`~/.config/antigravity/`), executables (`~/.gemini/bin/`, `agentapi` helpers, `~/.cache/antigravity/bin/`), and the IDE's extensions, user settings, keybindings, and wrappers (`~/.antigravity/{extensions,bin}/`, `argv.json`, `~/.antigravity-ide/`, `~/.config/Antigravity/`, `~/.config/Antigravity IDE/`). In-sandbox updates will fail; update from the host. If `GEMINI.md`/`AGENTS.md` are symlinks (e.g. to a dotfiles repository), their targets are read-only and the links are verified and restored on exit (see `protect`).

> [!WARNING]
> **Agent self-configuration attacks:** Any profile that mounts an agent's configuration directory read-write (e.g. `~/.claude`, `~/.claude.json`, `~/.gemini`) lets the agent, or a prompt injection steering it, rewrite its own configuration. Hooks, MCP servers, plugins, skills and instruction files (`CLAUDE.md`) can all execute commands or alter the agent's behavior, which enables two attack paths:
> * **Host execution:** if you ever run the agent **outside** the sandbox, a hook or MCP server planted from inside it runs on your host with full user privileges (SSH keys, browser sessions, shell profiles).
> * **Cross-project persistence:** because the configuration directory is shared, a payload planted while working on project A also runs in later sandboxed sessions for project B, breaking the isolation between workspaces.
>
> The same applies to project-level configuration inside the workspace (e.g. `<project>/.claude/settings.json`). Mitigations: run the agent only through the sandbox, review configuration changes periodically (e.g. keep the config directory under Git and inspect `git diff`), use the `strict` profile variants (or `protect` directives in your own profiles), or point the sandbox at a dedicated configuration directory (e.g. `CLAUDE_CONFIG_DIR`) that is separate from the one your host agent uses.

### 4. Run Claude Code with Custom Domain Whitelist

Run Claude Code with host toolchains and a custom domain whitelist file:

```bash
./bwrap-sandbox.sh -p dev-tools,claude -nf -w ./my-domains.txt -- claude
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

### 7. Resolve Workspace Symlinks Pointing Outside the Project

Only the workspace is mounted, so symlinks inside the project that point **outside** of it (shared libraries, `npm link` / `pip install -e` packages, files stored in another repository) are broken inside the sandbox. Symlinks pointing to other locations inside the project always work. `--resolve-symlinks` scans the workspace and mounts each external target:

```bash
# Read-only (default, same as --resolve-symlinks=ro or --resolve-symlinks=read)
./bwrap-sandbox.sh -p dev-tools,claude -nf --resolve-symlinks -- claude

# Read-write (same as --resolve-symlinks=write): the agent may also modify the symlink targets
./bwrap-sandbox.sh -p dev-tools,claude -nf --resolve-symlinks=rw -- claude
```

Every mounted or refused symlink is reported on startup (`[+] Resolved workspace symlink ...` / `Warning: Skipping workspace symlink ...`). Rules applied:

* **Blocklist (`symlink-blocklist.txt`):** host paths that are never mounted. The default template covers credentials and secrets (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.docker`, `~/.config/gh`, `~/.netrc`, `~/.npmrc`, keyrings, agent configs such as `~/.claude` and `~/.gemini`), browser profiles, shell startup files and histories (`~/.zshrc`, `~/.bashrc`, ...), `~/.gitconfig` and system paths (`/etc`, `/proc`, `/sys`, `/dev`, `/run`, `/root`, `/boot`). Entries prefixed with `rw:` are only refused in `rw` mode; the template uses it for host-executed locations (`~/.local/bin`, `~/.config/systemd`, `~/.config/autostart`) and the `bwrap-sandbox` installation directory itself (`$SANDBOX_DIR`). A blocked path also blocks every directory **containing** it (e.g. a link to `~` or `/`), and entries that are themselves symlinks (e.g. `~/.zshrc` managed by a dotfiles repository) also block their real location. If the blocklist file is missing, `--resolve-symlinks` refuses to run.
* **Always refused (built-in):** sockets, devices and FIFOs; targets containing the workspace (e.g. `link -> ..`), which would expose sibling projects; and targets containing a profile mount, which would override its `ro`/`rw` mode.
* **Skipped:** targets already visible in the sandbox (system directories or profile mounts keep the mode set by the profile), broken symlinks and anything inside `.git`.
* Symlinks are resolved once at startup and only one level deep: symlinks created later by the agent, or nested inside a mounted target, are not resolved.

> [!WARNING]
> A cloned repository can ship hostile symlinks (e.g. `keys -> ~/.ssh`). The blocklist is best-effort, so review the startup report and only use `--resolve-symlinks` on projects you trust. Prefer the default `ro` mode; `rw` lets the agent modify files outside the workspace that your host may later execute or trust (scripts, build files, other repositories). For a permanent, explicit setup, a `mount = ro:<path>` entry in a custom profile is the safer alternative.

---

## Profiles & Environment Isolation

Profiles govern which host paths, IPC mechanisms, and environment variables are exposed to the sandbox. Multiple profiles can be combined; in case of path permission conflicts, the last profile evaluated wins.

| Profile | Mounts / Permissions | Forwarded Environment Variables | Purpose |
| --- | --- | --- | --- |
| `dev-tools` | `~/.local/bin`, `~/.cargo/bin`, `~/.nvm`, `~/.pyenv`, `~/.asdf`, `~/.rustup`, `~/.fnm`, `~/.volta`, `~/.bun/bin`, `~/go/bin`, `~/.local/share/mise`, `~/.config/mise`, `~/.local/share/uv` **[RO]** | *(None)* | Exposes host toolchains to compile and test without modifying binaries. |
| `antigravity` | `~/.antigravity` **[RW]**<br>`~/.antigravity-ide` **[RW]**<br>`~/.gemini` **[RW]**<br>`~/.config/antigravity` **[RW]**<br>`~/.config/Antigravity` **[RW]**<br>`~/.config/Antigravity IDE` **[RW]**<br>`~/.cache/antigravity` **[RW]**<br>`~/.local/bin/agy` **[RO]**<br>`~/.cache/ms-playwright-go` **[RO]**<br>`~/.cache/ms-playwright` **[RO]**<br>`~/.cache/ms-playwright/b` **[tmpfs]**<br>`/opt/google/chrome` **[RO]**<br>`xdg-dbus-proxy` socket | `GEMINI_*`<br>`ANTIGRAVITY_*`<br>`GOOGLE_API_KEY`<br>`GOOGLE_APPLICATION_CREDENTIALS`<br>Terminal variables (`terminal_env`) | Preserves Antigravity/Gemini state, IDE/app configurations, embedded cache tools, and uses filtered D-Bus for Google OAuth / Keyring; matches host hyperlink and color rendering. |
| `antigravity:standard` | Same as `antigravity`, plus X11/Wayland display and clipboard (`gui`) and nested user namespaces (`allow_userns`) | Same as `antigravity` | Headed browsers (Playwright `headless: false`) with Chrome's own sandbox. Weakens isolation (see `--gui` and `--allow-userns`). |
| `antigravity:strict` | Same as `antigravity`, plus **[RO]**: `~/.gemini/config/` (except `projects/`), `GEMINI.md`, `AGENTS.md`, CLI `settings.json`, `~/.config/antigravity/`, `~/.gemini/bin/`, `agentapi` helpers, `~/.cache/antigravity/bin/`, IDE extensions, settings, keybindings and wrappers (`~/.antigravity/`, `~/.antigravity-ide/`, `~/.config/Antigravity/`, `~/.config/Antigravity IDE/`) | Same as `antigravity` | Blocks hook, MCP, skill, IDE setting and binary tampering (self-configuration attacks). |
| `claude` | `~/.claude` **[RW]**<br>`~/.claude.json` **[RW]**<br>`~/.local/state/claude` **[RW]**<br>`~/.local/share/claude` **[RW]**<br>`~/.local/bin/claude` **[RO]**<br>`~/.cache/ms-playwright` **[RO]**<br>`~/.cache/ms-playwright/b` **[tmpfs]**<br>`/opt/google/chrome` **[RO]**<br>`xdg-dbus-proxy` socket (notifications only) | `ANTHROPIC_*`<br>`CLAUDE_CODE_OAUTH_TOKEN`<br>Terminal variables (`terminal_env`) | Preserves Claude Code OAuth credentials, session history and installation; allows desktop notifications from hooks; matches host hyperlink and color rendering. |
| `claude:standard` | Same as `claude`, plus X11/Wayland display and clipboard (`gui`) and nested user namespaces (`allow_userns`) | Same as `claude` | Headed browsers (Playwright `headless: false`) with Chrome's own sandbox. Weakens isolation (see `--gui` and `--allow-userns`). |
| `claude:strict` | Same as `claude`, plus **[RO]**: `~/.claude/{settings.json,CLAUDE.md}`, `~/.claude/{skills,agents,commands,output-styles,plugins,hooks,chrome}/`, `~/.local/share/claude` | Same as `claude`<br>*(sets `DISABLE_AUTOUPDATER=1`)* | Blocks hook, skill, plugin and binary tampering (self-configuration attacks). |
| `openai` | *(None)* | `OPENAI_API_KEY` | Forwards OpenAI API credentials to tools that require them. |
| `deepseek` | *(None)* | `DEEPSEEK_API_KEY` | Forwards DeepSeek API credentials. |
| `mistral` | *(None)* | `MISTRAL_API_KEY` | Forwards Mistral API credentials. |
| `groq` | *(None)* | `GROQ_API_KEY` | Forwards Groq API credentials. |
| `none` | *(None)* | *(None)* | Pure isolation; no host configs, credentials, or toolchains escape RAM. |

### Per-Profile Environment Variable Isolation

To prevent credential leakage and uphold the principle of least privilege, environment variables are passed into the sandbox **only** if they are explicitly matched by an `env` directive in one of the active profiles:

* Running `./bwrap-sandbox.sh -p dev-tools -- cargo build` passes **zero** API keys into the sandbox.
* Running `./bwrap-sandbox.sh -p claude -- claude` passes only `ANTHROPIC_*` and `CLAUDE_CODE_OAUTH_TOKEN`, keeping your other credentials hidden.
* Running `./bwrap-sandbox.sh -p claude,openai -- my-script` passes both the Anthropic variables and `OPENAI_API_KEY`.
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
                              |         └── .git/{hooks,config} (Read-Only)|
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
* **Git Metadata Protection:** Git on the host runs hooks and config-defined commands (`core.fsmonitor`, `core.pager`, `diff.external`, `credential.helper`, ...), so a poisoned repository would execute code outside the sandbox the next time you run `git status`. For the workspace repository, its linked worktrees (`.git/worktrees/*`) and its submodules (`.git/modules/**`), `hooks/`, `config`, `config.worktree`, `commondir` and `gitdir` are mounted read-only, and every git directory is mounted on itself so it cannot be renamed or replaced. Objects, refs, the index and logs stay writable, so the agent can commit, branch and fetch. Since `<gitdir>/commondir` would redirect Git to a config and hooks elsewhere, a no-op placeholder containing `.` is created in each repository (it is left in place; Git only reports the common directory as an absolute path, e.g. in `git rev-parse --git-common-dir`), and the sandbox refuses to start if one points anywhere else. Not covered: a repository the agent creates during the session (a warning is shown on exit) and nested repositories the agent creates inside the workspace, so only run Git on the host in directories you expect to be repositories.
* **Git SSH Trap Mitigation:** Because SSH (port 22) cannot pass through an HTTP proxy, `GIT_CONFIG_PARAMETERS` automatically rewrites `git@github.com:` and `git@gitlab.com:` to `https://` URLs so `git clone` and `git fetch` seamlessly traverse the filtering proxy without developer intervention.
* **D-Bus Host Escape Neutralization & Fine-Grained Permissions:** Passing raw host D-Bus sockets into a sandbox allows attackers to instruct `systemd --user` to run commands outside all namespaces. Profiles requiring D-Bus spawn an isolated `xdg-dbus-proxy` filtering out all calls except explicitly permitted bus names, while completely blocking `org.freedesktop.systemd1` and other host APIs. Permissions are decoupled for least privilege:
  * `dbus_auth = true`: Filters and exposes `org.freedesktop.secrets` and `org.gnome.keyring` (used for OAuth tokens). *(Note: Allows processes inside the sandbox to query unlocked keyring credentials, so only enable it on profiles that strictly require host keyring integration).*
  * `dbus_notifications = true`: Filters and exposes `org.freedesktop.Notifications`, allowing desktop notifications (e.g. `notify-send`) without granting any credential or keyring access.
* **Nested User Namespace Blocking (`--disable-userns`):** Processes inside the sandbox cannot create further user namespaces, closing off the kernel attack surface (netfilter, mounts, etc.) that unprivileged user namespaces expose to local privilege escalation exploits. Lifted only by `--allow-userns` or `allow_userns = true`.
* **Process Termination Assurance (`--die-with-parent`):** If the parent shell or terminal terminates, the Linux kernel terminates every subprocess inside the sandbox namespace.
* **Automatic Resource Cleanup:** A bash `trap` cleans up the `xdg-dbus-proxy` and `net-proxy.py` background processes and removes temporary directories (`/tmp/bwrap-dbus-*`, `/tmp/bwrap-net-*`) upon exit.
* **Declarative Per-Profile Secret Scoping:** The sandbox runs `--clearenv` to scrub all host environment variables. Unlike traditional wrappers that unconditionally pass all API keys whenever network is enabled, `bwrap-sandbox` inspects the active profiles defined in `profiles.conf` and injects *only* the specific variables declared for those profiles (supporting exact names and wildcards). Toolchains, build runners, and unselected agents run with zero exposed keys.
* **Opt-in Workspace Symlink Resolution (`--resolve-symlinks`):** External symlink targets are never mounted implicitly. When requested, targets are mounted read-only by default, while paths listed in the configurable `symlink-blocklist.txt` (credentials, shell startup files, system paths, etc.), sockets and any directory containing them are always refused (see [example 7](#7-resolve-workspace-symlinks-pointing-outside-the-project)).
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


