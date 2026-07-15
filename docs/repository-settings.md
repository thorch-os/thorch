# Repository settings

The pull-request workflow creates an aggregate check named `ci`. GitHub branch
rules are server-side state, so committing a workflow does not by itself make
that check mandatory. The expected default-branch policy is versioned in
`.github/rulesets/main.json` and can be validated without network access:

```bash
scripts/configure-github-repository.sh --validate
```

An administrator with `Administration:write` permission can deliberately
create or update the ruleset, then verify the live state:

```bash
gh auth status
scripts/configure-github-repository.sh --apply thorch-os/thorch
scripts/configure-github-repository.sh --check thorch-os/thorch
```

`--apply` is never run by CI and should be reviewed like any other repository
administration change. The policy requires pull requests, the current `ci`
result against the latest default branch, resolved review conversations, linear
history, and protection from force-push/deletion. It deliberately requires zero
approvals while the repository has only one verified maintainer; increase that
count and enable CODEOWNER review only after another maintainer has write access
and can provide non-deadlocking review.

After changing the workflow job name, update the ruleset in the same pull
request and apply it only after the renamed check has run at least once. A
passing local validation does not prove the live GitHub setting; `--check` is
the evidence for that state.

The committed Dependabot policy covers GitHub Actions and the Docker base.
Repository administrators must separately enable private vulnerability
reporting, secret scanning, and push protection in GitHub's security settings;
those are server-side controls and are not established by the files in this
repository. Record a dated settings screenshot or API result in the release
evidence instead of treating this checklist as proof that they are active.
