# Jenkins inbound (JNLP) agent carrying this repo's toolchain.
#
# Based on the official inbound-agent image so the agent runtime, the `jenkins`
# user (uid 1000) and the connection entrypoint are already correct -- everything
# below is just PHP/Composer/Node layered on top.

ARG JENKINS_AGENT_TAG=latest-jdk21
FROM jenkins/inbound-agent:${JENKINS_AGENT_TAG}

# 8.4 is what this repo is developed and tested on today. web/compose.yaml runs
# the Sail 8.5 runtime, so set PHP_VERSION=8.5 in .env once you want CI to test
# the version that actually ships. Both satisfy the ">=8.2" in composer.json.
ARG PHP_VERSION=8.4
# Vite 7 (web/package.json) requires Node ^20.19 || >=22.12.
ARG NODE_MAJOR=22

USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        unzip \
        zip \
    && rm -rf /var/lib/apt/lists/*

# Debian bookworm only ships PHP 8.2. Sury is the standard third-party repo and
# is what makes pinning an exact PHP version possible.
RUN curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/sury-php.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
        > /etc/apt/sources.list.d/sury-php.list

# Extension set is derived from the hard `require` entries in composer.lock:
# ctype, fileinfo, filter, hash, iconv, json and pcre are built into -cli;
# -xml covers dom/libxml/simplexml/xmlreader; -zip is needed by openspout.
# -sqlite3 is what the test suite actually runs on (in-memory); -pgsql is here
# so a deploy stage can run artisan against the real Postgres 18 the app uses.
# -bcmath/-gd/-intl are not hard requirements
# but Laravel and the marketplace SDKs reach for them often enough to include.
# -pcov drives `composer test:coverage`; it's the low-overhead coverage driver,
# so use it rather than Xdebug unless you need step debugging on the agent.
RUN apt-get update && apt-get install -y --no-install-recommends \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-pcov \
        php${PHP_VERSION}-pgsql \
        php${PHP_VERSION}-sqlite3 \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-zip \
    && update-alternatives --set php /usr/bin/php${PHP_VERSION} \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Official installer, checksum-verified against composer.github.io/installer.sig.
RUN EXPECTED_SIG="$(curl -fsSL https://composer.github.io/installer.sig)" \
    && curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php \
    && echo "${EXPECTED_SIG}  /tmp/composer-setup.php" | sha384sum -c - \
    && php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --2 \
    && rm /tmp/composer-setup.php

# Docker CLI + compose plugin so a pipeline can build and roll web/compose.yaml.
# Inert unless docker-compose.yml also mounts the host socket into the agent.
RUN curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /usr/share/keyrings/docker.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Caches live under $HOME so docker-compose.yml can persist them as volumes;
# without that every build re-downloads the full composer.lock and npm tree.
ENV COMPOSER_HOME=/home/jenkins/.composer \
    COMPOSER_NO_INTERACTION=1 \
    NPM_CONFIG_CACHE=/home/jenkins/.npm \
    PATH=/home/jenkins/.composer/vendor/bin:$PATH

RUN mkdir -p /home/jenkins/.composer /home/jenkins/.npm /home/jenkins/agent \
    && chown -R jenkins:jenkins /home/jenkins

USER jenkins
