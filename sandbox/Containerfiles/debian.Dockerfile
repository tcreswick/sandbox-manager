ARG BASE_IMAGE=debian:trixie
FROM ${BASE_IMAGE}

ARG USERNAME
ARG USER_UID
ARG USER_GID

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_GB.UTF-8
ENV LC_ALL=en_GB.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo ca-certificates curl wget git bash-completion \
        build-essential nodejs npm \
        nano vim less file tree htop jq \
        procps iproute2 iputils-ping dnsutils hostname \
        locales \
        x11-apps mesa-utils \
    && sed -i 's/# en_GB.UTF-8/en_GB.UTF-8/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g ${USER_GID} ${USERNAME} \
    && useradd -u ${USER_UID} -g ${USER_GID} -s /bin/bash -G sudo ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 440 /etc/sudoers.d/${USERNAME}

CMD ["sleep", "infinity"]
