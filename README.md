# Dockerized Jenkins agent

A long-lived inbound (JNLP) agent carrying this repo's toolchain: PHP, Composer,
Node, and the Docker CLI.

The agent dials **out** to the controller at `test.irongateenterprises.com` over
HTTPS. The controller never connects back, so there is nothing to expose on this
host and no inbound firewall rule to add — including no port 50000, because
`JENKINS_WEB_SOCKET=true` tunnels the agent protocol over 443.

## Setup

**1. Create the node in Jenkins first.** The secret only exists after the node
does.

Manage Jenkins → Nodes → New Node:

| Field | Value |
| --- | --- |
| Name | `dowscripts-docker` |
| Type | Permanent Agent |
| Remote root directory | `/home/jenkins/agent` |
| Labels | `docker php node` |
| Usage | Use this node as much as possible |
| Launch method | **Launch agent by connecting it to the controller** |

Save, reopen the node, and copy the secret from the connection instructions.

Under Manage Jenkins → Security, confirm **WebSocket** is permitted for inbound
agents. (If you'd rather use the TCP port, set `JENKINS_WEB_SOCKET=false` and
open 50000 to this host.)

**2. Copy this whole directory to the server.** The compose file builds from
`Dockerfile` in the same directory (`context: .`), so the compose file alone
isn't enough.

```sh
scp -r ci/jenkins-agent/ test.irongateenterprises.com:~/
```

**3. Configure and start.**

```sh
cd ~/jenkins-agent
cp .env.example .env
chmod 600 .env          # holds the agent secret
$EDITOR .env            # set JENKINS_SECRET

docker compose up -d --build
docker compose logs -f agent
```

The node goes green in Jenkins once `INFO: Connected` appears.

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
alternative — bypassing Apache via `host.docker.internal:8080`, see the next
section — does not.

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

## What's in the image

| | | Why |
| --- | --- | --- |
| PHP | 8.4 (`PHP_VERSION`) | `composer.json` requires `>=8.2` |
| Extensions | ctype curl dom fileinfo filter hash iconv json libxml mbstring pcre xmlreader zip | hard `require` entries in `composer.lock` |
| | bcmath gd intl pcov pgsql sqlite3 | coverage, deploys, tests |
| Composer | 2.x | checksum-verified official installer |
| Node | 22 (`NODE_MAJOR`) | Vite 7 needs `^20.19 \|\| >=22.12` |
| Docker CLI + compose | latest | inert unless the socket is mounted |

**PHP version mismatch worth deciding on.** The default is 8.4, matching the
workstation this repo is developed on. But `web/compose.yaml` builds the Sail
**8.5** runtime, so CI currently tests one minor version behind what deploys.
Set `PHP_VERSION=8.5` in `.env` and rebuild to close that gap — worth doing once
you've confirmed the suite passes on 8.5 locally.

## Pipeline notes

Tests run on in-memory sqlite; there is no database service to start. See the
comment at the bottom of `docker-compose.yml` for why, and for the one thing not
to do (point CI at the app's own Postgres).

```groovy
pipeline {
    agent { label 'docker' }
    environment {
        DB_CONNECTION = 'sqlite'
        DB_DATABASE   = ':memory:'
    }
    stages {
        stage('Install') {
            steps {
                sh 'composer install --no-interaction --prefer-dist --no-progress'
                dir('web') {
                    sh 'composer install --no-interaction --prefer-dist --no-progress'
                    sh 'npm ci'
                }
            }
        }
        stage('Build assets') {
            steps { dir('web') { sh 'npm run build' } }
        }
        stage('Test') {
            steps {
                dir('web') {
                    sh 'cp -n .env.example .env || true'
                    sh 'php artisan key:generate'
                    sh 'php artisan test'
                }
            }
        }
    }
}
```

Composer and npm caches persist in named volumes, so `composer install` and
`npm ci` only pay full download cost on the first run.

## Giving pipelines access to Docker

Deploy stages that build images or roll `web/compose.yaml` need the host's
Docker daemon. Uncomment the `docker.sock` mount and `group_add` in
`docker-compose.yml`, and set `DOCKER_GID` in `.env`:

```sh
getent group docker | cut -d: -f3
```

Understand the trade: mounting the socket gives anyone who can run a job on this
agent effective root on the host. Only do it if every job on this node is
trusted.

## Operations

```sh
docker compose logs -f agent          # connection troubleshooting
docker compose up -d --build          # rebuild after changing PHP/Node versions
docker compose down                   # stop (node shows offline in Jenkins)
docker volume rm dowscripts-jenkins-agent_agent-workdir   # wipe workspaces
```

Rotate the secret by deleting and recreating the node in Jenkins, then updating
`.env` and running `docker compose up -d`.
