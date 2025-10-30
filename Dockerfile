ARG azul_docker_pycharm_base_image_tag

FROM debian:${azul_docker_pycharm_base_image_tag}

ARG TARGETARCH

LABEL maintainer="Azul Group <azul-group@ucsc.edu>"

ARG azul_docker_pycharm_internal_version

RUN \
  apt-get update \
  && apt-get upgrade -y \
  && apt-get install --no-install-recommends -y \
    python3 python3-dev \
    gcc openssh-client less curl ca-certificates \
    libxtst-dev libxext-dev libxrender-dev libfreetype6-dev \
    libfontconfig1 libgtk2.0-0 libxslt1.1 libxxf86vm1 \
  && rm -rf /var/lib/apt/lists/*

# CVE-2025-21863 CVE-2025-21858 CVE-2025-21855 CVE-2025-21759 CVE-2025-21756
# CVE-2025-21751 CVE-2025-21739 CVE-2025-21729 CVE-2025-21714 CVE-2025-21693
# CVE-2025-0927 CVE-2024-58002 CVE-2024-57984 CVE-2024-57982 CVE-2024-57900
# CVE-2024-57857 CVE-2024-57795 CVE-2024-56784 CVE-2024-56775 CVE-2024-56538
# CVE-2024-53218 CVE-2024-53216 CVE-2024-53203 CVE-2024-53179 CVE-2024-53177
# CVE-2024-53168 CVE-2024-53166 CVE-2024-53133 CVE-2024-53108 CVE-2024-53095
# CVE-2024-53068 CVE-2024-50246 CVE-2024-50226 CVE-2024-50217 CVE-2024-50112
# CVE-2024-50063 CVE-2024-50029 CVE-2024-49928 CVE-2024-47691 CVE-2024-46833
# CVE-2024-46813 CVE-2024-46811 CVE-2024-46786 CVE-2024-46774 CVE-2024-44951
# CVE-2024-44942 CVE-2024-44941 CVE-2024-42162 CVE-2024-39479 CVE-2024-38630
# CVE-2024-38570 CVE-2024-36921 CVE-2024-36913 CVE-2024-36908 CVE-2024-35929
# CVE-2024-35887 CVE-2024-35869 CVE-2024-35866 CVE-2024-27042 CVE-2024-26982
# CVE-2024-26944 CVE-2024-26930 CVE-2024-26913 CVE-2024-26842 CVE-2024-26739
# CVE-2024-26672 CVE-2024-26669 CVE-2024-25743 CVE-2024-21803 CVE-2023-52751
# CVE-2023-52629 CVE-2023-52624 CVE-2023-52591 CVE-2023-52586 CVE-2023-52452
# CVE-2021-3864 CVE-2021-3847
RUN dpkg --remove --force-depends linux-libc-dev

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

# CVE-2021-23383 CVE-2021-23369 CVE-2019-19919 GHSA-q42p-pg8m-cqh6
# GHSA-q2c6-c6pm-g3gh GHSA-g9r4-xpmj-mj65 GHSA-2cf5-4w76-r9qv CVE-2019-20920
# GHSA-h6ch-v84p-w6p9⁠ CVE-2020-7712⁠
RUN rm -rf /opt/pycharm/plugins/textmate

RUN useradd -ms /bin/bash developer

USER developer
ENV HOME=/home/developer

ARG pycharm_local_dir=.PyCharmCE${azul_docker_pycharm_upstream_version}

RUN mkdir /home/developer/.PyCharm \
  && ln -sf /home/developer/.PyCharm "/home/developer/$pycharm_local_dir"

SHELL ["/bin/sh", "-c"]

CMD [ "/opt/pycharm/bin/pycharm.sh" ]
