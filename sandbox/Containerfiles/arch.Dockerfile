ARG BASE_IMAGE=archlinux:latest
FROM ${BASE_IMAGE}

ARG USERNAME
ARG USER_UID
ARG USER_GID

ENV LANG=en_GB.UTF-8
ENV LC_ALL=en_GB.UTF-8

RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
        sudo ca-certificates curl wget git bash-completion \
        base-devel nodejs npm \
        nano vim less file tree htop jq \
        procps iproute2 iputils-ping dnsutils hostname \
        glibc locales \
        xorg-xclock mesa-utils

RUN locale-gen en_GB.UTF-8

RUN groupadd -g ${USER_GID} ${USERNAME} \
    && useradd -u ${USER_UID} -g ${USER_GID} -s /bin/bash -G sudo,wheel ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 440 /etc/sudoers.d/${USERNAME}

CMD ["sleep", "infinity"]
