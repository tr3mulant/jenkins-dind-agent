# jenkins-dind-agent

A long-lived Jenkins inbound agent plus a private Docker daemon for it to build
on. One shared node, any number of jobs.

The agent dials **out** to the controller over HTTPS. The controller never
connects back, so there is nothing to expose on this host and no inbound
firewall rule to add — including no port 50000, because `JENKINS_WEB_SOCKET=true`
tunnels the agent protocol over 443.

> This is an **inbound (JNLP)** agent, not Jenkins' "SSH agent" launch method.
> Those are opposites: an SSH agent means the controller connects _in_ to a
> listening sshd. Nothing here listens. `ssh` and `scp` are in the image for
> pipelines that deploy over SSH, not for the agent's own connection.

## Architecture

Two containers, siblings, not nested:

```
host
├── <stack>-agent    agent.jar, git, docker CLI. Runs no containers.
└── <stack>-dind     dockerd
    └── …            every container your pipelines start
```

The agent is a Docker **client** only. It points at `dind` over TLS via
`DOCKER_HOST`, and every container a pipeline starts is a child of that daemon.

The host's own daemon is deliberately out of reach. If the Jenkins controller
shares this box, a job that could talk to the host socket could read
`$JENKINS_HOME` and every credential in it.

### The one rule that matters

**`agent-workdir` is mounted at `/home/jenkins/agent` in both containers, and it
has to stay that way.**

Compose resolves bind mounts to absolute paths on the _client_, then hands those
paths to the daemon, which resolves them against _its own_ filesystem. Any
pipeline that bind-mounts its workspace into a container — the common case — is
relying on both sides agreeing on that path.

If dind can't see it, dockerd doesn't error. It silently creates empty
root-owned directories and mounts those instead, so the job fails somewhere that
points nowhere near the cause, and the root-owned debris defeats `cleanWs()`.

## Setup

**1. Create the node in Jenkins first.** The secret only exists after the node
does.

Manage Jenkins → Nodes → New Node:

| Field                 | Value                                               |
| --------------------- | --------------------------------------------------- |
| Name                  | matches `JENKINS_AGENT_NAME` in `.env`              |
| Type                  | Permanent Agent                                     |
| Remote root directory | `/home/jenkins/agent`                               |
| Labels                | whatever your Jenkinsfiles ask for                  |
| # of executors        | `1` (see _Sharing one agent_)                       |
| Usage                 | Use this node as much as possible                   |
| Launch method         | **Launch agent by connecting it to the controller** |

Labels are how jobs find this node. A Jenkinsfile asking for a label the node
doesn't carry doesn't fail — it queues indefinitely with no error, so check both
sides match.

Save, reopen the node, and copy the secret from the connection instructions.

Under Manage Jenkins → Security, confirm **WebSocket** is permitted for inbound
agents. (To use the TCP port instead, set `JENKINS_WEB_SOCKET=false` and open
50000 to this host.)

**2. Copy this directory to the host.** The compose file builds from
`Dockerfile` beside it (`context: .`), so the compose file alone isn't enough.

**3. Configure and start.**

```sh
cp .env.example .env
chmod 600 .env          # holds the agent secret
$EDITOR .env            # JENKINS_URL, JENKINS_AGENT_NAME, JENKINS_SECRET

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

## What pipelines can assume

The agent has `docker`, `docker compose`, `git`, `bash`, `ssh` and `scp`. That
is the whole toolchain.

**No language runtimes, and don't add any.** Install nothing on the agent —
start a container and exec into it. A shared node carrying every project's
toolchain would need the union of all of them, pinned to one version each, and
every project would be stuck with whichever version won.

```groovy
// Instead of `sh 'composer install'` on the agent:
sh 'docker compose exec -T -u 1000 app composer install'
```

Note the `-u`: `docker compose exec` ignores the image's entrypoint and runs as
the image's configured user, which is often root. Without it, builds write
root-owned files into the workspace and `cleanWs()` can't remove them.

## Sharing one agent

Every job on this node shares one dind daemon. That buys a warm layer cache
across projects, and costs some isolation:

- **Compose project names must be unique per job.** Set `COMPOSE_PROJECT_NAME`
  in each Jenkinsfile. Two jobs defaulting to the directory name will tear down
  each other's containers.
- **Published ports are shared.** They bind inside dind's network namespace, not
  the host's — which is why nothing leaks to the outside — but that namespace is
  common to every concurrent job. Two jobs publishing the same port collide.
- **`docker login` state is shared.** A `docker logout` in one job's `post`
  block pulls the credential out from under another job running concurrently.
- **Memory is shared.** `BUILD_MEM_LIMIT` caps the daemon, so it caps all
  concurrent builds together, not each one.

Start with **1 executor**. Raise it only after the jobs that would run
concurrently have been checked against the four points above.

## Troubleshooting

### "Handshake error" / "Did not receive X-Remoting-Capability header"

The agent reached Jenkins but fell back to the TCP transport, which modern
Jenkins ships **disabled** — `/tcpSlaveAgentListener/` then 404s. Confirm with:

```sh
docker compose exec agent curl -sSI "$JENKINS_URL"tcpSlaveAgentListener/
```

A 404 carrying `X-Jenkins:` headers means Jenkins is fine and the transport is
the problem — the agent must use WebSocket instead.

**Check the reverse proxy before chasing the agent flag.** If Apache terminates
TLS and proxies to `localhost:8080` with plain `mod_proxy_http`, it cannot
forward the WebSocket `Upgrade` handshake. With the TCP port disabled _and_
WebSocket blocked at the proxy, both transports are closed and no agent-side
setting will help.

The fix is one directive in the `*:443` vhost. On Apache >= 2.4.47
`mod_proxy_http` forwards the upgrade itself via `upgrade=websocket` — no
`mod_proxy_wstunnel`, and no separate `/wsagents/` rule to mis-order:

```apache
ProxyTimeout 3600
ProxyPass / http://localhost:8080/ nocanon upgrade=websocket
```

`upgrade=websocket` belongs on the `http://` catch-all. Putting it on a `ws://`
wstunnel rule is a no-op — that combination looks plausible and silently does
nothing. Then `apachectl configtest && systemctl reload apache2`. Nothing
changes on the agent side.

Verify the proxy independently of the agent:

```sh
curl -sS -i -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  https://jenkins.example.com/wsagents/ | head -20
```

`400 This endpoint is only for use from agent.jar in WebSocket mode`, served by
Jetty, means the proxy is **working** — curl isn't agent.jar, so Jenkins rejects
it. An Apache `404`/`503` without `X-Jenkins` headers means it isn't.

Once the proxy is confirmed, a persisting handshake error means Jenkins is
rejecting the agent itself: check that the node name matches
`JENKINS_AGENT_NAME` exactly and that `JENKINS_SECRET` is current.

Fixing the proxy also unblocks agents on machines other than the controller,
which the `host.docker.internal` workaround below does not.

To confirm the flag itself reached the agent:

```sh
docker compose exec agent sh -c 'for p in /proc/[0-9]*/cmdline; do tr "\0" " " < $p; echo; done' | grep agent.jar
```

If `-webSocket` is missing, pass it explicitly — the entrypoint appends `"$@"`:
`command: ["-webSocket"]`. Don't add it when already present; args4j rejects the
duplicate.

### The agent hangs on connect, but the URL works in a browser

The agent is on the controller's own host. The public hostname resolves to your
public IP, so the container has to hairpin back through the router — and many
routers refuse. Uncomment an `extra_hosts` entry on the `agent` service: pin the
hostname to `host-gateway`, or point `JENKINS_URL` at
`http://host.docker.internal:8080/` and bypass the proxy entirely.

### A stage fails with "cannot reach a daemon"

`DOCKER_HOST` points at dind and dind isn't up or healthy.

```sh
docker compose ps                     # dind should be (healthy)
docker compose logs dind
docker compose exec agent docker version
```

`depends_on: service_healthy` normally prevents this — the agent shouldn't start
until dind has generated its TLS certs and dockerd is listening.

### `docker push` fails with "x509: certificate signed by unknown authority"

The dind daemon is new and doesn't trust your registry's CA, even if the host
daemon does. Uncomment the `/etc/docker/certs.d` mount on the `dind` service.

### Pulls inside dind hang partway

Nested bridge networking on a tunnelled link. Uncomment
`command: ["--mtu=1400"]` on the `dind` service.

### A build fails with an empty workspace inside its container

The workspace path invariant is broken. Run the step 4 probe.

## Operations

```sh
docker compose logs -f agent    # connection troubleshooting
docker compose logs -f dind     # build/daemon troubleshooting
docker compose up -d --build    # rebuild after changing the Dockerfile
docker compose down             # stop (node shows offline in Jenkins)

docker volume rm ${STACK_NAME}_agent-workdir   # wipe workspaces
docker volume rm ${STACK_NAME}_docker-lib      # wipe the layer cache
```

Don't run `docker compose down -v` casually — it takes `docker-lib` with it, and
every job's next build starts with a cold cache.

Rotate the secret by deleting and recreating the node in Jenkins, then updating
`.env` and running `docker compose up -d`.
