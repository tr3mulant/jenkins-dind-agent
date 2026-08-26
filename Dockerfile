# Jenkins inbound (JNLP) agent: the official base image plus the Docker CLI.
#
# Based on jenkins/inbound-agent so the agent runtime, the `jenkins` user
# (uid 1000) and the connection entrypoint are already correct.
#
# No language toolchain here on purpose -- no PHP, Node, Python, Ruby. Build
# tooling belongs in the containers a pipeline starts, not on the agent:
#
#   - baking it in pins every job on this node to one version
#   - it adds third-party apt repos to keep working across base-image OS bumps
#   - a shared agent would need the union of every project's toolchain
#
# Pipelines should exec into their own containers instead. That is what the
# dind daemon in docker-compose.yml is for.
#
# git, bash, ssh and scp come from the base image; deploy stages need the last
# two.
#
# All three docker packages are required. Without docker-buildx-plugin, Compose
# falls back to the legacy builder and BuildKit-only Dockerfile features fail
# here while working on every developer machine, which ships buildx by default.
# That drift costs more than the features do. BuildKit itself runs in dockerd
# (the dind service); buildx is only the CLI plugin that drives it.

ARG JENKINS_AGENT_TAG=latest-jdk21
FROM jenkins/inbound-agent:${JENKINS_AGENT_TAG}

USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Client only. The daemon is the `dind` service in docker-compose.yml, reached
# over TLS via DOCKER_HOST -- there is no socket mounted here.
RUN curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /usr/share/keyrings/docker.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-compose-plugin \
        docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# Keep this. docker-compose.yml mounts a named volume here, and a named volume
# inherits ownership from the image path it covers -- without the chown it comes
# up root-owned and the agent (uid 1000) cannot write its workspace.
RUN mkdir -p /home/jenkins/agent \
    && chown -R jenkins:jenkins /home/jenkins

USER jenkins
