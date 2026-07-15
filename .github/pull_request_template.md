## Summary

Describe the user-visible or contributor-visible outcome and why this change is needed.

## Scope and ownership

- Affected component(s):
- Affected package(s):
- Package version change (`epoch:pkgver-pkgrel`), or why none is required:
- Migration or compatibility behavior:

## Validation

List exact commands and results. Include a failure/recovery case for risky paths.

- [ ] `make doctor` reports a supported environment, or CI is the documented validation environment.
- [ ] `make ci` passes.
- [ ] Relevant integration/image tests pass, or are explicitly not applicable.
- [ ] Hardware evidence is attached for behavior that cannot be established in rootless CI, or is explicitly not applicable.

Hardware/device, install location (SD/internal), root filesystem, and session tested:

## Safety and release checklist

- [ ] Package/profile manifest inputs and package versions were updated together.
- [ ] No package mutates a file owned by another package without a documented migration.
- [ ] Boot, initramfs, kernel, partition, installer, or storage changes preserve the known-good recovery path and include a failure test.
- [ ] User and administrator configuration remains compatible across an upgrade.
- [ ] New upstream code, firmware, patches, and binary inputs have provenance, license, and integrity metadata.
- [ ] No secret, signing key, credential, generated image, package cache, or proprietary payload is included.
- [ ] Documentation and architecture decisions were updated when a contract changed.

## Reviewer notes

Call out unresolved hardware questions, follow-up work, or reasons this must not yet be promoted to a release channel.
