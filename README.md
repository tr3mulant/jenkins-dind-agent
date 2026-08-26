# Dockerized Jenkins agent

A long-lived inbound (JNLP) agent for the Dowscripts pipeline, plus a private
Docker daemon for it to build against.

The agent dials **out** to the controller at `test.irongateenterprises.com` over
HTTPS. The controller never connects back, so there is nothing to expose on this
host and no inbound firewall rule to add — including no port 50000, because
`JENKINS_WEB_SOCKET=true` tunnels the agent protocol over 443.

## Architecture

Two containers, siblings, not nested:

```
host
├── dowscripts-jenkins-agent   agent.jar, git, docker CLI. Runs no containers.
└── dowscripts-jenkins-dind    dockerd
    ├── laravel.test           composer, npm, php, artisan, PHPUnit
    └── pgsql
```

The agent is a Docker **client** only. It points at `dind` over TLS via
`DOCKER_HOST`, and every container the pipeline starts is a child of that
daemon. Nothing runs on the agent itself except `git`, `ssh`/`scp` for the
deploy, and the CLI.

The host's own daemon is deliberately out of reach. The Jenkins controller runs
on this same box, so a job that could talk to the host socket could read
`$JENKINS_HOME` and every credential in it — the registry login and the
production deploy key included.

### The one rule that matters

**`agent-workdir` is mounted at `/home/jenkins/agent` in both containers, and it
has to stay that way.**

Compose resolves bind mounts to absolute paths on the *client*, then hands those
paths to the daemon, which resolves them against *its own* filesystem.
`web/compose.yaml` mounts `.:/var/www/html` and `..:/var/www/repo` out of the
Jenkins workspace. If dind can't see that path, dockerd doesn't error — it
silently creates empty root-owned directories and mounts those instead.

Symptom: `composer install` fails on a missing `composer.json`, and the
root-owned debris defeats the pipeline's `cleanWs()`.

## Setup

**1. Create the node in Jenkins first.** The secret only exists after the node
does.

Manage Jenkins → Nodes → New Node:

| Field | Value |
| --- | --- |
| Name | `dowscripts-docker` |
| Type | Permanent Agent |
| Remote root directory | `/home/jenkins/agent` |
| Labels | `php84` |
| Usage | Use this node as much as possible |
| Launch method | **Launch agent by connecting it to the controller** |

The label must match the Jenkinsfile's `agent { label 'php84' }`. It's a fossil
— there is no PHP on this agent any more — but a mismatch doesn't fail the
build, it leaves the job queued indefinitely with no error. Rename in both
places or neither.

Save, reopen the node, and copy the secret from the connection instructions.

Under Manage Jenkins → Security, confirm **WebSocket** is permitted for inbound
agents. (To use the TCP port instead, set `JENKINS_WEB_SOCKET=false` and open
50000 to this host.)

**2. Copy this whole directory to the server.** The compose file builds from
`Dockerfile` in the same directory (`context: .`), so the compose file alone
isn't enough.

```sh
scp -r Dowscripts-jenkins-agent/ test.irongateenterprises.com:~/
```

**3. Configure and start.**

```sh
cd ~/Dowscripts-jenkins-agent
cp .env.example .env
chmod 600 .env          # holds the agent secret
$EDITOR .env            # set JENKINS_SECRET

docker compose up -d --build
docker compose logs -f agent
```

The node goes green in Jenkins once `INFO: Connected` appears.

**4. Verify the workspace path before running a build.**

```sh
docker compose exec agent sh -c '
  mkdir -p /home/jenkins/agent/probe && date > /home/jenkins/agent/probe/stamp &&
  docker run --rm -v /home/jenkins/agent/probe:/p alpine cat /p/stamp'
docker compose exec agent rm -rf /home/jenkins/agent/probe
```

A date means bind mounts resolve coherently between the agent and dind. `cat:
/p/stamp: No such file or directory` means they don't — fix the volume mounts
before running a build, or it will scatter root-owned directories.

## Troubleshooting

### "Handshake error" / "Did not receive X-Remoting-Capability header"

The agent reached Jenkins but fell back to the TCP transport, which modern
Jenkins ships **disabled** — `/tcpSlaveAgentListener/` then 404s. Confirm with:

```sh
docker compose exec agent curl -sSI "$JENKINS_URL"tcpSlaveAgentListener/
```

A 404 carrying `X-Jenkins:` headers means Jenkins is fine and the transport is
the problem — the agent must use WebSocket instead.

**Check the reverse proxy before chasing the agent flag.** Apache terminates TLS
on this server and proxies 443 to `localhost:8080` using plain `mod_proxy_http`,
which cannot forward the WebSocket `Upgrade` handshake. With the TCP port
disabled *and* WebSocket blocked at the proxy, both transports are closed and no
agent-side setting will help.

The fix is one directive in the `*:443` vhost. On Apache >= 2.4.47 (this server
runs 2.4.52) `mod_proxy_http` forwards the upgrade itself via `upgrade=websocket`
— no `mod_proxy_wstunnel`, and no separate `/wsagents/` rule to mis-order:

```apache
ProxyTimeout 3600
ProxyPass / http://localhost:8080/ nocanon upgrade=websocket
```

`upgrade=websocket` belongs on the `http://` catch-all. Putting it on a `ws://`
wstunnel rule is a no-op — that combination looks plausible and silently does
nothing. Then `sudo apachectl configtest && sudo systemctl reload apache2`.
Nothing changes on the agent side.

Verify the proxy independently of the agent:

```sh
curl -sS -i -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  https://test.irongateenterprises.com/wsagents/ | head -20
```

`400 This endpoint is only for use from agent.jar in WebSocket mode`, served by
Jetty, means the proxy is **working** — curl isn't agent.jar, so Jenkins rejects
it. An Apache `404`/`503` without `X-Jenkins` headers means it isn't.

Once the proxy is confirmed, a persisting handshake error means Jenkins is
rejecting the agent itself: check that the node name matches
`JENKINS_AGENT_NAME` exactly and that `JENKINS_SECRET` is current.

This also unblocks agents on machines other than the controller, which the
alternative — bypassing Apache via `host.docker.internal:8080`, see below —
does not.

To confirm the flag itself reached the agent:

```sh
docker compose exec agent sh -c 'for p in /proc/[0-9]*/cmdline; do tr "\0" " " < $p; echo; done' | grep agent.jar
```

If `-webSocket` is missing, pass it explicitly — the entrypoint appends `"$@"`:
`command: ["-webSocket"]`. Don't add it when already present; args4j rejects the
duplicate.

### If the agent runs on the controller's own host

The public hostname resolves to your public IP, so a container on that same host
has to hairpin back through the router to reach it — and many routers won't.
The URL works from a browser while the agent hangs on connect. Uncomment one of
the `extra_hosts` blocks in `docker-compose.yml`: either pin
`test.irongateenterprises.com` to `host-gateway`, or point `JENKINS_URL` at
`http://host.docker.internal:8080/` and bypass the reverse proxy entirely.

### Pre-build fails: "cannot reach a daemon"

The agent's `DOCKER_HOST` points at dind and dind isn't up or healthy.

```sh
docker compose ps                     # dind should be (healthy)
docker compose logs dind
docker compose exec agent docker version
```

`depends_on: service_healthy` normally prevents this — the agent shouldn't start
until dind has generated its TLS certs and dockerd is listening.

### `docker push` fails with "x509: certificate signed by unknown authority"

The dind daemon is new and doesn't trust your registry's CA, even if the host
daemon does. Mount the host's copy into dind:

```yaml
      - /etc/docker/certs.d:/etc/docker/certs.d:ro
```

### Pulls inside dind hang partway

Nested bridge networking on a tunnelled link. Lower the MTU on the dind service:

```yaml
    command: ["--mtu=1400"]
```

## What's in the image

The Docker CLI and the compose plugin. That's it.

`git`, `bash`, `ssh` and `scp` come from the `jenkins/inbound-agent` base — the
Deploy stage needs the last two.

**No PHP, Composer or Node, on purpose.** Every one of those runs inside the
`laravel.test` container, never on the agent: check
`scripts/ci/jenkins-step1-build-test-containers.sh` and note that every call
goes through its `appexec()` helper, which is `compose exec … laravel.test`.
A toolchain here would be ~1GB nothing invokes, plus two third-party apt repos
(Sury, NodeSource) to keep working across Debian releases.

This also settles the old "which PHP does CI test?" question — the suite runs on
whatever `web/compose.yaml` builds, which is the same runtime developers use.

## Operations

```sh
docker compose logs -f agent    # connection troubleshooting
docker compose logs -f dind     # build/daemon troubleshooting
docker compose up -d --build    # rebuild after changing the Dockerfile
docker compose down             # stop (node shows offline in Jenkins)

docker volume rm dowscripts-jenkins-agent_agent-workdir   # wipe workspaces
docker volume rm dowscripts-jenkins-agent_docker-lib      # wipe the layer cache
```

Don't run `docker compose down -v` casually — it takes `docker-lib` with it, and
the next build recompiles the whole production PHP layer from scratch.

Rotate the secret by deleting and recreating the node in Jenkins, then updating
`.env` and running `docker compose up -d`.

Tests run on in-memory sqlite; there is no database service here to start. See
the comment at the bottom of `docker-compose.yml` for why, and for the one thing
not to do (point CI at the app's own Postgres).
