ARG azul_docker_pycharm_base_image_tag=no_tag

FROM debian:${azul_docker_pycharm_base_image_tag}

ARG TARGETARCH

LABEL maintainer="Azul Group <azul-group@ucsc.edu>"

ARG azul_docker_pycharm_internal_version=no_version

RUN \
  apt-get update \
  && apt-get upgrade -y \
  && apt-get install --no-install-recommends -y \
    zip unzip python3 python3-dev \
    gcc openssh-client less curl ca-certificates \
    libxtst-dev libxext-dev libxrender-dev libfreetype6-dev \
    libfontconfig1 libgtk2.0-0 libxslt1.1 libxxf86vm1 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/pycharm

SHELL ["/bin/bash", "-c"]

ARG azul_docker_pycharm_upstream_version

RUN set -o pipefail \
  && export pycharm_arch=$(python3 -c "print(dict(amd64='',arm64='-aarch64')['${TARGETARCH}'])") \
  && export pycharm_source="https://download.jetbrains.com/python/pycharm-community-${azul_docker_pycharm_upstream_version}${pycharm_arch}.tar.gz" \
  && echo "Downloading ${pycharm_source}" \
  && curl -fsSL "${pycharm_source}" -o installer.tgz \
  && tar --strip-components=1 -xzf installer.tgz \
  && rm installer.tgz

# Eliminate vulnerable OS packages not needed for how we use this image
#
RUN dpkg --remove --force-depends \
    linux-libc-dev \
    expat libexpat1 libexpat1-dev

# Eliminate vulnerable PyCharm libraries, plugins, or parts thereof that are not
# needed for how we use this image
#
RUN rm -rf  \
    /opt/pycharm/plugins/textmate  \
    /opt/pycharm/plugins/tasks  \
    /opt/pycharm/lib/protobuf.jar \
    /opt/pycharm/plugins/python-ce/helpers

# Eliminate vulnerable Java packages from fat JARs that PyCharm depends on, but
# that are not needed for how we use this image
#
RUN zip -d /opt/pycharm/lib/lib-client.jar \
    $( \
      zipinfo -1 /opt/pycharm/lib/lib-client.jar \
      | grep  \
        -e netty[./]io  \
        -e net[./]i2p[./]crypto \
    )

RUN useradd -ms /bin/bash developer

USER developer
ENV HOME=/home/developer

ARG pycharm_local_dir=.PyCharmCE${azul_docker_pycharm_upstream_version}

RUN mkdir /home/developer/.PyCharm \
  && ln -sf /home/developer/.PyCharm "/home/developer/$pycharm_local_dir"

SHELL ["/bin/sh", "-c"]

CMD [ "/opt/pycharm/bin/pycharm.sh" ]
