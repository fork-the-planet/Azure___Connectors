# Releasing

This repository publishes public preview connector artifacts through GitHub Releases.

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

## Release workflow

Use the **Release connector namespace CLI** workflow for new wheel releases.

The workflow publishes the release with `GITHUB_TOKEN` instead of an individual account. It validates the requested version, release tag, wheel file name, wheel SHA-256, and wheel package metadata before creating the GitHub Release. After publication, it reads back the release and fails if the new release does not report `immutable=true`.

Required workflow inputs:

| Input | Purpose |
| --- | --- |
| `version` | Package version without a leading `v`, for example `1.0.0b34` |
| `target_ref` | Azure/Connectors ref or commit used for the release tag |
| `wheel_url` | HTTPS URL for `connector_namespace-<version>-py3-none-any.whl` from the approved build |
| `wheel_sha256` | Expected SHA-256 for the wheel |
| `notes_start_tag` | Previous release tag used for generated notes |
| `prerelease` | Whether the GitHub Release should be marked as a prerelease |

Before running the workflow:

1. Produce the wheel from the owner-approved connector namespace CLI build.
2. Record the source/build run that produced the wheel.
3. Compute and review the wheel SHA-256.
4. Confirm the requested `version` matches the wheel metadata.
5. Confirm `target_ref` points to the repository commit that should own the release tag.

The release job uses the `release` environment. This is the native GitHub Actions approval hook, but it is only an actual approval gate after the repository environment is configured.

Required environment setting:

- Environment name: `release`
- Required reviewers: a small maintainer/release-owner team, for example `@Azure/azure-connectors-contributors` until a narrower release-owner team exists
- Prevent self-review: enabled, if available in the repository UI
- Deployment branches: restrict to `main`, or protected branches that include `main`

A configuration attempt from the audit session failed with `Must have admin rights to Repository`, so an admin/JIT owner must create or update this environment before the workflow is used for production release validation.

## Why the workflow is safer

A workflow-backed release is safer than publishing artifacts from an individual account because it gives the repo a repeatable managed identity, auditable logs, constrained permissions, and a path to provenance or attestation.

This repository currently does not contain the generated `azext_connector_namespace` source that appears inside the published wheel. Until that source and build are available in this repository, the release workflow cannot truthfully claim to build the wheel from local source. The current workflow therefore treats the wheel as an input from the approved build and validates it before publication.

The stronger future state is:

1. Build the wheel in GitHub Actions from pinned, repository-owned source.
2. Create provenance or artifact attestations for that build.
3. Create the release as a draft.
4. Upload all assets while the release is still a draft.
5. Publish the release only after all assets are attached.
6. Read back the release, tag, asset, and immutability metadata.

## Manual release fallback

Manual publishing should be treated as break-glass. Until the release workflow is fully adopted, a maintainer may publish a release manually only after producing the expected wheel asset from the owner-approved build process.

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

A release workflow applies to this repository for generated artifacts such as the connector namespace wheel. The repository also contains documentation and plugin skill content; those files alone do not require package publishing automation. The wheel asset does.

If a future release contains only documentation or plugin skill text with no generated artifact, the release owner should decide whether a GitHub Release is needed at all. If a GitHub Release is used, keep the same tag and immutability validation steps.