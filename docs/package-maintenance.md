# Package Maintenance

`manifests/packages.json` is the canonical inventory for package paths, build
order, build/image profile membership, owners, test tiers, and external build
inputs. Do not add package lists to build scripts or documentation. Useful
queries are:

```bash
python3 scripts/package-manifest.py validate
python3 scripts/package-manifest.py profile build
python3 scripts/package-manifest.py profile image --format space
python3 scripts/package-manifest.py profile release --format space
python3 scripts/package-manifest.py inputs linux-thorch
```

Add every new `packages/*/PKGBUILD` directory to the manifest. The validator
fails both for unlisted package directories and manifest entries without a
PKGBUILD. The record order is the dependency-safe build order. `--packages`
selections are normalized back into this order; legacy names are resolved only
through the manifest's aliases. Fast CI parses every generated `.SRCINFO` and
rejects an internal runtime, build, or check dependency whose provider is
missing or appears after its consumer.

## Inputs and versions

The package directory is always an input. `build_inputs` names external input
trees copied into the isolated aarch64 build root. Add `version_inputs` only for
tracked paths outside the package directory that directly change the package
artifact.

Build inputs use an allowlisted configuration variable followed only by normal
repository-relative path components. `.` and `..` components are rejected, as
are absolute or traversing configured input roots. The builder resolves both
source and staging destinations canonically before any privileged removal or
copy. Contributors can run the same check without root or a build root:

```bash
scripts/build-packages.sh --validate-input-paths
```

If any declared tracked input changes, increase the package's static
`epoch:pkgver-pkgrel` according to pacman's `vercmp` ordering. CI runs:

```bash
python3 scripts/check-package-versions.py --base-ref origin/main
```

New packages are accepted at their initial version. Existing packages fail the
check when an input changes without a strictly greater version. Dynamic
`pkgver()` values are intentionally unsupported because CI must be able to
compare the source and base trees without building them.

## Isolated builds

`scripts/build-packages.sh` maintains `build/pkg-base-root` as the updated,
pristine Arch Linux ARM base. Before each package, it recreates `build/pkg-root`
from that base, stages the current local Thorch repository, copies only the
external inputs declared for that package, and generates `.SRCINFO`. The build
then runs `makepkg --syncdeps`; runtime, build, and check dependencies must
therefore be declared in the PKGBUILD. Do not restore
`.thorch-build-pacman-deps` or use `makepkg --nodeps`.

Internal Thorch dependencies must appear in `depends` and their providers must
come earlier in the manifest. A targeted build can consume an already built
internal dependency from `output/repo`; a full profile build produces them in
order. The local repository is refreshed after every successful package.
In particular, `linux-thorch` uses the canonical config parser and transaction
hooks installed by `thorch-bsp`, so the BSP is a runtime dependency and
deliberately precedes the kernel package. This keeps the hooks installed and
avoids a second IKCONFIG parser.

The `release` profile is the publication allowlist. Never publish
`thorch-boot-bootstrap-ready`: it is a machine-local marker generated only
after the legacy hook-mask migration has completed. Keeping it out of the
release repository makes a direct legacy `pacman -Syu` fail dependency
resolution before an unguarded kernel transaction can start. Fresh image
composition includes the marker through the `image` profile; supported legacy
bootstrap installs an equivalent local package before enabling boot hooks.

After building, `scripts/check-package-repo.py` checks `.PKGINFO`, required
package presence, and duplicate non-directory paths across Thorch packages.
Package installation/upgrade fixtures must additionally run pacman's database
integrity check because archive inspection cannot prove that dependencies from
the base repository remain available.

Before the mutable developer repository is pruned or regenerated, the builder
copies its self-contained bytes and a `SHA256SUMS` inventory to the
content-addressed sibling directory `output/repo.cohorts/`. It archives the
successfully validated final state too. These unsigned archives prevent local
iteration from destroying the prior test input; they are not qualified release
cohorts and must not be published. A future publisher must select only the
manifest `release` profile, sign it, and bind it to a qualified base snapshot.

The builder records a JSON binding for each cached artifact under
`output/repo/.thorch-inputs/`. It binds the exact package bytes to a complete
fingerprint of each declared tree: paths, file contents and modes, directory
entries (including empty directories), symlink targets, and missing inputs.
Reuse requires both the current declared-input fingerprint and the artifact
SHA-256 to match the binding. A build is discarded if its declared inputs
change between staging and completion. The all-fresh early exit and final
repository validation also verify every current artifact binding and
current/retained package identity.

If a rebuilt candidate has the same name, version, and architecture as an
existing package but different bytes, the build fails and requires an epoch,
`pkgver`, or `pkgrel` increase. This comparison includes every locally retained
`repo.cohorts/` generation, not just the mutable current repository. Missing or
legacy input-only sidecars are never silently reused. A repository that
predates artifact bindings can be adopted only with the explicit
`--skip-fresh --trust-existing` migration assertion, after its current and
retained identities have passed validation. A future publisher must repeat the
same NEVRA-to-digest comparison against every remotely retained channel
cohort; the local archive is not a substitute for that Milestone 2 gate.

## Configuration ownership

Package-owned defaults and generated machine state are separate files. Put
administrator-editable configuration in `/etc` and list it in `backup=()` only
when pacman should preserve local edits. Do not list generated files in
`backup=()` and do not have runtime tools rewrite package-owned defaults.

For example, `thorch-kde-defaults` owns static SDDM policy in
`10-thorch.conf`; `thorch-sessionctl` owns generated local state in
`90-thorch-local.conf`, which is deliberately absent from the package archive.
