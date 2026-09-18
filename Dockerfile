ARG azul_docker_pycharm_base_image_tag=no_tag

# The distribution is unpacked and slimmed down in a stage of its own, and only
# the result is copied into the image. Nothing this stage installs ends up being
# shipped, so it installs only what unpacking and slimming need, and the image
# is unaffected by what happens here beyond the contents of /opt/pycharm.
#
# Doing it in one stanza would work just as well, and until recently it did, but
# then every change to one of the lists below re-downloads the distribution.
# Splitting the two apart within a single stage would instead leave the whole
# distribution in the layer that extracted it, since an image only ever shrinks
# within the instruction that creates the layer, never in a later one. Two
# stages are what makes the download cacheable without the removals becoming
# cosmetic.
#
FROM debian:${azul_docker_pycharm_base_image_tag} AS pycharm

ARG TARGETARCH

RUN \
  apt-get update \
  && apt-get upgrade -y \
  && apt-get install --no-install-recommends -y \
    zip unzip python3 curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/pycharm

SHELL ["/bin/bash", "-c"]

ARG azul_docker_pycharm_upstream_version

# The archive lost its `community` infix in 2025.3, when JetBrains merged the
# two editions into a single distribution.
#
# The checksums are the ones JetBrains publishes alongside the archives. Only
# the one for the architecture being built is present, hence --ignore-missing.
# Run `make pycharm_checksums` after changing the version of PyCharm.
#
COPY pycharm_checksums.txt /tmp/

RUN set -o pipefail \
  && export pycharm_arch=$(python3 -c "print(dict(amd64='',arm64='-aarch64')['${TARGETARCH}'])") \
  && export pycharm_tarball="pycharm-${azul_docker_pycharm_upstream_version}${pycharm_arch}.tar.gz" \
  && echo "Downloading ${pycharm_tarball}" \
  && curl --fail --no-progress-meter --location \
     "https://download.jetbrains.com/python/${pycharm_tarball}" \
     -o "/tmp/${pycharm_tarball}" \
  && ( cd /tmp && sha256sum --ignore-missing -c pycharm_checksums.txt ) \
  && tar --strip-components=1 -xzf "/tmp/${pycharm_tarball}" \
  && rm "/tmp/${pycharm_tarball}" /tmp/pycharm_checksums.txt

# `pycharm_plugins.txt` names the plugins to keep, and every other one is
# removed. Naming what to keep rather than what to drop means a release that
# bundles something new leaves it out by default, instead of adding it to this
# image until someone notices. Naming what to drop had gone stale twice already:
# 2025.3 renamed `textmate` to `textmate-plugin` and `tasks` to
# `tasks-timeTracking`, and the `rm -rf` of the old names deleted nothing for as
# long as that went unnoticed.
#
# The eight are what the platform needs in order to format Python. Missing one
# of them is not subtle: the platform refuses to start and names what it wants,
# as an `EssentialPluginMissingException`. The build fails if one is absent from
# the distribution, rather than leaving it to that exception to explain.
#
# `plugins/plugin-classpath.txt` goes with them. It is a precomputed index of
# the JARs of all bundled plugins, and with it in place the platform would not
# start on this image. Without it, the platform scans the directory instead, and
# tolerates the absence of the plugins removed here.
#
# The helpers of the Python plugin go too, and so do the debugger eggs and the
# bundled runtime; the formatter runs none of them.
#
# `pycharm_unused_jars.txt` names the platform JARs that no class is ever loaded
# from while formatting, more than half of those under `lib/`. The list was
# derived by running the formatter over the Azul code base with `-verbose:class`
# and keeping the JARs that no loaded class came from. It holds for both
# architectures, whose archives contain the same JARs, and has to be derived
# anew for every release of PyCharm, and whenever the list of plugins above
# changes. A JAR that some future source file turns out to need announces itself
# as a `NoClassDefFoundError` from the formatter, and the remedy is to remove
# that JAR from the list. Use Claude with the `pycharm-upgrade` skill to derive
# the list again.
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
COPY pycharm_plugins.txt pycharm_unused_jars.txt /tmp/

RUN set -o pipefail \
  && ( cd plugins \
       && xargs -I {} test -d {} < /tmp/pycharm_plugins.txt \
       && ls | grep -vxF -f /tmp/pycharm_plugins.txt | xargs rm -r ) \
  && rm -r plugins/python-ce/helpers jbr debug-eggs \
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
  && rm /tmp/pycharm_plugins.txt /tmp/pycharm_unused_jars.txt

FROM debian:${azul_docker_pycharm_base_image_tag}

LABEL maintainer="Azul Group <azul-group@ucsc.edu>"

ARG azul_docker_pycharm_internal_version=no_version
ARG azul_docker_pycharm_upstream_version

# PyCharm bundles its own JRE, the JetBrains Runtime, which this image does not
# install. The distribution's JRE is installed instead: it is patched whenever
# the pin of the base image is bumped, whereas the bundled one is patched when
# JetBrains ships a release. Its major version has to match the bundled one,
# which `jbr/release` in the archive states.
#
# The path Debian installs it under carries the architecture, so it is
# symlinked to one that does not, for `JAVA_HOME` to name below. That is how the
# launcher finds a JRE once the bundled one is gone.
#
# Only what running the formatter needs is installed. Unpacking the distribution
# needs more than this, but that happens in the stage above, whose packages stay
# there.
#
RUN \
  apt-get update \
  && apt-get upgrade -y \
  && apt-get install --no-install-recommends -y \
    python3 openjdk-21-jre-headless \
    openssh-client less ca-certificates \
    libxtst-dev libxext-dev libxrender-dev libfreetype6-dev \
    libfontconfig1 libgtk2.0-0 libxslt1.1 libxxf86vm1 \
  && rm -rf /var/lib/apt/lists/* \
  && ln -s /usr/lib/jvm/java-21-openjdk-* /opt/java

ENV JAVA_HOME=/opt/java

COPY --from=pycharm /opt/pycharm /opt/pycharm

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
