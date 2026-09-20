"""
Replace libraries that PyCharm merges into its own JARs with newer releases.

PyCharm ships neither Netty nor Jackson as JARs of their own, so there is
nothing to swap out. Their classes are merged into JARs of its own naming, along
with the Maven metadata that a vulnerability scanner reads the version from.
This rewrites those JARs, replacing every entry of the library with the one from
the artifacts in `/tmp/maven`, which `pycharm_maven_checksums.txt` pins.

Which JARs those are, and which modules are in them, is a property of the
release of PyCharm being unpacked, and this knows it only as the tables below.
A release that puts a library somewhere else would leave that JAR untouched,
with its classes and its version intact, and a release that adds a module would
have that module's classes dropped and not replaced. Neither is evident from the
outcome, so the splice is checked rather than assumed: every class of the
library has to come from the artifacts spliced in, every Maven version has to be
the one pinned for its module, and every module a rewritten JAR carries has to
be one its table names.

The exception is the handful of classes JetBrains writes into a library's own
packages in order to reach members that are package-private. Netty has three;
Jackson has none. They are named below, because nothing distinguishes them from
the library's own by inspection, and the check insists on finding them. That
they survive today is a consequence of living in a JAR this does not rewrite,
which is luck rather than design; if a release moves them into one it does, the
splice drops them and the check says so.
"""

import collections
import pathlib
import shutil
import sys
import zipfile

maven = pathlib.Path('/tmp/maven')

libraries = {
    'Netty': {
        'prefixes': (
            'io/netty/',
            'META-INF/maven/io.netty/',
            'META-INF/native-image/io.netty/',
        ),
        'authored': {
            'io/netty/bootstrap/BootstrapUtil.class',
            'io/netty/buffer/ByteBufUtf8Writer.class',
            'io/netty/buffer/ByteBufUtilEx.class',
        },
        'layout': {
            'lib/util-8.jar': [
                'netty-buffer', 'netty-codec', 'netty-codec-base',
                'netty-codec-http', 'netty-codec-http2', 'netty-codec-socks',
                'netty-common', 'netty-handler', 'netty-handler-proxy',
                'netty-resolver', 'netty-transport',
                'netty-transport-native-unix-common',
            ],
            'lib/lib.jar': ['netty-codec-compression'],
        },
    },
    'Jackson': {
        'prefixes': (
            'com/fasterxml/jackson/',
            'META-INF/maven/com.fasterxml.jackson',
        ),
        'authored': set(),
        'layout': {
            'lib/module-intellij.libraries.jackson.databind.jar': [
                'jackson-annotations', 'jackson-databind',
            ],
            'lib/module-intellij.libraries.jackson.jar': ['jackson-core'],
            'lib/module-intellij.libraries.jackson.module.kotlin.jar': [
                'jackson-module-kotlin',
            ],
            'lib/modules/intellij.platform.settings.local.jar': [
                'jackson-dataformat-cbor',
            ],
        },
    },
}


def module_jars():
    # The path a Maven repository stores an artifact under ends in the module,
    # the version, and a file named for both, which is the version this pins.
    # Jackson does not version its modules in lockstep, so each is its own.
    jars = {}
    for path in maven.rglob('*.jar'):
        version = path.parent.name
        module = path.parent.parent.name
        assert path.name == f'{module}-{version}.jar', path
        assert module not in jars, module
        jars[module] = path
    return jars


def entries(jars, modules, prefixes):
    found = {}
    for module in modules:
        assert module in jars, (module, sorted(jars))
        with zipfile.ZipFile(jars[module]) as z:
            for name in z.namelist():
                if name.startswith(prefixes) and not name.endswith('/'):
                    found[name] = z.read(name)
    return found


def splice(path, new, prefixes, modules):
    kept = added = dropped = 0
    tmp = path.with_suffix('.spliced')
    with zipfile.ZipFile(path) as src, \
            zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as dst:
        # A module this JAR carries but the table does not name would have its
        # classes dropped here and nothing put back, which no later check can
        # see, the metadata that would have named it being dropped along with
        # them
        merged = {
            name.split('/')[3]
            for name in src.namelist()
            if name.startswith(prefixes) and name.startswith('META-INF/maven/')
        }
        assert merged <= set(modules), sorted(merged - set(modules))
        for item in src.infolist():
            if item.filename.startswith(prefixes):
                dropped += 1
            else:
                dst.writestr(item, src.read(item.filename))
                kept += 1
        for name, data in sorted(new.items()):
            dst.writestr(name, data)
            added += 1
    tmp.replace(path)
    print(f'  {path}: kept {kept}, dropped {dropped}, added {added}')


def check(root, name, library, jars, spliced):
    prefixes, authored = library['prefixes'], library['authored']
    classes = collections.defaultdict(list)
    versions = collections.defaultdict(list)
    for path in sorted(root.rglob('*.jar')):
        with zipfile.ZipFile(path) as z:
            for entry in z.namelist():
                if not entry.startswith(prefixes):
                    continue
                elif entry.endswith('.class'):
                    classes[entry].append(path)
                elif entry.endswith('pom.properties'):
                    found = dict(
                        line.split('=', 1)
                        for line in z.read(entry).decode().splitlines()
                        if '=' in line and not line.startswith('#')
                    )
                    versions[(found.get('artifactId'),
                              found.get('version'))].append(f'{path}:{entry}')

    # A class from neither the artifacts spliced in nor JetBrains means a JAR
    # the table does not account for, carrying the release we meant to replace
    strays = {
        entry: paths
        for entry, paths in classes.items()
        if entry not in spliced and entry not in authored
    }
    assert not strays, sorted(strays.items())[:4]

    missing = authored - classes.keys()
    assert not missing, sorted(missing)

    # A version other than the one pinned means the same thing, for a JAR whose
    # classes happen to all be in the release
    expected = {
        module: path.parent.name for module, path in jars.items()
    }
    stale = {
        (module, version): paths[:2]
        for (module, version), paths in versions.items()
        if expected.get(module) != version
    }
    assert not stale, stale

    pinned = sorted({expected[module] for module, _ in versions})
    print(f'  {name}: {len(classes)} classes, of which {len(authored)} '
          f"JetBrains', all Maven metadata at {', '.join(pinned)}")


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '/opt/pycharm')
    jars = module_jars()
    for name, library in libraries.items():
        prefixes = library['prefixes']
        spliced = set()
        for jar, modules in library['layout'].items():
            path = root / jar
            assert path.exists(), path
            new = entries(jars, modules, prefixes)
            splice(path, new, prefixes, modules)
            spliced |= {
                entry for entry in new if entry.endswith('.class')
            }
        check(root, name, library, jars, spliced)
    shutil.rmtree(maven)


if __name__ == '__main__':
    main()
