# releases.ecash.com

Signed, immutable builds published from GitHub Actions. Any repository publishes by calling
[`publish.yml`](.github/workflows/publish.yml); consumers verify with `gh attestation verify` or
[`scripts/fetch-release.sh`](scripts/fetch-release.sh).

## Layout

```
<project>/<channel>/<commit>/     immutable, one per published build
    <project>-<target>.zip        unpacks to <project>-<version>-<commit>-<target>/
    SHA256SUMS
    release.json                  version, commit, ref, path, files (name, target, sha256, size)
    provenance.jsonl              Sigstore bundle attesting every file above
<project>/<channel>/latest/       moving copy of the newest <commit>/
index.json                        every latest/release.json, keyed by <project>/<channel>
```

`<channel>` is the published branch, or any stream name the caller picks (`nightly`, `release`).
`<commit>` is the first 12 hex characters of the source commit, or the caller's `release-id`. Files
under `<commit>/` are never overwritten. `latest/` moves only after every file is in place. Read
`latest/release.json`, then fetch from the immutable `path` it names.

## Verifying

Needs the [GitHub CLI](https://cli.github.com).

```sh
gh attestation verify L1-ecash-bitcoin-x86_64-unknown-linux-gnu.zip \
  --bundle provenance.jsonl \
  --repo ecash-com/bitcoin \
  --signer-workflow ecash-com/releases/.github/workflows/publish.yml \
  --source-ref refs/heads/betanet \
  --source-digest ca64033c137457a3c8ca394186759819a2ab0694 \
  --deny-self-hosted-runners
```

The signer is this repository's workflow, the source is the repository that called it, and `--repo`
pins the project. `release.json` is attested too and records the `ref` the build ran on
(`refs/tags/<tag>` for a tag build).

```sh
scripts/fetch-release.sh L1-ecash-bitcoin ecash-com/bitcoin betanet x86_64-unknown-linux-gnu ./bitcoin-betanet
```

The script verifies against the ref in `release.json`. Set `EXPECT_REF` to require a specific one.

## Publishing

Builds upload one artifact per target, named `*-<target>`, containing the files to ship plus a
`VERSION` file:

```yaml
- run: |
    mkdir -p artifacts
    cp build/bin/mytool artifacts/
    printf '%s\n' "$VERSION" > artifacts/VERSION
- uses: actions/upload-artifact@<sha>
  with:
    name: mytool-${{ matrix.target }}
    path: artifacts
    if-no-files-found: error
```

A job on a release branch or tag calls the workflow:

```yaml
publish:
  needs: [build]
  if: github.event_name == 'push' && github.repository_owner == 'my-org'
  permissions:
    contents: read
    id-token: write
    attestations: write
  uses: ecash-com/releases/.github/workflows/publish.yml@<commit sha>
  with:
    project: mytool
    channel: ${{ github.ref_name }}
    artifact-pattern: mytool-*
    targets: |
      x86_64-unknown-linux-gnu
      aarch64-apple-darwin
  secrets: inherit
```

Pin to a commit SHA and bump through reviewed PRs: the pinned revision decides what gets signed
under the caller's identity. `channel` and `release-id` become URL path components and must match
`[A-Za-z0-9._-]+`.

Optional inputs:

- `release-id`: name of the immutable directory instead of the commit. Pass `${{ github.ref_name }}`
  to publish a tag under its version.
- `zip-naming: versioned`: zips are named `<project>-<version>-<target>.zip`, and `latest/` holds
  stable `<project>-latest-<target>.zip` copies.

A project can publish pushes to `nightly` and tags to `release` with two calls. Put the kind of
build in `VERSION` (for example `0.19.0-nightly.<commit>`).

The calling repository needs a `releases` environment whose deployment policy lists the publishing
branches and tags. That policy is what gates the secrets. The environment holds `R2_ACCESS_KEY_ID`,
`R2_SECRET_ACCESS_KEY`, `R2_ACCOUNT_ID` and `R2_BUCKET`. R2 tokens are scoped per bucket, not per
prefix; issue one per repository so they can be revoked independently.

Re-running only the publish job reproduces identical zips. Re-running the whole workflow rebuilds,
and if the bytes differ the publish fails rather than overwrite. Publish a new commit instead.
