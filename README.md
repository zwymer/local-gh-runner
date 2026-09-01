# local-gh-runner

Ephemeral, self-hosted GitHub Actions runners in Docker, on this workstation.

Two fleets share this directory and the same GitHub App credentials in `.env`:

| Fleet       | Repo              | Compose project       | Containers                                  |
| ----------- | ----------------- | --------------------- | ------------------------------------------- |
| `edtok`     | `zwymer/EdTok`    | `local-gh-runner`     | `gh-runner-1`, `gh-runner-2`, `gh-runner-prod` |
| `leetspeak` | `zwymer/leetspeak`| `leetspeak-gh-runner` | `ls-gh-runner-1..3`                          |

`gh-runner-prod` carries the `edtok-production` label. EdTok's `deploy.yml`
schedules its promotion job on that label alone, so **if that container is
missing, EdTok cannot ship.**

## Running a fleet

Always go through the wrapper. It supplies the project name and the `-f` list,
and puts Docker's bin directory on `PATH` (see [wincred](#gotchas)).

```powershell
./fleet.ps1 edtok up -d          # start the EdTok fleet
./fleet.ps1 edtok ps             # what is running
./fleet.ps1 edtok down           # stop it
./fleet.ps1 leetspeak up -d      # the other fleet
./fleet.ps1 edtok up -d --build  # after editing the Dockerfile
```

Git Bash: `./fleet.sh edtok up -d` — same arguments.

There is deliberately **no `docker-compose.yml`**. A bare `docker compose ...`
in this directory now fails with "no configuration file provided" instead of
silently selecting a fleet. `compose.base.yml` alone is inert too: its project
name is a sentinel that matches nothing.

That is not defensive over-engineering. The EdTok fleet disappeared between
2026-08-31 and 2026-09-01 — containers, project-built images and named volumes
all gone, no reboot, no crash, unrelated images untouched. That is the blast
radius of a scoped teardown of this project, and back then a flagless
`docker compose down` here *was* the EdTok fleet. It went unnoticed until a
production promotion had no runner to schedule on.

## Watchdog

`restart: unless-stopped` covers a crashed container and an engine restart. It
cannot resurrect a container that no longer exists. The watchdog covers that.

```powershell
./install-watchdog.ps1                        # every 15 min + at logon, edtok
./install-watchdog.ps1 -Fleet edtok,leetspeak # both fleets
./watchdog.ps1 -WhatIfOnly                    # dry run, no changes
./install-watchdog.ps1 -Uninstall
```

It is conservative by design:

- Acts **only on absent containers.** An existing-but-stopped container is left
  alone: `unless-stopped` means a manual stop was intentional, and ephemeral
  runners exit between jobs by design. Recreating one mid-job would kill a
  running deploy.
- If the Docker engine is unreachable it starts Docker Desktop and returns; the
  next tick does the rest.
- The GitHub registration check is **advisory**. If the containers are up but no
  runner is registered, `up -d` is a no-op anyway, so it logs and leaves it.

Logs to `watchdog.log` (gitignored, truncated at 1 MB).

The task runs only while you are logged on — it needs your Docker Desktop engine
and your `gh` credentials, neither of which exists in a SYSTEM session.

Also make sure Docker Desktop itself starts at sign-in (Settings → General →
"Start Docker Desktop when you sign in"). Without it, a reboot leaves no engine,
and `restart: unless-stopped` has nothing to run in.

## Gotchas

**`docker-credential-wincred` not found.** It lives in
`C:\Program Files\Docker\Docker\resources\bin`, which is not on `PATH` in Git
Bash or PowerShell. Without it every build dies resolving image metadata with an
opaque `error getting credentials` that looks nothing like a `PATH` problem. Both
wrappers prepend it.

**apt fails at the first `apt-get update`.** Mullvad's DNS-leak protection
SERVFAILs `archive.ubuntu.com` and `security.ubuntu.com` host-wide while
everything else resolves fine, so the build dies with `Unable to locate package
curl`. Either point the build at another mirror, or resolve the two hosts over
DoH (port 443 is allowed) and pin them:

```powershell
$a = (Invoke-RestMethod "https://dns.google/resolve?name=archive.ubuntu.com&type=A").Answer[0].data
$s = (Invoke-RestMethod "https://dns.google/resolve?name=security.ubuntu.com&type=A").Answer[0].data
docker build --add-host archive.ubuntu.com:$a --add-host security.ubuntu.com:$s `
  -t local-gh-runner-runner-1 -t local-gh-runner-runner-2 -t local-gh-runner-runner-prod .
./fleet.ps1 edtok up -d
```

Note the destructive-`down`-then-failing-`build` trap: the documented refresh is
`down && up -d --build`, but if the rebuild cannot reach the archive you are left
with no fleet at all. Build first, then `up -d`.

**Stale offline registrations.** Ephemeral runners deregister cleanly on
`SIGTERM`, so a normal cycle leaves nothing behind. Ghost `offline` entries mean
containers died without a clean stop. They are harmless — an offline runner takes
no jobs — but they clutter the deploy pre-flight. Clear them with:

```bash
gh api -X DELETE repos/zwymer/EdTok/actions/runners/<id>
```

## Setup

1. `cp .env.example .env` and fill in the GitHub App credentials.
2. Build the image (see the Mullvad note above).
3. `./fleet.ps1 edtok up -d`
4. `./install-watchdog.ps1`
