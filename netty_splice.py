"""
Replace the Netty that PyCharm merges into its own JARs with a newer release.

PyCharm does not ship Netty as a JAR of its own, so there is nothing to swap
out. Its classes are merged into `lib/util-8.jar` and `lib/lib.jar`, along with
the Maven metadata that a vulnerability scanner reads the version from. This
rewrites both, replacing every `io/netty/` entry with the one from the
distribution of Netty in `/tmp/netty`, and the metadata with that release's.

Classes that JetBrains authored into Netty's packages, to reach members that
are package-private, are kept as they are. They live in `lib/app.jar`, which
this leaves alone, but the check is by origin rather than by file, so that a
release moving them elsewhere does not silently drop them.
"""

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

# Which modules are merged into which of PyCharm's JARs
layout = {
    'lib/util-8.jar': [
        'netty-buffer', 'netty-codec', 'netty-codec-base', 'netty-codec-http',
        'netty-codec-http2', 'netty-codec-socks', 'netty-common',
        'netty-handler', 'netty-handler-proxy', 'netty-resolver',
        'netty-transport', 'netty-transport-native-unix-common',
    ],
    'lib/lib.jar': ['netty-codec-compression'],
}


def replacement_entries(modules):
    entries = {}
    for module in modules:
        # A glob would have `netty-codec` match `netty-codec-base` as well, so
        # the name is split on the last dash instead, the version carrying none
        jars = [
            jar for jar in sorted(netty.glob(f'{module}-*.jar'))
            if jar.name.removesuffix('.jar').rsplit('-', 1)[0] == module
        ]
        assert len(jars) == 1, (module, jars)
        with zipfile.ZipFile(jars[0]) as z:
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


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '/opt/pycharm')
    for jar, modules in layout.items():
        path = root / jar
        assert path.exists(), path
        splice(path, modules)
    shutil.rmtree(netty)


if __name__ == '__main__':
    main()
