# releases.ecash.com

Signed, immutable builds published from GitHub Actions. Any repository publishes by calling
[`publish.yml`](.github/workflows/publish.yml); consumers verify with `gh attestation verify` or
[`scripts/fetch-release.sh`](scripts/fetch-release.sh).

## Layout

```
<project>/<channel>/<commit>/     immutable, one per published commit
    <project>-<target>.zip        unpacks to <project>-<version>-<commit>-<target>/
    SHA256SUMS
    release.json
    provenance.jsonl              Sigstore bundle attesting every file above
<project>/<channel>/latest/       moving copy of the newest <commit>/
index.json                        every latest/release.json, keyed by <project>/<channel>
```

`<channel>` is the published branch. `<commit>` is the first 12 hex characters of the source commit.
Files under `<commit>/` are never overwritten. `latest/` moves only after every file is in place.
Read `latest/release.json`, then fetch from the immutable `path` it names.

```json
{
  "version": "31.1.0",
  "commit": "ca64033c137457a3c8ca394186759819a2ab0694",
  "commit_short": "ca64033c1374",
  "repository": "ecash-com/bitcoin",
  "path": "L1-ecash-bitcoin/betanet/ca64033c1374/",
  "files": [
    { "name": "L1-ecash-bitcoin-x86_64-unknown-linux-gnu.zip", "sha256": "…", "size": 31220833 }
  ]
}
```

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

The signer is this repository's workflow. The source is the repository that called it. One publisher
is trusted for every project, and `--repo` pins the project. `release.json` is attested too.

```sh
scripts/fetch-release.sh L1-ecash-bitcoin ecash-com/bitcoin betanet x86_64-unknown-linux-gnu ./bitcoin-betanet
```

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

A job on the release branch calls the workflow:

```yaml
publish:
  needs: [build]
  if: >-
    github.event_name == 'push' && github.repository_owner == 'my-org' &&
    contains(fromJSON('["main", "betanet"]'), github.ref_name)
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
      x86_64-apple-darwin
      aarch64-apple-darwin
  secrets: inherit
```

Pin to a commit SHA and bump through reviewed PRs: the pinned revision decides what gets signed
under the caller's identity. `channel` becomes a URL path component and must match
`[A-Za-z0-9._-]+`.

The calling repository needs a `releases` environment whose deployment-branch policy lists the
publishing branches. That policy is what gates the secrets. The environment holds:

| Secret                 | Value                 |
| ---------------------- | --------------------- |
| `R2_ACCESS_KEY_ID`     | R2 API token id       |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret   |
| `R2_ACCOUNT_ID`        | Cloudflare account id |
| `R2_BUCKET`            | bucket name           |

R2 tokens are scoped per bucket, not per prefix; issue one per repository so they can be revoked
independently.

Re-running only the publish job reuses the original artifacts and reproduces identical zips.
Re-running the whole workflow rebuilds, and if the bytes differ the publish fails rather than
overwrite. Publish a new commit instead.
