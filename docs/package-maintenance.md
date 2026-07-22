# Package maintenance

`manifests/packages.json` defines package paths, dependency-safe order, build
and image profiles, and external inputs. Do not maintain additional package
lists in build scripts or documentation.

Useful commands:

```bash
python3 scripts/package-manifest.py validate
python3 scripts/package-manifest.py profile build
python3 scripts/package-manifest.py profile image --format space
python3 scripts/package-manifest.py inputs linux-thorch
scripts/build-packages.sh --validate-input-paths
```

Add every new `packages/*/PKGBUILD` directory to the manifest. Internal
dependencies must be declared by the consumer and their providers must appear
earlier in the manifest.

## Inputs and versions

The package directory is always an input. `build_inputs` lists external trees
copied into the isolated build root; `version_inputs` lists tracked paths
outside the package directory that affect the package artifact.

When a declared input changes, increase the package's static
`epoch:pkgver-pkgrel`. CI compares versions with pacman's ordering:

```bash
python3 scripts/check-package-versions.py --base-ref origin/main
```

Configured input roots must be repository-relative and may not traverse with
`.` or `..`. The builder validates resolved source and destination paths before
copying or removing files.

## Builds and local repositories

Each package is built from a fresh clone of the updated Arch Linux ARM base
root. `makepkg --syncdeps` resolves dependencies from the PKGBUILD and the local
Thorch repository, so one package build cannot leak dependencies into another.

Cached artifacts are reused only when their declared-input fingerprint and
artifact digest still match. Rebuilding the same package name, version, and
architecture with different bytes is rejected; increase the package version
instead. Prior local repository bytes are retained for development rollback and
integrity checks, but they are unsigned build artifacts and must not be
published as a release feed.

`thorch-boot-bootstrap-ready` is a machine-local marker. It is included in
fresh images but excluded from the release profile. Existing installations
create it only after `thorch-update-bootstrap` verifies the transaction hooks
and removes the known legacy hook masks.

After a build, `scripts/check-package-repo.py` validates package metadata,
required packages, cache bindings, and cross-package file ownership.

## Configuration ownership

Put vendor defaults in `/usr`, administrator-editable configuration in `/etc`,
persistent generated state in `/var/lib/thorch`, and temporary state in
`/run/thorch`. List `/etc` files in PKGBUILD `backup=()` only when pacman should
preserve local changes. Runtime tools must not rewrite another package's files.
