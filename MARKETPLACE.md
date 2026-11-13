# The marketplace

What GL-Link lists under Settings → App Extensions → Browse Extensions: the extensions people
share, each with its source public on GitHub.

```
entries/<id>.json     one file per shared extension, added by pull request
index.json            every entry in one file: what the app reads. Generated
index.json.sig        the marketplace's signature of index.json. Generated
.github/workflows/    checks each pull request; signs the index when one is merged
```

## The rules

1. **The source is public on GitHub.** An entry names its repository, and its manifest names
   the same one.
2. **The file is a release of that repository.** `download` is a `.glext` attached to one of
   its releases, and nothing else: the file people get has its history in the open.
3. **It's signed by its publisher.** The entry carries the publisher's public key. The
   `.glext` must be signed with it, and so must every later version: a pull request that
   changes an extension's key fails the check, and needs a maintainer to agree.
4. **The entry is what the package says.** Its name, version, platforms and permissions are
   the manifest's. People see the permissions before they download anything.
5. **A change is a new version.** An entry only changes together with a higher `version`.

GL-Link checks these again on the device: the list must be signed by the marketplace, the
download must match the entry's SHA-256, and the package must be signed by the entry's key.
An extension still reaches only what its manifest asks for, whoever wrote it.

Being listed says who published an extension and that its source can be read. It doesn't say
anyone reviewed the code.

## Sharing an extension

You need `gllink-ext` (`swift run gllink-ext` in this repository; [`README.md`](README.md)),
GitHub's `gh`, and a public repository holding your extension's source.

```sh
gllink-ext keygen                 # once: your publisher key. Back it up
gllink-ext check Thing.ext        # what GL-Link would say about it
gllink-ext publish Thing.ext      # signs and packs it, releases it in your repository,
                                  # and writes com.you.thing.json
```

`manifest.json` needs `"repo": "https://github.com/you/your-repo"`. The release is tagged
`Thing-1.0.0`, after the extension and its version, so one repository can hold several.

Then open a pull request here that adds `com.you.thing.json` to `entries/`. The check
downloads your release as anyone would, and compares it with the entry. Once it's merged, the
index is signed again and the app lists your extension.

**To update:** raise `version` in the manifest, run `gllink-ext publish` again, and open a
pull request with the new entry.

**If you lose your key,** you can't sign updates as the same publisher. Say so in a pull
request that changes the entry's key; a maintainer decides. People who have the extension
installed will be asked to remove it and install it again.

## Maintaining this repository

- **The marketplace key** signs `index.json`. Its public half is in the app
  (`Catalog.marketplaceKey`); the private half is the `MARKETPLACE_KEY` secret here, and
  nowhere else but its owner's Mac.
- **The check** (`.github/workflows/marketplace.yml`) runs `gllink-ext market check` on every
  pull request, with the tool built from `main`, not from the pull request. It has no
  secrets, so a pull request from a fork can't reach the key.
- **Signing** runs on `main` only: `gllink-ext market index` rewrites `index.json` and
  `index.json.sig` from `entries/`.
- **By hand:** `just market-check` and `just market-index`.
- **Removing an extension:** delete its entry. It stops being listed; installed copies stay
  until their owners remove them.
