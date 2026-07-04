# Development Architecture

## Purpose

This document describes the intended development architecture for doing primary
full-stack Rails work from this MacBook while running coding agents and app
processes on remote machines.

The repository implements the first version of this architecture as the
`tesseract` CLI. Commands are designed to be idempotent where practical and to
keep host-specific behavior behind explicit host and app profiles.

## Machine Roles

### MacBook

The MacBook is the control plane.

- Primary terminal and browser live here.
- Commands are usually initiated here.
- Source may exist here for local work, but remote hosts keep their own clones.
- Browser access to remote Rails apps happens over the private network using
  app-specific development domains and explicit ports.

### `tars`

`tars` is the default execution host.

- Runs coding agents for normal Rails development.
- Runs app servers, workers, asset servers, PostgreSQL, and Redis for remote
  worktree sessions.
- Is reached over SSH and Tailscale.
- Is the default target for `tesseract` commands.

### `case`

`case` is a future macOS execution host.

- Intended for coding agents that need macOS.
- Intended for agentic computer-use workflows.
- Not designed in detail yet.
- Should eventually fit the same host/profile model as `tars`.

## Core Model

The architecture has five primitives:

1. Host profiles
2. App profiles
3. Worktree sessions
4. Shared host services
5. `tesseract`, the personal control CLI

The important boundary is that infrastructure is shared by host, while app
behavior is described by explicit app profiles. No single Rails app should be
hardcoded into the architecture.

## `tesseract`

`tesseract` is the intended personal development control CLI.

It should always accept a `--host` parameter. If omitted, `--host` defaults to
`tars`.

Examples:

```bash
tesseract doctor
tesseract doctor --host tars
tesseract app clone docovia
tesseract worktree create docovia no-show
tesseract worktree start docovia no-show
tesseract worktree status docovia no-show
tesseract worktree remove docovia no-show
```

The normal operating model is:

- Run `tesseract` from the MacBook.
- `tesseract` connects to the selected host over SSH.
- Remote tasks execute on that host.

The same CLI should also be installable on remote hosts. When `tesseract` is run
from the selected host itself, it should execute locally instead of SSHing back
into the same machine.

## Host Profiles

A host profile describes a machine that can run development workloads.

For `tars`, the profile should eventually include:

- Host id: `tars`
- SSH target: `bot@tars`
- Default user: `bot`, configurable per host profile
- Service user: `achan`, configurable per host profile, used for Docker-backed
  host services
- Role: default Rails and coding-agent execution host
- Tailscale identity and IP
- Base repo path: `~/repos`
- Service backend: shared Docker Compose stack
- Default shell/session tool: `tmux`

`case` should eventually get its own host profile, but it is out of scope for
the first implementation phase.

## App Profiles

An app profile describes one Rails application.

Each Rails app should have its own explicit profile containing:

- App id
- Git remote
- Main clone path on each host
- Worktree root path on each host
- Custom development domain
- Base port or port range
- Runtime versions
- Database naming rules
- Redis DB allocation rules
- Secret template source
- Process commands for web, workers, asset servers, and agents

This is the mechanism for supporting multiple apps. Docovia is only one app
profile, not a hardcoded namespace.

## Source Code Topology

Source code should be cloned independently on each machine.

- The MacBook has its own clones.
- `tars` has its own clones.
- `case` will have its own clones later.
- GitHub is the sync boundary.
- Source should not be network-mounted between machines.

This keeps file watching, Ruby tooling, Node tooling, and agent edits local to
the machine doing the work.

## Worktree Sessions

A worktree session is the unit of active development.

Each worktree session should have:

- One git worktree
- One tmux session
- One assigned app port
- One PostgreSQL database
- One Redis DB index
- One worktree-specific environment override file
- One coding-agent pane
- One Rails server pane
- One worker pane
- One asset-server pane, when the app needs it

Worktree sessions isolate feature work without requiring separate operating
system users or per-worktree containers.

## Shared Host Services

Each execution host should provide shared services for all worktrees on that
host.

For `tars`, the intended first implementation is one machine-level Docker
Compose stack:

- PostgreSQL using `pgvector/pgvector:pg14`, bound to `127.0.0.1:5432`
- Redis using `redis:7-alpine`, bound to `127.0.0.1:6379`

Worktrees share these server processes but use separate databases and Redis DB
indexes.

This avoids per-worktree Compose overhead while keeping app data separated.
The runtime user `bot` should not be a member of the Docker group. Docker access
is effectively root on the host, so service management is delegated to the
separate `service_user` instead.

## Ports, Databases, and Redis

Each app profile owns a port range.

For each worktree:

- Allocate the next available port in the app's range.
- Create a deterministic database name from the app id and worktree slug.
- Assign a Redis DB index derived from the port or recorded allocation.
- Record the assignment so stop/status/remove commands are deterministic.

The exact registry format is an implementation detail, but it should be
machine-local and human-readable.

## Domains and Browser Access

Rails apps may depend on subdomains. Browser access should preserve those
subdomains.

The default access pattern is:

```text
https://<subdomain>.<app-dev-domain>:<port>
```

This keeps app routing behavior realistic while avoiding a reverse proxy in the
first implementation.

Each app may define a custom development domain. There is no requirement that
all apps use the same pattern.

## Secrets

Secrets should be generated from 1Password templates.

The intended behavior is:

- Store secret values in 1Password.
- Use `op inject` or an equivalent template flow to generate local env files on
  each host.
- Keep generated env files out of git.
- Set generated env file permissions to `0600`.
- Never print raw secret values in `tesseract` output.

Raw `.env.local` files should not be copied manually between machines.

## Docovia Example Profile

Docovia is the first example app profile.

It is an example only. Future apps should be added by creating additional app
profiles, not by changing core `tesseract` behavior.

Example profile values:

- App id: `docovia`
- Git remote: `git@github.com:getsprung/app`
- Main path on `tars`: `/home/bot/repos/sprung-app`
- Worktree root on `tars`: `/home/bot/repos/sprung-worktrees`
- Development domain: `docovia.tars.achan.bot`
- Base port: `3100`
- Example worktree port range: `3101-3199`
- Runtime versions: read from repo files such as `.ruby-version` and `.nvmrc`

Example browser URLs for a worktree on port `3101`:

```text
https://app.docovia.tars.achan.bot:3101
https://api.docovia.tars.achan.bot:3101
https://gfease.docovia.tars.achan.bot:3101
```

Example worktree environment override values:

```dotenv
APP_DOMAIN=docovia.tars.achan.bot
DASHBOARD_DOMAIN=app.docovia.tars.achan.bot
APP_PORT=:3101
PORT=3101
DATABASE_NAME=sprung_dev_worktree_no_show
PGHOST=127.0.0.1
PGUSER=bot
REDIS_URL=redis://127.0.0.1:6379/1
WEBSITE_URL=https://app.docovia.tars.achan.bot:3101
API_URL=https://api.docovia.tars.achan.bot:3101
```

Example process commands:

```bash
bundle exec rails s -p {port} -b "ssl://app.{domain}?key=app.key&cert=app.crt"
bundle exec rails jobs:work
bin/webpack-dev-server
claude
```

## Intended Command Surface

The command names below describe the implemented first-pass interface.

```bash
tesseract doctor [--host tars]
tesseract bootstrap [--host tars]
tesseract services up [--host tars]
tesseract services down [--host tars]
tesseract services logs [--host tars]

tesseract app list [--host tars]
tesseract app clone <app> [--host tars]
tesseract app doctor <app> [--host tars]
tesseract app setup <app> [--host tars]

tesseract worktree create <app> <slug> [branch] [--host tars]
tesseract worktree start <app> <slug> [--host tars]
tesseract worktree stop <app> <slug> [--host tars]
tesseract worktree status <app> <slug> [--host tars]
tesseract worktree remove <app> <slug> [--host tars]

tesseract dns sync <app> [--host tars]
tesseract dns doctor <app> [--host tars]

tesseract cert doctor <app> [--host tars]
tesseract cert issue <app> [--host tars]
tesseract cert renew <app> [--host tars]
```

## Acceptance Checklist

The implementation should continue to satisfy these architectural requirements:

- MacBook as control plane
- `tars` as default execution host
- `case` as future macOS/computer-use host
- `tesseract` as the intended CLI name
- `--host` accepted by every command, defaulting to `tars`
- Multiple apps through explicit app profiles
- Docovia as an example profile only
- Independent clones per machine
- Shared PostgreSQL and Redis per host
- Per-worktree isolation through worktrees, ports, databases, Redis DBs, env
  overrides, and tmux sessions
- 1Password-based secret generation
