# Jenkins inbound (JNLP) agent for this repo.
#
# Based on the official inbound-agent image so the agent runtime, the `jenkins`
# user (uid 1000) and the connection entrypoint are already correct. The only
# thing layered on top is the Docker CLI.
#
# No PHP, Composer or Node here on purpose: every one of those runs inside the
# laravel.test container the pipeline starts, never on the agent. See
# scripts/ci/jenkins-step1-build-test-containers.sh -- every call goes through
# its appexec() helper. Adding a toolchain here builds ~1GB nothing invokes.
#
# git, bash, ssh and scp come from the base image; the Deploy stage needs the
# last two.

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
    && rm -rf /var/lib/apt/lists/*

# Keep this. docker-compose.yml mounts a named volume here, and a named volume
# inherits ownership from the image path it covers -- without the chown it comes
# up root-owned and the agent (uid 1000) cannot write its workspace.
RUN mkdir -p /home/jenkins/agent \
    && chown -R jenkins:jenkins /home/jenkins

USER jenkins
