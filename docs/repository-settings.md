# Repository settings

The expected `main` branch policy is stored in
`.github/rulesets/main.json`. Validate it locally with:

```bash
scripts/configure-github-repository.sh --validate
```

An administrator can apply and verify it explicitly:

```bash
gh auth status
scripts/configure-github-repository.sh --apply thorch-os/thorch
scripts/configure-github-repository.sh --check thorch-os/thorch
```

The policy requires pull requests, the aggregate `ci` check, resolved review
conversations, linear history, and protection from force-push or deletion. It
requires no approval while the project has only one maintainer.

Committing the policy does not change GitHub. Only a successful live `--check`
establishes that the repository rules match this file.
