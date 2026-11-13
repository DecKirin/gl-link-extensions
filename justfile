# GL-Link extensions — https://github.com/casey/just

# gllink-ext, from source: `just ext help`
[positional-arguments]
ext *args:
    swift run gllink-ext "$@"

# The tests, then gllink-ext over every extension here and every marketplace entry
check:
    swift test
    for e in extensions/*.ext; do swift run gllink-ext check "$e"; done
    swift run gllink-ext market check entries --offline

# gllink-ext for both Mac CPUs, in /usr/local/bin
install:
    swift build -c release --product gllink-ext --arch arm64 --arch x86_64
    install .build/apple/Products/Release/gllink-ext /usr/local/bin/gllink-ext

# Sign and pack the extensions here into build/*.glext (your key: `just ext keygen`)
build:
    for e in extensions/*.ext; do swift run gllink-ext build "$e" -o build; done

# Marketplace: every entry's download, SHA-256, publisher and manifest
market-check:
    swift run gllink-ext market check entries

# Marketplace: rewrite index.json and its signature from entries/
market-index key="~/.gllink-ext/marketplace.key":
    swift run gllink-ext market index entries -o . --key {{key}}
