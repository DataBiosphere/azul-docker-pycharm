"""
Replace the Netty that PyCharm merges into its own JARs with a newer release.

PyCharm does not ship Netty as a JAR of its own, so there is nothing to swap
out. Its classes are merged into `lib/util-8.jar` and `lib/lib.jar`, along with
the Maven metadata that a vulnerability scanner reads the version from. This
rewrites both, replacing every `io/netty/` entry with the one from the
distribution of Netty in `/tmp/netty`.

Which JARs those are, and which modules are in them, is a property of the
release of PyCharm being unpacked, and this knows it only as the table below.
A release that puts Netty somewhere else would leave that JAR untouched, with
its classes and its version intact, and a release that adds a module would have
that module's classes dropped and not replaced. Neither is evident from the
outcome, so the splice is checked rather than assumed: every `io/netty/` class
in the image has to come from the release spliced in, every Maven version has
to be that release's, and every module a rewritten JAR carries has to be one
the table names.

The exception is the handful of classes JetBrains writes into Netty's packages
in order to reach members that are package-private. They are named below,
because nothing distinguishes them from Netty's own by inspection, and the
check insists on finding them. That they survive today is a consequence of
living in a JAR this does not rewrite, which is luck rather than design; if a
release moves them into one it does, the splice drops them and the check says
so.
"""

import collections
import pathlib
import shutil
import sys
import zipfile

netty = pathlib.Path('/tmp/netty')

prefixes = (
    'io/netty/',
    'META-INF/maven/io.netty/',
    'META-INF/native-image/io.netty/',
)

# Which modules PyCharm merges into which of its JARs
#
layout = {
    'lib/util-8.jar': [
        'netty-buffer', 'netty-codec', 'netty-codec-base', 'netty-codec-http',
        'netty-codec-http2', 'netty-codec-socks', 'netty-common',
        'netty-handler', 'netty-handler-proxy', 'netty-resolver',
        'netty-transport', 'netty-transport-native-unix-common',
    ],
    'lib/lib.jar': ['netty-codec-compression'],
}

# Classes JetBrains authored into Netty's packages, which the splice must keep
#
authored = {
    'io/netty/bootstrap/BootstrapUtil.class',
    'io/netty/buffer/ByteBufUtf8Writer.class',
    'io/netty/buffer/ByteBufUtilEx.class',
}


def module_jar(module):
    # A glob would have `netty-codec` match `netty-codec-base` as well, so the
    # name is split on the last dash instead, the version carrying none
    jars = [
        jar for jar in sorted(netty.glob(f'{module}-*.jar'))
        if jar.name.removesuffix('.jar').rsplit('-', 1)[0] == module
    ]
    assert len(jars) == 1, (module, jars)
    return jars[0]


def spliced_version():
    versions = {
        module_jar(module).name.removesuffix('.jar').rsplit('-', 1)[1]
        for modules in layout.values()
        for module in modules
    }
    assert len(versions) == 1, versions
    return versions.pop()


def replacement_entries(modules):
    entries = {}
    for module in modules:
        with zipfile.ZipFile(module_jar(module)) as z:
            for name in z.namelist():
                if name.startswith(prefixes) and not name.endswith('/'):
                    entries[name] = z.read(name)
    return entries


def splice(path, modules):
    new = replacement_entries(modules)
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
            if name.startswith('META-INF/maven/io.netty/')
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
    return set(new)


def check(root, version, spliced_names):
    classes = collections.defaultdict(list)
    versions = collections.defaultdict(list)
    for path in sorted(root.rglob('*.jar')):
        with zipfile.ZipFile(path) as z:
            for name in z.namelist():
                if name.startswith('io/netty/') and name.endswith('.class'):
                    classes[name].append(path)
                elif (name.startswith('META-INF/maven/io.netty/')
                      and name.endswith('pom.properties')):
                    found = dict(
                        line.split('=', 1)
                        for line in z.read(name).decode().splitlines()
                        if '=' in line and not line.startswith('#')
                    )
                    versions[found.get('version')].append(f'{path}:{name}')

    # A class from neither the release spliced in nor JetBrains means a JAR the
    # table does not account for, carrying the release we meant to replace
    strays = {
        name: paths
        for name, paths in classes.items()
        if name not in spliced_names and name not in authored
    }
    assert not strays, sorted(strays.items())[:4]

    missing = authored - classes.keys()
    assert not missing, sorted(missing)

    # A version other than the one spliced in means the same thing, for a JAR
    # whose classes happen to all be in the release
    assert set(versions) == {version}, {
        found: paths[:2]
        for found, paths in versions.items()
        if found != version
    }

    print(f'  checked: {len(classes)} Netty classes, of which '
          f'{len(authored)} JetBrains\', all Maven metadata at {version}')


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '/opt/pycharm')
    version = spliced_version()
    spliced_names = set()
    for jar, modules in layout.items():
        path = root / jar
        assert path.exists(), path
        spliced_names |= splice(path, modules)
    check(root, version, {
        name for name in spliced_names if name.endswith('.class')
    })
    shutil.rmtree(netty)


if __name__ == '__main__':
    main()
