# bwrap-sandbox

A Bash wrapper around [Bubblewrap (`bwrap`)](https://github.com/containers/bubblewrap) for running AI coding agents such as Claude Code and Antigravity in unattended (*YOLO*) mode. The agent gets the project directory, the toolchains and credentials you choose, and optionally a network filtered by domain. Your real `$HOME`, SSH keys, shell history and the rest of the host stay out of reach.

There is no daemon, container image or VM: each run is a set of Linux namespaces that disappears when the command exits. The script works with any command, but it was developed mostly against the Antigravity CLI (`agy`) and Claude Code, and the bundled profiles reflect that.

---

## What it does

* **Hides `$HOME`.** `$HOME` is replaced by an empty tmpfs, so `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.docker`, shell histories and everything else there do not exist inside the sandbox. Only paths mounted by a profile come back.
* **Mounts the workspace read-write, the system read-only.** The project directory is mounted at its real path. `/usr` and a minimal set of `/etc` files are read-only; `/tmp` and `/dev/shm` are private tmpfs mounts.
* **Uses composable profiles.** Profiles in an INI file declare which paths are mounted (`ro`/`rw`), which environment variables are forwarded and which extra capabilities are enabled. They can be combined (`-p dev-tools,claude`), and on conflicting mounts the last one wins.
* **Has no network by default.** `--net-filtered` (`-nf`) allows HTTP/HTTPS only to domains in a whitelist, through a proxy reached over a Unix socket; the sandbox keeps its own network namespace. `--net` shares the host network without filtering.
* **Clears the environment.** The sandbox starts with `--clearenv`. Apart from locale and terminal basics, only variables listed by the active profiles are forwarded, so `-p dev-tools` runs with no API keys at all.
* **Protects host-side Git.** Hooks, config and the files that point Git elsewhere are mounted read-only, so the agent cannot plant code that runs the next time you use Git on the host. Commits still work inside the sandbox.
* **Filters D-Bus.** Profiles that need the keyring or desktop notifications get an `xdg-dbus-proxy` that exposes only those services; `systemd --user` and other host interfaces stay unreachable.
* **Blocks terminal injection.** `--new-session` detaches the controlling TTY, so `ioctl(TIOCSTI)` cannot push keystrokes into the host shell.

---

## Requirements

* **Bubblewrap (`bwrap`)**, required.
* **Python 3**, only for `--net-filtered` (it runs `net-proxy.py`). Everything else is Bash.
* **xdg-dbus-proxy**, only for profiles that enable `dbus_auth` or `dbus_notifications`.
* **socat**, optional. Used for the in-sandbox relay to the network proxy; without it, a small Python relay is used instead.

```bash
# Debian / Ubuntu
sudo apt update && sudo apt install bubblewrap xdg-dbus-proxy socat python3

# Fedora
sudo dnf install bubblewrap xdg-dbus-proxy socat python3

# Arch Linux
sudo pacman -S bubblewrap xdg-dbus-proxy socat python
```

> **Ubuntu 24.04 and later:** AppArmor restricts unprivileged user namespaces by default. If `bwrap` fails with `No permissions to creating new namespace`, lift the restriction:
> ```bash
> sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
> ```

---

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/jpbonfim/bwrap-sandbox.git
   cd bwrap-sandbox
   chmod +x bwrap-sandbox.sh
   ```

2. Create your local configuration from the templates:
   ```bash
   ./bwrap-sandbox.sh --init
   ```
   The first regular run does the same if the files are missing.

3. Optionally, put it on your `PATH`:
   ```bash
   mkdir -p ~/.local/bin
   ln -sf "$(pwd)/bwrap-sandbox.sh" ~/.local/bin/bwrap-sandbox
   ```
   The script resolves symlinks to find its own directory, so it still finds `profiles.conf`, `allowed-domains.txt` and `net-proxy.py` when called through the link.

---

## Configuration

Each configuration file has a versioned template and a local copy, ignored by Git, that the script actually reads. Edit the local copies; pulling updates will not conflict with them.

| Template (versioned) | Local copy (ignored) | Contents |
| --- | --- | --- |
| `profiles.example.conf` | `profiles.conf` | Profiles: mounts, environment variables, capabilities. |
| `allowed-domains.example.txt` | `allowed-domains.txt` | Domains and ports allowed by `-nf` (agent APIs, GitHub, npm, PyPI, etc.). |
| `symlink-blocklist.example.txt` | `symlink-blocklist.txt` | Host paths that symlink resolution never mounts (credentials, shell startup files, system paths, etc.). |

### Profiles (`profiles.conf`)

Every `[name]` section becomes a profile selectable with `-p name`. Directives:

* `description = <text>`: shown by `--list-profiles`.
* `mount = <ro|rw>:<path>`: bind-mounts a file or directory. `~` and `$HOME` are expanded. Missing paths are skipped. Repeatable.
* `protect = <path>[/]`: mounts a path read-only, even inside a read-write mount (e.g. `~/.claude/settings.json` inside `~/.claude`), so it cannot be modified, renamed or replaced. If the path does not exist but its parent does, an empty placeholder is created on the host first, so the agent cannot create it: a directory when the path ends with `/`, otherwise a file (`{}` for `.json`). Repeatable.

  Symlinks, such as files managed by a dotfiles repository, need special handling: bwrap follows them, and the link itself stays replaceable through its writable parent. So the link's target is protected instead, and the link is checked when the sandbox exits. If it was replaced or removed, it is restored and the replacement is kept as `<path>.sandbox-replaced.<timestamp>`, with a warning. During the session a replaced link is already visible to programs on the host, and nothing is checked if the script is killed with `SIGKILL`. For files that must never change mid-session, protect a real file or the directory containing the link.
* `tmpfs = <path>`: mounts an empty, writable tmpfs over a directory, usually inside a read-only mount (e.g. `~/.cache/ms-playwright/b`, where `@playwright/mcp` records running browsers). Writes stay in RAM and are discarded on exit, so tools on the host never read them. A missing directory is created on the host first if its parent exists, since bwrap cannot create mount points inside a read-only mount. Repeatable.
* `env = <NAME|PATTERN_*>`: forwards host environment variables. Wildcards are supported (`ANTIGRAVITY_*`). Repeatable.
* `setenv = <NAME>=<VALUE>`: sets a fixed variable inside the sandbox (e.g. `DISABLE_AUTOUPDATER=1`). Repeatable.
* `dbus_auth = true|false`: exposes the Secret Service / GNOME Keyring (`org.freedesktop.secrets`, `org.gnome.keyring`) through the filtered D-Bus proxy.
* `dbus_notifications = true|false`: exposes desktop notifications (`org.freedesktop.Notifications`) through the filtered D-Bus proxy.
* `gui = true|false`: same as `--gui`.
* `allow_userns = true|false`: same as `--allow-userns`.
* `terminal_env = true|false`: same as `--terminal-env`. Forwards terminal identification and color variables (`COLORTERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `TMUX`, `TMUX_PANE`, `VTE_VERSION`, `KONSOLE_VERSION`, `WT_SESSION`, `COLORFGBG`, `LS_COLORS`, `NO_COLOR`, `FORCE_COLOR`, `FORCE_HYPERLINK`, `CLICOLOR`, `CLICOLOR_FORCE`) and mounts `$TERMINFO` read-only when it is a directory. Tools use these to choose color depth, themes and hyperlink support (Claude Code, for instance, limits itself to 256 colors and wraps escape sequences differently when `TMUX` is set). The tmux socket itself stays unreachable: `/tmp` is private, and symlink resolution never mounts `/tmp` or directories containing sockets. `KITTY_*` is never forwarded, since it refers to kitty's remote control.

The switches (`dbus_*`, `gui`, `allow_userns`, `terminal_env`) are turned on if any active profile sets them to `true`. Setting `false`, or leaving them out, never turns off a switch enabled by another profile or a command-line flag.

Example:
```ini
[my-agent]
description = Custom agent workspace and Hugging Face credentials
mount = rw:~/.cache/huggingface
mount = ro:~/.config/my-agent
env = HF_TOKEN
env = MY_AGENT_*
```

```bash
./bwrap-sandbox.sh -p dev-tools,my-agent -nf -- my-agent-cli
```

### Profile variants (`profile:variant`)

A `[profile:variant]` section defines a variant, selected with `-p profile:variant`. The base section is applied first and the variant's directives on top, so a variant only lists what changes. On conflicting mounts the later one wins, so a base `rw` mount can become `ro` in the variant. `--list-profiles` groups variants under their base profile.

```ini
[my-agent:strict]
description = Custom agent with read-only configuration
protect = ~/.config/my-agent/hooks/
mount = ro:~/.cache/huggingface
```

```bash
./bwrap-sandbox.sh -p dev-tools,my-agent:strict -nf -- my-agent-cli
```

The template ships `standard` and `strict` variants for `claude` and `antigravity`. `standard` adds `gui` and `allow_userns` for headed browsers, so `-p claude` and `-p claude:standard` are **not** the same (see the warnings on [`--gui`](#security-implications-of---gui) and [`--allow-userns`](#security-implications-of---allow-userns)). The `:` separator needs no quoting in zsh, unlike brackets.

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
  -n, --net                Allow unrestricted network access, sharing the host network
                           namespace (Default: OFF / isolated; see README)
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

Everything after `--` is the command to run inside the sandbox; without it, an interactive shell starts. The workspace cannot be `$HOME` or any directory containing it (such as `/home` or `/`), a system directory (`/usr`, `/etc`, `/run`, ...) or a shared root such as `/tmp`, `/opt` or `/mnt`.

`--log-level debug` lists the applied profiles and every mount with its mode; `warn` or `error` hides the informational output.

> [!WARNING]
> #### Security implications of `--gui`
> Gives the sandbox the host display and clipboard. Under X11 it can read and inject input into other windows, including host terminals; under both X11 and Wayland it can read or replace the clipboard and draw fake prompts. Enable it only when you need a visible window or clipboard images.

> [!WARNING]
> #### Security implications of `--net`
> Shares the host network without filtering, including services listening on the host loopback and abstract Unix sockets (such as X11's). Prefer `--net-filtered`, and keep `--net` for short, trusted commands.

> [!WARNING]
> #### Security implications of `--allow-userns`
> Lets processes in the sandbox create user namespaces, which Chrome needs for its own sandbox. It also exposes kernel interfaces normally reserved for root, so a kernel bug becomes a way out of the sandbox. For headed browsers on trusted sites, running the browser with `--no-sandbox` instead is usually the safer choice.

---

## Examples

### 1. Offline shell

A shell in the current directory with no network:

```bash
./bwrap-sandbox.sh
```

### 2. Antigravity CLI with filtered network

Host toolchains, Antigravity's credentials and state, and network limited to the whitelist:

```bash
./bwrap-sandbox.sh -p dev-tools,antigravity -nf -- agy
```

### 3. Claude Code with filtered network

```bash
./bwrap-sandbox.sh -p dev-tools,claude -nf -- claude --dangerously-skip-permissions

# Strict variant: hooks, settings, skills, agents, commands, plugins, instructions and the binary are read-only
./bwrap-sandbox.sh -p dev-tools,claude:strict -nf -- claude --dangerously-skip-permissions
```

Notes on the `claude` profile:
* **Authentication:** on Linux, Claude Code keeps OAuth credentials in `~/.claude/.credentials.json`, which is shared with the host, so no keyring access is needed. If you are logged in on the host, the sandbox reuses that session (token refreshes go to `platform.claude.com`, which is in the default whitelist). To log in from inside, run `/login`, open the printed URL on the host and paste the code back. With an API key, export `ANTHROPIC_API_KEY` instead; all `ANTHROPIC_*` variables and `CLAUDE_CODE_OAUTH_TOKEN` are forwarded.
* **Updates:** `~/.local/share/claude` is mounted read-write so Claude Code can update itself, which also means the agent can modify the binary you run on the host. `claude:strict` mounts it read-only and sets `DISABLE_AUTOUPDATER=1`; update with `claude update` on the host.
* **Notifications:** `dbus_notifications` is on, so hooks can call `notify-send`. Only `org.freedesktop.Notifications` is reachable; keyring and systemd are not.
* **Headed browsers (`claude:standard`):** enables `gui` and `allow_userns` so Playwright can open a visible Chrome with Chrome's own sandbox. Use the base profile when you don't need that.
* **`claude:strict`** protects the files an agent could use to persist or run code: `~/.claude/settings.json` (hooks, statusline, permissions), `CLAUDE.md`, `skills/`, `agents/`, `commands/`, `output-styles/`, `plugins/`, `hooks/` and `chrome/` (the Claude in Chrome native messaging host, which the browser runs on the host). Sessions, history and credentials stay writable. As a consequence, `/config`, `/model` and similar commands cannot save settings, and plugins cannot be installed or synced. Not covered: MCP servers in `~/.claude.json` (Claude Code has to write that file) and project configuration in the workspace (`.claude/`, `.mcp.json`), which shows up in `git diff`.

Notes on `antigravity:strict`: it protects `~/.gemini/config/` (hooks, MCP config, skills, scripts, plugins; per-project state stays writable), the CLI's `settings.json`, global instructions (`GEMINI.md`, `AGENTS.md`), the authentication config (`~/.config/antigravity/`), executables (`~/.gemini/bin/`, the `agentapi` helpers, `~/.cache/antigravity/bin/`), and the IDE's extensions, settings, keybindings and wrappers (`~/.antigravity/{extensions,bin}/`, `argv.json`, `~/.antigravity-ide/`, `~/.config/Antigravity/`, `~/.config/Antigravity IDE/`). Updates from inside the sandbox fail; update on the host. If `GEMINI.md` or `AGENTS.md` are symlinks, their targets are protected and the links are checked on exit (see `protect`).

> [!WARNING]
> **Writable agent configuration.** The base `claude` and `antigravity` profiles mount the agent's configuration read-write, so the agent can add hooks, MCP servers or plugins that later run on the host (if you run the agent outside the sandbox) or in other projects. Use the `strict` variants, `protect` in your own profiles, or a separate configuration directory (e.g. `CLAUDE_CONFIG_DIR`) to prevent this.

### 4. Custom domain whitelist

```bash
./bwrap-sandbox.sh -p dev-tools,claude -nf -w ./my-domains.txt -- claude
```

### 5. Unrestricted network for a build

For downloads from repositories that are not on the whitelist:

```bash
./bwrap-sandbox.sh -p dev-tools --net -- cargo build
```

### 6. Antigravity CLI with display and clipboard

Lets you paste images into the CLI with `Ctrl+V` and run headed browsers:

```bash
./bwrap-sandbox.sh -p dev-tools,antigravity -nf -g -- agy
```

### 7. Workspace symlinks that point outside the project

Since only the workspace is mounted, symlinks pointing **outside** it (shared libraries, `npm link` or `pip install -e` packages, files in another repository) are broken inside the sandbox. Links to other places inside the project work normally. `--resolve-symlinks` scans the workspace and mounts each external target:

```bash
# Read-only (default; same as --resolve-symlinks=ro or =read)
./bwrap-sandbox.sh -p dev-tools,claude -nf --resolve-symlinks -- claude

# Read-write (same as =write): the agent can also modify the targets
./bwrap-sandbox.sh -p dev-tools,claude -nf --resolve-symlinks=rw -- claude
```

Each mounted or refused link is reported at startup (`[+] Resolved workspace symlink ...` / `Warning: Skipping workspace symlink ...`). The rules:

* **Blocklist (`symlink-blocklist.txt`):** host paths that are never mounted. The template covers credentials and secrets (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.docker`, `~/.config/gh`, `~/.netrc`, `~/.npmrc`, keyrings, agent configs such as `~/.claude` and `~/.gemini`), browser profiles, shell startup files and histories, `~/.gitconfig`, system paths (`/etc`, `/proc`, `/sys`, `/dev`, `/run`, `/root`, `/boot`) and shared temporary directories holding host IPC sockets (`/tmp`, `/var/tmp`). Entries prefixed with `rw:` are refused only in `rw` mode; the template uses that for locations the host executes from (`~/.local/bin`, `~/.config/systemd`, `~/.config/autostart`) and for the `bwrap-sandbox` directory itself (`$SANDBOX_DIR`). A blocked path also blocks every directory that **contains** it (a link to `~` or `/`), and entries that are symlinks also block their real location. Without the blocklist file, `--resolve-symlinks` refuses to run.
* **Always refused:** sockets, devices and FIFOs, and directories containing any of them at any depth (a socket stays connectable through a read-only mount); targets containing the workspace (e.g. `link -> ..`), which would expose sibling projects; and targets containing a profile mount, which would override its mode.
* **Skipped:** targets already visible in the sandbox (they keep the mode the profile set), broken links and anything inside `.git`.
* Links are resolved once, at startup, and one level deep. Links the agent creates later, or links inside a mounted target, are not resolved.

> [!WARNING]
> A repository can contain symlinks to sensitive host paths, and the blocklist is best-effort. Use `--resolve-symlinks` only on projects you trust, check the startup report, and prefer `ro`.

---

## Bundled profiles

| Profile | Mounts / permissions | Forwarded variables | Purpose |
| --- | --- | --- | --- |
| `dev-tools` | `~/.local/bin`, `~/.cargo/bin`, `~/.nvm`, `~/.pyenv`, `~/.asdf`, `~/.rustup`, `~/.fnm`, `~/.volta`, `~/.bun/bin`, `~/go/bin`, `~/.local/share/mise`, `~/.config/mise`, `~/.local/share/uv` **[RO]** | *(none)* | Host toolchains for building and testing, without letting the agent modify them. |
| `antigravity` | `~/.antigravity` **[RW]**<br>`~/.antigravity-ide` **[RW]**<br>`~/.gemini` **[RW]**<br>`~/.config/antigravity` **[RW]**<br>`~/.config/Antigravity` **[RW]**<br>`~/.config/Antigravity IDE` **[RW]**<br>`~/.cache/antigravity` **[RW]**<br>`~/.local/bin/agy` **[RO]**<br>`~/.cache/ms-playwright-go` **[RO]**<br>`~/.cache/ms-playwright` **[RO]**<br>`~/.cache/ms-playwright/b` **[tmpfs]**<br>`/opt/google/chrome` **[RO]**<br>D-Bus proxy (keyring and notifications) | `GEMINI_*`<br>`ANTIGRAVITY_*`<br>`GOOGLE_API_KEY`<br>`GOOGLE_APPLICATION_CREDENTIALS`<br>Terminal variables (`terminal_env`) | Antigravity CLI and IDE state, Google OAuth through the keyring, notifications. |
| `antigravity:standard` | `antigravity` plus display and clipboard (`gui`) and nested user namespaces (`allow_userns`) | Same as `antigravity` | Headed browsers with Chrome's own sandbox. Weakens isolation. |
| `antigravity:strict` | `antigravity` plus **[RO]**: `~/.gemini/config/` (except `projects/`), `GEMINI.md`, `AGENTS.md`, CLI `settings.json`, `~/.config/antigravity/`, `~/.gemini/bin/`, `agentapi` helpers, `~/.cache/antigravity/bin/`, IDE extensions, settings, keybindings and wrappers | Same as `antigravity` | Blocks tampering with hooks, MCP config, skills, IDE settings and binaries. |
| `claude` | `~/.claude` **[RW]**<br>`~/.claude.json` **[RW]**<br>`~/.local/state/claude` **[RW]**<br>`~/.local/share/claude` **[RW]**<br>`~/.local/bin/claude` **[RO]**<br>`~/.cache/ms-playwright` **[RO]**<br>`~/.cache/ms-playwright/b` **[tmpfs]**<br>`/opt/google/chrome` **[RO]**<br>D-Bus proxy (notifications only) | `ANTHROPIC_*`<br>`CLAUDE_CODE_OAUTH_TOKEN`<br>Terminal variables (`terminal_env`) | Claude Code credentials, sessions and installation; notifications from hooks. |
| `claude:standard` | `claude` plus display and clipboard (`gui`) and nested user namespaces (`allow_userns`) | Same as `claude` | Headed browsers with Chrome's own sandbox. Weakens isolation. |
| `claude:strict` | `claude` plus **[RO]**: `~/.claude/{settings.json,CLAUDE.md}`, `~/.claude/{skills,agents,commands,output-styles,plugins,hooks,chrome}/`, `~/.local/share/claude` | Same as `claude`<br>*(sets `DISABLE_AUTOUPDATER=1`)* | Blocks tampering with hooks, skills, plugins and the binary. |
| `openai` | *(none)* | `OPENAI_API_KEY` | OpenAI credentials. |
| `deepseek` | *(none)* | `DEEPSEEK_API_KEY` | DeepSeek credentials. |
| `mistral` | *(none)* | `MISTRAL_API_KEY` | Mistral credentials. |
| `groq` | *(none)* | `GROQ_API_KEY` | Groq credentials. |
| `none` | *(none)* | *(none)* | No host configuration, credentials or toolchains. This is the default. |

List the profiles in your local configuration with:
```bash
./bwrap-sandbox.sh --list-profiles
```

### Environment variables

A host variable reaches the sandbox only if an `env` directive in an active profile matches it:

* `-p dev-tools -- cargo build`: no API keys.
* `-p claude -- claude`: only `ANTHROPIC_*` and `CLAUDE_CODE_OAUTH_TOKEN`.
* `-p claude,openai -- my-script`: the Anthropic variables plus `OPENAI_API_KEY`.

### Git identity

`~/.gitconfig` is hidden along with the rest of `$HOME`, so `git commit` inside the sandbox fails with `Author identity unknown`. Two ways around it:

* **Identity only (least exposure):** set `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME` and `GIT_COMMITTER_EMAIL` with `setenv` in a profile.
* **The whole file:** uncomment `mount = ro:~/.gitconfig` in the `claude` or `antigravity` profile. Being read-only, the agent cannot add aliases, pagers or credential helpers that would later run on the host (and `core.hooksPath=/dev/null` is still forced inside the sandbox), but it can read everything in the file. Check it first for tokens in URLs, `http.extraHeader`, `credential.helper` or `include.path`, e.g. `grep -nE 'token|password|extraheader|https?://[^/ ]*@|helper|include' ~/.gitconfig`.

---

## How it works

* **Filtered network (`-nf`):** the sandbox keeps its own network namespace (`--unshare-net`), with no routes out. Inside, a relay on `127.0.0.1:18080` (socat or Python) forwards to a Unix socket mounted from the host, where `net-proxy.py` checks each request against `allowed-domains.txt`. `HTTP_PROXY`/`HTTPS_PROXY` point at the relay, so no port is opened on the host:

  ```
  sandbox (own netns, no routes)              host
    app ──HTTP_PROXY──▶ 127.0.0.1:18080
                        relay (socat/python) ──unix socket──▶ net-proxy.py ──▶ allowed domains
                                                                └─ 403 for everything else
  ```

  Domains or ports not on the list get `403 Forbidden`, and direct TCP/UDP connections fail with `Network is unreachable`. Host services are reachable only when listed explicitly, e.g. `localhost:11434` for Ollama, `127.0.0.1:8000,8080`, or ranges such as `3000-3010`.

  The proxy only sees the host and port the client asks for. Traffic inside an allowed `CONNECT` tunnel (TLS SNI, the inner `Host` header, any protocol on an allowed port) is not inspected, so a whitelisted CDN or shared hosting platform can relay requests to other sites it serves (domain fronting). On shared platforms, list specific hostnames rather than wildcards. Request heads must arrive within 30 seconds and have at most 100 header lines; upstream connections time out after 15 seconds; established tunnels have no idle timeout.
* **Git SSH remotes under `-nf`:** SSH (port 22) cannot go through an HTTP proxy, so with `-nf` `GIT_CONFIG_PARAMETERS` rewrites `git@github.com:` and `git@gitlab.com:` to `https://`, and `git clone`/`git fetch` go through the proxy.
* **Git metadata:** Git on the host runs hooks and commands taken from config (`core.fsmonitor`, `core.pager`, `diff.external`, `credential.helper`, ...), so a poisoned repository would run code outside the sandbox the next time you type `git status`. For the workspace repository, its linked worktrees (`.git/worktrees/*`) and its submodules (`.git/modules/**`), the files `hooks/`, `config`, `config.worktree`, `commondir` and `gitdir` are mounted read-only, and every git directory is mounted onto itself so it cannot be renamed or replaced. Objects, refs, the index and logs stay writable, so the agent can commit, branch and fetch. Since `<gitdir>/commondir` could redirect Git to config and hooks elsewhere, a harmless placeholder containing `./` is created in each repository and left there (Git only reports the common directory as an absolute path, e.g. in `git rev-parse --git-common-dir`); if an existing `commondir` points anywhere else, the sandbox refuses to start. Not covered: a repository the agent initializes during the session (a warning is shown on exit) and nested repositories it creates inside the workspace, so only run Git on the host in directories you expect to be repositories.
* **D-Bus:** handing the raw session bus to a sandbox lets it ask `systemd --user` to run commands outside every namespace. Profiles that need D-Bus get their own `xdg-dbus-proxy` that allows only the requested names:
  * `dbus_auth = true` exposes `org.freedesktop.secrets` and `org.gnome.keyring`. Anything in the sandbox can then read unlocked keyring secrets, so enable it only where host keyring integration is required.
  * `dbus_notifications = true` exposes `org.freedesktop.Notifications`, with no keyring access.
* **Nested user namespaces (`--disable-userns`):** blocked unless `--allow-userns` or `allow_userns = true` is used. This keeps netfilter, mounts and other kernel interfaces that user namespaces open to unprivileged users out of reach.
* **Environment:** `--clearenv` removes every host variable; locale, terminal and proxy variables are set explicitly, and the rest comes only from the active profiles' `env` and `setenv` directives (see [Environment variables](#environment-variables)).
* **Profile symlinks:** symlinks inside profile mounts that point elsewhere (e.g. `~/.claude/settings.json -> ~/dotfiles/claude/settings.json`) have their targets mounted read-only so they keep working. Since an agent could plant such a link in a writable mount (e.g. `~/.claude/x -> ~`) to get it mounted in a later session, targets go through the same rules as `--resolve-symlinks`: blocklisted paths, directories containing them or the workspace, and targets containing sockets, devices or FIFOs are refused with a warning (and none are resolved if `symlink-blocklist.txt` is missing). Paths named directly in `mount` entries are trusted. `--log-level debug` lists every resolved target.
* **Process lifetime:** `--die-with-parent` kills everything in the sandbox if the script exits. On exit, a `trap` stops `xdg-dbus-proxy` and `net-proxy.py` and removes the temporary directories (`/tmp/bwrap-rt-*`, `/tmp/bwrap-dbus-*`, `/tmp/bwrap-net-*`).
* **usr-merge:** `/bin`, `/sbin`, `/lib` and `/lib64` are recreated as symlinks when they are symlinks on the host, so the sandbox works on both merged and split layouts.

---

## Recommendations

1. **Use `-nf` by default.** It keeps the agent away from your LAN and host services and limits where data can be sent.
2. **Keep production secrets out of the shell** you launch the sandbox from. Forwarded variables are visible to everything the agent runs; prefer test keys with spending limits.
3. **Review changes from the host** (`git status`, `git diff`) before committing or pushing what the agent wrote.

---

## Contributing

Issues and pull requests are welcome, especially reports of sandbox escapes, permission bypasses, problems on specific distributions, and suggestions for tighter default profiles or whitelists.

> [!NOTE]
> I am not a security specialist, and much of this project was written with the help of AI coding agents. Treat it as a useful layer of defense, not a guarantee, and please report anything that looks wrong.

---

## License

[GNU General Public License v3.0](LICENSE).
