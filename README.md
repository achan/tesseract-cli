# tesseract-cli

Personal development control plane for running app worktrees, dev servers, and
coding agents on remote hosts.

The default host is `tars`. Runtime work runs as `bot`; Docker-backed shared
services run as `achan` through the host profile's `service_user`.

## Mental Model

`bin/tesseract` is run from this repo on the control machine, usually the
MacBook. It reads local YAML profiles, connects to the selected host over SSH,
and runs the requested operation there.

There are three layers:

- Host profiles in `config/hosts/*.yml` describe machines such as `tars` and
  `local`.
- App profiles in `config/apps/*.yml` describe app clones such as `docovia` and
  `flexday`.
- Repo-local app adapters, usually `<app main path>/bin/tesseract`, own
  app-specific worktree behavior.

The top-level CLI handles host/app discovery, SSH, shared services, DNS, certs,
and dispatch. Worktree commands intentionally delegate into the app repository
so each app can decide how to create databases, env files, tmux sessions,
servers, workers, and asset processes.

## Command Shape

All commands accept `--host`. If omitted, `--host tars` is used.

```bash
bin/tesseract doctor
bin/tesseract live
bin/tesseract bootstrap
bin/tesseract services up|down|logs
bin/tesseract app list
bin/tesseract app doctor|clone|setup APP
bin/tesseract attach SESSION
bin/tesseract worktree list [APP]
bin/tesseract worktree create|start|stop|status|remove APP SLUG [BRANCH]
bin/tesseract dns doctor|sync APP
bin/tesseract cert doctor|issue|renew APP
```

Examples:

```bash
bin/tesseract app list
bin/tesseract live
bin/tesseract worktree list
bin/tesseract attach docovia_patientnow_integration --host tars
bin/tesseract worktree status docovia patientnow-integration
bin/tesseract worktree start flexday calendar-refresh --host tars
```

## Prerequisites

- SSH access to the runtime user, for example `bot@tars`.
- SSH access to the service user, for example `achan@tars`.
- Tailscale on the machine used to open remote apps in a browser.
- Docker access for the service user, not the runtime user.
- `mise`, `git`, `tmux`, `ruby`, and app-specific runtimes on the execution
  host.
- A Cloudflare API token with `Zone:Read` and `DNS:Edit` for `achan.bot` when
  running DNS or certificate commands.

`bin/tesseract dns sync` and `bin/tesseract cert issue|renew` read
`CLOUDFLARE_API_TOKEN` from the local environment and pass only the needed value
to the remote command.

If the token is assigned in `~/.zshrc` without `export`, run DNS and cert
commands through zsh:

```bash
zsh -lc 'source ~/.zshrc; export CLOUDFLARE_API_TOKEN; bin/tesseract dns sync docovia --host tars'
zsh -lc 'source ~/.zshrc; export CLOUDFLARE_API_TOKEN; bin/tesseract cert issue docovia --host tars'
```

## Host Bootstrap

Bootstrap creates runtime directories for the selected host and writes the
shared Docker Compose file for PostgreSQL and Redis.

```bash
bin/tesseract doctor --host tars
bin/tesseract bootstrap --host tars
bin/tesseract services up --host tars
bin/tesseract services logs --host tars
```

On `tars`, the shared services are defined at:

```text
/home/achan/.config/tesseract/services/compose.yml
```

The runtime registry and cert directories are:

```text
/home/bot/.local/share/tesseract/registry
/home/bot/.local/share/tesseract/certs
```

## App Setup

List configured apps:

```bash
bin/tesseract app list
```

Clone and prepare an app on the selected host:

```bash
bin/tesseract app clone docovia --host tars
bin/tesseract app setup docovia --host tars

bin/tesseract app clone flexday --host tars
bin/tesseract app setup flexday --host tars
```

`app setup` uses the app repository runtime files through `mise`; no global
runtime activation is required.

Check an app profile and remote clone:

```bash
bin/tesseract app doctor docovia --host tars
```

## Shared App Environment

Each app profile points at a shared env file on the host:

```text
docovia: /home/bot/repos/sprung-app/.env.local
flexday: /home/bot/repos/flexday/.env.local
```

Worktree creation links or copies from the app's shared env according to the
repo-local adapter. Keep real env files out of git and set permissions to
`0600`.

## DNS and Certificates

Sync app DNS records to the host's Tailscale IP:

```bash
bin/tesseract dns sync docovia --host tars
bin/tesseract dns doctor docovia --host tars

bin/tesseract dns sync flexday --host tars
bin/tesseract dns doctor flexday --host tars
```

Issue or inspect app certificates:

```bash
bin/tesseract cert issue docovia --host tars
bin/tesseract cert doctor docovia --host tars
bin/tesseract cert renew docovia --host tars
```

Certificates are installed under the host cert directory. For Docovia on `tars`:

```text
/home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.crt
/home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.key
```

## Worktree Lifecycle

List worktrees with their tmux session names and URLs:

```bash
bin/tesseract worktree list --host tars
bin/tesseract worktree list docovia --host tars
```

Attach to a worktree's tmux session:

```bash
bin/tesseract attach docovia_smoke_test --host tars
```

Create a worktree from the app repository default branch:

```bash
bin/tesseract worktree create docovia smoke-test --host tars
```

Create a worktree from a specific branch:

```bash
bin/tesseract worktree create docovia patientnow-integration origin/feature/patientnow-integration --host tars
```

Start, inspect, stop, and remove the worktree:

```bash
bin/tesseract worktree start docovia smoke-test --host tars
bin/tesseract worktree status docovia smoke-test --host tars
bin/tesseract worktree stop docovia smoke-test --host tars
bin/tesseract worktree remove docovia smoke-test --host tars
```

`stop` kills the app's tmux session and processes but leaves the worktree,
database, env files, and registry entry in place. `remove` is destructive: it
stops the session, removes the git worktree, prunes registry metadata, and lets
the repo-local adapter clean up app-specific state.

Worktree commands run this shape on the selected host:

```bash
cd <app main path>
exec ./bin/tesseract worktree <action> <slug> [branch]
```

That app-local handoff is why Docovia and Flexday can share the top-level
control plane while keeping different runtime details.

## Live Worktrees

Show currently running app worktrees and their URLs:

```bash
bin/tesseract live --host tars
```

Example output:

```text
APP        WORKTREE               URL
docovia    patientnow-integration https://app.docovia.tars.achan.bot:3102
docovia    text-expander          https://app.docovia.tars.achan.bot:3103
```

`live` scans each configured app's main clone, asks the repo-local adapter for
each worktree status, and prints worktrees with `running=yes` and a URL.

## Browser Access

Open the URL reported by `worktree status` or `live`.

Docovia URLs usually look like:

```text
https://app.docovia.tars.achan.bot:3101
https://api.docovia.tars.achan.bot:3101
```

Flexday URLs usually look like:

```text
http://flexday.tars.achan.bot:4001
```

If the browser reports `ERR_NAME_NOT_RESOLVED`, verify DNS first:

```bash
bin/tesseract dns doctor docovia --host tars
```

Some local resolvers cache earlier NXDOMAIN responses. Use a resolver such as
`1.1.1.1`, wait for cache expiry, or temporarily add host entries for the
Tailscale IP.

## Adding an App

Add a YAML file under `config/apps/` with at least:

```yaml
id: example
repo: git@github.com:owner/repo
main_path: /home/bot/repos/example
domain: example.tars.achan.bot
env_shared_path: /home/bot/repos/example/.env.local
```

The app repository must provide an executable `bin/tesseract` when it wants to
support worktree lifecycle commands through this control plane.

## Resetting Runtime State

Use these only when intentionally deleting remote runtime state.

Remove a worktree:

```bash
bin/tesseract worktree stop docovia smoke-test --host tars || true
bin/tesseract worktree remove docovia smoke-test --host tars || true
```

Remove the Docovia main clone and tesseract metadata on `tars`:

```bash
ssh bot@tars 'rm -rf \
  /home/bot/repos/sprung-app \
  /home/bot/repos/sprung-worktrees \
  /home/bot/.local/share/tesseract/registry/docovia.tsv \
  /home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.crt \
  /home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.key \
  /home/bot/.acme.sh/docovia.tars.achan.bot_ecc'
```

Reset shared PostgreSQL and Redis volumes:

```bash
ssh achan@tars 'cd /home/achan/.config/tesseract/services && docker compose -f compose.yml down -v'
```

Then start again from `Host Bootstrap`.
