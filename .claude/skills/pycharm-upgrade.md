---
name: pycharm-upgrade
description: "Upgrade the PyCharm in this image: the plugins and platform JARs it keeps, and the Netty it substitutes."
user_invocable: true
---

# PyCharm upgrade

Apply this skill when `azul_docker_pycharm_upstream_version` in
`.github/workflows/docker-publish.yml` is bumped to a new release of PyCharm.

Azul uses this image for one thing: the `format` target in Azul's `Makefile`
runs `/opt/pycharm/bin/format.sh` in a container from it. Everything this image
strips away — vulnerable OS packages, every plugin outside
`pycharm_plugins.txt`, the bundled runtime, and the JARs named in
`pycharm_unused_jars.txt` — is stripped on the assumption that formatting is
all that has to keep working. So are the Netty and the Jackson that
`splice.py` swaps for current releases. Judge an upgrade by that, not by whether the IDE still
starts. Rather more than half of the distribution is gone, and most of what it
does still carry is never loaded.

Three files drive it, and an upgrade may need all three revisited:
`pycharm_plugins.txt`, `pycharm_unused_jars.txt`, and
`pycharm_maven_checksums.txt`.

Every step compares formatted output against a reference produced by the image
that is being replaced. Nothing is accepted because it looks right. Budget two
hours, most of it waiting for builds and formatter runs.

## Step 0: Refresh the checksums, and expect the name to change

Run `make pycharm_checksums` first; it rewrites `pycharm_checksums.txt` from
the version in the workflow, fetching what JetBrains publishes next to the
archives. A 404 means the archive
is not named what `Dockerfile` expects. JetBrains renames it from time to time:
2025.3 dropped the `community` infix that every release before it carried, when
the two editions merged into one distribution. Fix the `pycharm_tarball`
assignment in `Dockerfile` and rerun.

## Step 1: Note what changed

Read the release notes for anything about bundled plugins or the layout of the
distribution. Record which version this image is being upgraded *from*; Step 2
needs it.

## Step 2: Establish the reference

Pull the image Azul currently pins — see `azul_docker_images` in Azul's
`environment.py`, not this repository, which may be ahead of it — and capture
what it produces. The formatter rewrites files in place, so work on throwaway
copies of Azul's sources, never on a working tree. Make two, e.g. with `git
archive HEAD | tar -x -C <dir>` in a clone of Azul:

- one left as checked out, and

- one whose formatting has been mangled beforehand, which proves the formatter
  changes the right things. Mangle with something crude, e.g. `perl -0pi -e
  's/, /,/g; s/ = /=/g'` over every `*.py` in the copy.

Format both with the reference image and keep the results:

    docker run --attach stdout --rm --user 0:0 \
        --mount type=bind,source=<copy>,target=/home/developer/azul \
        --workdir /home/developer/azul <image> \
        /opt/pycharm/bin/format.sh -r -settings .pycharm.style.xml -mask '*.py' .

The mangled copy is the one that matters. An already formatted file is left
untouched by almost any broken configuration, so the unmangled copy alone
proves little.

## Step 3: Confirm the new version formats identically

Build with `pycharm_unused_jars.txt` emptied, and format fresh copies of both.
Compare against the reference. If the output differs, the upgrade changes
Azul's formatting. Stop and report that to the user; whether to accept a
reformat of that code base is their decision, not something to absorb into this
task.

Check `pycharm_plugins.txt` here too. A release that renames a plugin fails the
build outright; one that splits a plugin in two, or moves what the formatter
needs into a plugin not on the list, fails at run time with an
`EssentialPluginMissingException` naming what it wants.

## Step 4: Derive the list of unused JARs

`pycharm_unused_jars.txt` names the JARs under `lib/` that no class is loaded
from while the formatter runs. Derive it anew, never carry one over: the list is
specific to a release *and* to the set of plugins this image keeps.

Derive it by converging from a build that works, not from an untrimmed one. An
image with the plugins trimmed and `lib/` intact does not start at all: it dies
in `com.intellij.util.system.OS.<clinit>`, reading a mapped buffer past its
limit, before the formatter runs. Whatever that is, it means there is no
untrimmed image to trace in this configuration.

So: trace the image the previous list produced, remove whatever loaded nothing,
rebuild, and validate. Repeat until a round finds nothing new. Each round is
safe — every image along the way is one that formats correctly — and each
converges on the answer from above. Starting from an empty list works too, if a
release moves enough that the previous one is worthless: the first build is then
untrimmed in `lib/` *and* in `plugins/`, which does start.

Run the formatter over the mangled copy with `-verbose:class` in
`_JAVA_OPTIONS`, capturing standard output. Index the classes in every JAR under
`/opt/pycharm/lib`, subtract the ones the trace names, and keep the JARs left
with none. Write them to the list as paths relative to `/opt/pycharm`, one per
line, sorted.

`zipinfo -1` in the container lists a JAR's entries; the image carries it for
the carving that `Dockerfile` does anyway.

Match the trace lines with `class,load\s*\]` rather than a fixed string. The JVM
widens the decorators of those lines part way through a run, and a fixed string
silently stops matching, leaving most of the trace uncounted and most of the
platform looking unused.

Intersect on exact class names, never on package prefixes. Prefixes like
`com.intellij.platform` span both plugin and platform JARs, and matching on them
credits a JAR for classes that came from somewhere else.

For 2025.3 this converged on 144 of the 261 JARs under `lib/`: 127 from a
trace against the fully untrimmed image, and 17 more from a second round once
the plugins were gone.

## Step 5: Check what the substitutions are still worth

`splice.py` replaces the libraries PyCharm merges into JARs of its own naming
with the releases pinned by `pycharm_maven_checksums.txt`. Two are substituted:
Netty, in `lib/util-8.jar` and `lib/lib.jar`, and Jackson, in the three
`lib/module-intellij.libraries.jackson*.jar` and in
`lib/modules/intellij.platform.settings.local.jar`, which is mostly platform
classes with one Jackson module among them.

Refresh the pin by fetching each artifact at the current release from Maven
Central and recording its digest against its full path in the repository. The
path carries the module and the version; nothing else does. Note that Jackson
does not version its modules in lockstep — `jackson-annotations` is at 2.22
where the rest are at 2.22.2 — so the pin is per module, not per library.

The build itself now checks that each substitution was complete: that every
class of a library comes from the artifacts spliced in, that every Maven version
is the one pinned for its module, and that every module a rewritten JAR carries
is one the table names. A release that moves a library, or adds a module to it,
fails the build rather than producing an image that looks substituted. What is
left to judge by hand is whether the substitution is still the right thing:

That what PyCharm merges in is still stock. It was for 2025.3 — all 2515 Netty
classes and all 1212 Jackson ones byte identical to Maven Central — which is why
substituting them discards nothing of JetBrains'. Compare digests rather than
assuming it stays that way.

That the classes JetBrains writes into a library's own packages are still named
in the table. Netty had three in 2025.3, reaching members that are
package-private; Jackson has none. The formatter loads none of them, so nothing
here will tell you if they break; that is also why it does not matter.

The version to pin is the current release, not the oldest one that clears the
findings. Advisories against Netty are written against `>=4.2.0.Final`, and
PyCharm ships a release candidate, which sorts below it and so matches none of
them. An unmatched version reads as clean and is not, and an intermediate
release can therefore report *more* findings than the RC it replaces.

If a release of PyCharm ever merges in a current version of one of these,
remove it from the table rather than keeping a substitution that does nothing.
A library PyCharm stops merging in fails the build at the missing JAR, which is
the prompt to remove it.

## Step 6: Validate

Build with the list in place, then, each against the reference from Step 2:

1. both copies, all sources, byte identical

2. the other architecture, via `docker build --platform` and `docker run
   --platform`

3. Azul's `make format` followed by `make check_clean`, against an image built
   here and pushed to a local registry — see the Azul notes in `README.md`

Scan the result with `docker scout quickview` and compare against the image
being replaced. A rise in findings is as much a result as a fall, and worth
understanding before it is reported: the Netty substitution turned up that way.

Report the size of the image and of `/opt/pycharm`, before and after the
removal. A sudden change from one release to the next means the list is matching
more or less than intended.

## Gotchas

Removals only shrink the image when they happen in the instruction that
extracted the files. A `RUN rm` of its own leaves the bytes in the earlier
layer: the container's file system shrinks, the image does not. That is why
`Dockerfile` downloads, verifies, extracts and prunes in a single instruction.

A list derived for a different plugin set will not do, even for the same release
of PyCharm. Plugins pull in platform code that formatting alone never touches —
`platform-images` needs `commons-imaging`, for instance. Remove the JAR it lives
in while that plugin is still installed and every file fails to format, with
`NoClassDefFoundError` buried in a stack trace on stderr while stdout reports
`Failed` for each file and `0 file(s) formatted` at the end. The list and
`pycharm_plugins.txt` therefore move together: trimming plugins only ever makes
the list longer, never shorter.

The list is only as good as the sources it was derived from. A JAR that some
future source file turns out to need announces itself the same way. The remedy
is to remove that JAR from the list, not to work around the error.

`xargs rm` fails when a listed JAR is absent, which is deliberate: it catches a
list carried over from a release that no longer ships that JAR.

The JRE has to match. `Dockerfile` installs Debian's `openjdk-21-jre-headless`
and removes the bundled JetBrains Runtime, so a release built against a newer
Java fails in ways that have nothing to do with any list. Read `JAVA_VERSION`
from `jbr/release` in the archive before assuming the pinned package still fits.

Naming a path goes stale silently. 2025.3 dropped `lib/lib-client.jar`, which an
earlier instruction carved packages out of by name; `zip -d` at least failed
loudly, with exit code 12, "nothing to do". `Dockerfile` now searches every JAR
that remains instead, and prints a line per JAR it carves. A `rm -rf` of a
renamed path is the quiet version of the same trap, and this repository had
two of them: `plugins/textmate` became `textmate-plugin` and `plugins/tasks`
became `tasks-timeTracking`, so both removals had been deleting nothing. Naming
what to keep, as `pycharm_plugins.txt` does, fails loudly instead.

Check what a pattern matches before trusting it. The Netty half of that carving
instruction read `netty[./]io`, the package path reversed, and so matched
nothing in any release — which was just as well, since formatting loads 320
Netty classes and carving them would have broken it.

Expect on the order of a hundred lines of stack traces per run even when
everything is correct. Azul's `format` target attaches only stdout for that
reason. Judge success by the `N file(s) formatted` line, the count of `Failed`
lines, and the diff — never by the absence of exceptions.
