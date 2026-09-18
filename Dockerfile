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

# Install PyCharm, and eliminate in the same instruction everything we don't
# need, because an image only ever shrinks within the instruction that creates
# the layer, never in a later one.
#
# The archive lost its `community` infix in 2025.3, when JetBrains merged the
# two editions into a single distribution.
#
# The checksums are the ones JetBrains publishes alongside the archives. Only
# the one for the architecture being built is present, hence --ignore-missing.
# Run `make pycharm_checksums` after changing the version of PyCharm.
#
# `pycharm_unused_jars.txt` names the platform JARs that no class is ever loaded
# from while formatting, half of the platform's JARs. The list was derived by
# running the formatter over the Azul code base with `-verbose:class` and keeping
# the JARs that no loaded class came from. It holds for both architectures, whose
# archives contain the same JARs, and has to be derived anew for every release of
# PyCharm. A JAR that some future source file turns out to need announces itself
# as a `NoClassDefFoundError` from the formatter, and the remedy is to remove
# that JAR from the list. Use Claude with the `pycharm-upgrade` skill to derive
# the list again.
#
# The plugins removed here carry the most vulnerable code we have no use for:
# `gateway-plugin` ships six remote development workers, one per platform, which
# between them account for most of this image's critical and high findings, and
# `textmate-plugin` bundles a copy of Handlebars. The helpers of the Python
# plugin go too; the formatter does not run them.
#
# They are removed with `rm -r`, not `rm -rf`, so that a release renaming one of
# them fails the build. Renames do happen: these were spelled `textmate` and
# `tasks` until 2025.3 renamed them, and `rm -rf` had been quietly deleting
# nothing for as long as that went unnoticed.
#
# The list subsumes `lib/protobuf.jar`, which an earlier instruction removed for
# being vulnerable.
#
# Carving a package out of a JAR covers what the list cannot express: a JAR the
# formatter does load may still carry a package we have no use for. The JAR to
# carve is no longer named, because the name this was written for,
# `lib/lib-client.jar`, did not survive one upgrade; every JAR that remains is
# searched instead, and the package deleted from wherever it turns up.
#
# The instruction this grew out of also named Netty, but its pattern was the
# package path reversed and so never matched it in any release. Netty must stay
# regardless: formatting loads 320 of its classes, whereas it loads none from
# the I2P crypto library that sshj bundles.
#
COPY pycharm_checksums.txt pycharm_unused_jars.txt /tmp/

RUN set -o pipefail \
  && export pycharm_arch=$(python3 -c "print(dict(amd64='',arm64='-aarch64')['${TARGETARCH}'])") \
  && export pycharm_tarball="pycharm-${azul_docker_pycharm_upstream_version}${pycharm_arch}.tar.gz" \
  && echo "Downloading ${pycharm_tarball}" \
  && curl -fsSL "https://download.jetbrains.com/python/${pycharm_tarball}" \
     -o "/tmp/${pycharm_tarball}" \
  && ( cd /tmp && sha256sum --ignore-missing -c pycharm_checksums.txt ) \
  && tar --strip-components=1 -xzf "/tmp/${pycharm_tarball}" \
  && rm -r plugins/textmate-plugin plugins/tasks-timeTracking plugins/gateway-plugin \
        plugins/python-ce/helpers \
  && xargs rm < /tmp/pycharm_unused_jars.txt \
  && for jar in $(find . -name '*.jar') ; do \
       entries=$( \
         zipinfo -1 "$jar" \
         | grep \
           -e net/i2p/crypto \
         || true \
       ) ; \
       if [ -n "$entries" ] ; then \
         echo "Carving $(echo "$entries" | wc -l) entries out of $jar" ; \
         zip -q -d "$jar" $entries ; \
       fi ; \
     done \
  && rm "/tmp/${pycharm_tarball}" \
        /tmp/pycharm_checksums.txt \
        /tmp/pycharm_unused_jars.txt

# Eliminate vulnerable OS packages not needed for how we use this image
#
RUN dpkg --remove --force-depends \
    linux-libc-dev \
    expat libexpat1 libexpat1-dev

RUN useradd -ms /bin/bash developer

USER developer
ENV HOME=/home/developer

ARG pycharm_local_dir=.PyCharmCE${azul_docker_pycharm_upstream_version}

RUN mkdir /home/developer/.PyCharm \
  && ln -sf /home/developer/.PyCharm "/home/developer/$pycharm_local_dir"

SHELL ["/bin/sh", "-c"]

CMD [ "/opt/pycharm/bin/pycharm.sh" ]
