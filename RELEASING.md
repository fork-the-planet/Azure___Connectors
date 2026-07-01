# Releasing

This repository currently publishes public preview connector artifacts through GitHub Releases.

## Current release model

Releases are tag-based:

- Release tags use the `v<version>` shape, for example `v1.0.0b33`.
- The public preview CLI documentation downloads wheel assets from GitHub release tag URLs.
- Each release tag is expected to publish a matching wheel asset named `connector_namespace-<version>-py3-none-any.whl`.

Do not create disposable `v*` tags for testing. Release tags are protected and are expected to represent real preview artifacts.

## Security controls

The repository has release-tag protection and future release immutability enabled:

- The active tag ruleset protects `refs/tags/v*` from deletion and non-fast-forward updates.
- Published releases are expected to become immutable after publication.
- Existing older releases may not show as immutable if they were published before immutability was enabled.

After publishing a release, verify:

```powershell
gh api repos/Azure/Connectors/releases/tags/v<version>
gh api repos/Azure/Connectors/git/ref/tags/v<version>
gh api repos/Azure/Connectors/rulesets/18361079
```

Expected evidence:

- The release exists and is not a draft.
- Preview releases use `prerelease=true`.
- New releases should report `immutable=true`.
- The tag ref points to the intended commit or annotated tag object.
- The tag ruleset remains active for `refs/tags/v*` with `deletion` and `non_fast_forward` rules.

## Preferred release process

A workflow-backed release is safer than publishing artifacts from an individual account because it gives the repo a repeatable managed identity, auditable logs, constrained permissions, and a path to provenance or attestation.

The preferred future process is:

1. Build the wheel in GitHub Actions from the selected commit.
2. Create the release as a draft.
3. Upload all assets while the release is still a draft.
4. Publish the release only after all assets are attached.
5. Read back the release, tag, and asset metadata.

A release workflow should use least-privilege permissions, for example:

```yaml
permissions:
  contents: write
  id-token: write
```

Use `contents: write` only for the release job that creates the tag or release. Use `id-token: write` only if provenance, artifact attestations, or trusted publishing are enabled.

## Manual release fallback

Until a release workflow exists, a maintainer may publish a release manually only after producing the expected wheel asset from the owner-approved build process.

Example command shape:

```powershell
gh release create v<version> `
  --repo Azure/Connectors `
  --target <commit-sha> `
  --title "v<version> (preview)" `
  --prerelease `
  --latest=false `
  --notes-file <release-notes.md> `
  <path-to-connector_namespace-<version>-py3-none-any.whl>
```

`gh release create` has no dry-run mode. If the tag does not already exist, it creates the tag automatically unless `--verify-tag` is supplied.

## When a release workflow applies

A release workflow does apply to this repository for any generated artifact such as the connector namespace wheel. The repository also contains documentation and plugin skill content; those files alone do not require a package publishing workflow. The wheel asset does.

If a future release contains only documentation or plugin skill text with no generated artifact, the release owner should decide whether a GitHub Release is needed at all. If a GitHub Release is used, keep the same tag and immutability validation steps.