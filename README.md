# rules_flux_deploy

Bazel rules for describing Kubernetes image references, rendering kustomize
deploy directories with digest-pinned images, and pushing those directories as
Flux OCI artifacts.

The model is deliberately split:

- `deploy_image` creates a no-repository `oci_push` target plus image metadata.
- `image_kustomization` copies a deploy tree and rewrites image refs with digest pins.
- `flux_push` pushes a rendered deploy directory with `flux push artifact`.
- `push_bundle` / `publish_bundle_set` coordinate image pushes and Flux pushes.

Static kustomize overlays still own Kubernetes concerns such as pull secrets,
namespaces, and environment-specific patches. These rules focus on image
identity and OCI bundle publishing.

## Setup

```starlark
bazel_dep(name = "rules_flux_deploy", version = "0.1.0")

flux_deploy_deps = use_extension(
    "@rules_flux_deploy//flux_deploy:extensions.bzl",
    "flux_deploy_dependencies",
)
use_repo(flux_deploy_deps, "rules_flux_deploy_tools")
```

The module extension downloads pinned Flux and Kustomize binaries for the host
platform and exposes them as Bazel executable targets. Rule users do not need
`flux` or `kustomize` on `PATH`; override `flux_tool` or `kustomize_tool` only
when a repo deliberately wants a custom CLI target.

## Deploy Images

```starlark
load("@rules_flux_deploy//flux_deploy:defs.bzl", "deploy_image")

deploy_image(
    name = "app_image",
    yaml_ref = "ghcr.io/adiom-data/integration-app",
    repository_suffix = "integration-app",
    image = "//services/integration/images/integration:image",
)
```

This says:

- checked-in YAML refers to `ghcr.io/adiom-data/integration-app`
- dynamic environments publish/reference it under suffix `integration-app`
- the digest is inferred from `//services/integration/images/integration:image.digest`
- a no-repository `:app_image_push` target is created for `push_bundle`

The push repository can still be different from the rendered YAML reference.
For example, images may be pushed through a proxy but rendered with the real
registry reference.

`deploy_image` uses `rules_oci` under the hood. It creates the equivalent of:

```starlark
oci_push(
    name = "app_image_push",  # no repository; supplied at runtime
    image = "//services/integration/images/integration:image",
)

image_ref(
    name = "app_image",
    yaml_ref = "ghcr.io/adiom-data/integration-app",
    repository_suffix = "integration-app",
    image = "//services/integration/images/integration:image",
    push = ":app_image_push",
)
```

Use lower-level `image_ref` directly for images that should be pinned in YAML but
not pushed by this ruleset.

## Image Kustomization

```starlark
load("@rules_flux_deploy//flux_deploy:defs.bzl", "image_kustomization")

filegroup(
    name = "app_deploy_srcs",
    srcs = glob(["deploy/app/**"]),
)

image_kustomization(
    name = "app_deploy",
    artifact_suffix = "app-deploy",
    srcs = [":app_deploy_srcs"],
    source_prefix = "deploy/app",
    images = [
        ":app_image",
    ],
    repository_prefix_override_all = "{STABLE_REFERENCE_PREFIX}",
    stamp = True,
)
```

This renders:

```text
{STABLE_REFERENCE_PREFIX}/integration-app@sha256:...
```

If `repository_prefix_override_all` is omitted, each original YAML image repo is
preserved and only the digest is changed:

```starlark
image_kustomization(
    name = "app_deploy",
    artifact_suffix = "app-deploy",
    srcs = [":app_deploy_srcs"],
    source_prefix = "deploy/app",
    images = [":app_image"],
)
```

This renders:

```text
ghcr.io/adiom-data/integration-app@sha256:...
```

`image_kustomization` also describes a deploy bundle: it carries the rendered
directory, `artifact_suffix`, and the underlying `image_ref` entries. Publishers
use that provider to push the bundle and its referenced images without
duplicating the image list.

By default, every copied directory containing `kustomization.yaml` or
`kustomization.yml` is edited once. Set `kustomize_dirs` only when a bundle needs
to restrict image edits to specific directories:

```starlark
image_kustomization(
    name = "app_deploy",
    srcs = [":app_deploy_srcs"],
    source_prefix = "deploy/app",
    artifact_suffix = "app-deploy",
    images = [":app_image"],
    kustomize_dirs = [
        "overlays/prod",
        "overlays/preview",
    ],
)
```

Static bundles that do not need image rewriting can use the same rule with no
images:

```starlark
image_kustomization(
    name = "db_deploy",
    srcs = [":db_deploy_srcs"],
    source_prefix = "deploy/db",
    artifact_suffix = "db-deploy",
)
```

Bundles can also carry deployment-orchestration metadata for generated publish
manifests:

```starlark
image_kustomization(
    name = "migration_deploy",
    bundle_name = "migration",
    artifact_suffix = "migration-deploy",
    srcs = [":migration_deploy_srcs"],
    source_prefix = "deploy/migration",
    overlay_path = "base",
    bundle_pull_secret = "ghcr-pull",
    namespace_id = "prod",
    force = True,
)
```

`bundle_name` defaults to the target name, `overlay_path` defaults to `./`, and
`bundle_pull_secret` and `namespace_id` are omitted from publish manifests unless
set. `force` defaults to `False`.

Stamped placeholders come from Bazel stable status, usually configured with:

```text
build --workspace_status_command=./tools/status.sh
```

Example status script:

```sh
#!/usr/bin/env bash
set -euo pipefail

echo "STABLE_GIT_COMMIT $(git rev-parse --short HEAD)"
echo "STABLE_REFERENCE_PREFIX ${REFERENCE_PREFIX:-ghcr.io/adiom-data}"
```

## Flux Push

```starlark
load("@rules_flux_deploy//flux_deploy:defs.bzl", "flux_push")

flux_push(
    name = "app_deploy_push",
    artifact = "oci://ghcr.io/adiom-data/integration-app-deploy",
    bundle = ":app_deploy",
    tag = "latest",
    source = "git@example.com:adiom/slack.git",
    revision = "{STABLE_GIT_COMMIT}",
)
```

Flux pushes are reproducible by default. The rules pass `--reproducible`, which
normalizes Flux's OCI `org.opencontainers.image.created` annotation so repeated
pushes of the same bundle, source, and revision produce the same artifact
digest. Set `reproducible = False` or pass `--no-reproducible` at runtime to use
Flux's default current-timestamp behavior.

Push with:

```sh
bazel run //deploy:app_deploy_push
```

Or override the Flux push destination at runtime:

```sh
bazel run //deploy:app_deploy_push -- \
  --artifact oci://proxy.example/previews/org/session/app-deploy \
  --tag session-123
```

For HTTP preview registries or in-cluster registry proxies, pass `--insecure` or
set `insecure = True`. This adds `--insecure-registry` to Flux pushes.

For static deploy bundles that do not need image rewriting, `flux_push` can
stage a filegroup directly:

```starlark
filegroup(
    name = "db_deploy_srcs",
    srcs = glob(["deploy/db/**"]),
)

flux_push(
    name = "db_deploy_push",
    srcs = [":db_deploy_srcs"],
    source_prefix = "deploy/db",
    artifact = "oci://ghcr.io/adiom-data/integration-db-deploy",
)
```

Use `bundle = ":app_deploy"` when pushing a rendered `image_kustomization`; use
`srcs = [":db_deploy_srcs"]` for a static deploy tree.

When pushing rendered bundles, the generated scripts resolve Bazel runfiles
symlinks to the physical tree artifact directory before invoking Flux. This
ensures `flux push artifact --path` packages the rendered files, including any
nested overlay paths referenced by deployment orchestration.

## Preview Shape

For a preview, the image push step can use `rules_oci` dynamically:

```sh
bazel run //services/app:image_push -- \
  --repository "$PUSH_PREFIX/integration-app" \
  --tag "$TAG"
```

Then the rendered deploy bundle can reference the real pull location:

```sh
REFERENCE_PREFIX="$REAL_PREFIX" \
bazel run //deploy:app_deploy_push -- \
  --artifact "oci://$PUSH_PREFIX/app-deploy" \
  --tag "$TAG"
```

The proxy is a publishing detail; the rendered Kubernetes YAML should point at
the registry location the cluster will pull.

## Push Bundle

`push_bundle` consumes one or more `image_kustomization` bundle targets. It
pushes referenced images first, then pushes each Flux OCI deploy artifact.

```starlark
load("@rules_flux_deploy//flux_deploy:defs.bzl", "push_bundle")

push_bundle(
    name = "publish_app",
    bundles = [":app_deploy"],
    push_prefix = "ghcr.io/adiom-data",
    push_tags = [
        "{STABLE_GIT_COMMIT}",
        "latest",
    ],
    compare_tag = "latest",
    skip_existing = True,
    source = "git@example.com:adiom/slack.git",
    revision = "{STABLE_GIT_COMMIT}",
    stamp = True,
)
```

Run with defaults:

```sh
bazel run //deploy:publish_app
```

Override for a proxy or preview:

```sh
bazel run //deploy:publish_app -- \
  --push-prefix "$PUSH_PREFIX" \
  --artifact-prefix "$PUSH_PREFIX" \
  --tag "$GIT_SHA" \
  --tag latest \
  --compare-tag latest \
  --source "$SOURCE" \
  --revision "$REVISION" \
  --skip-existing \
  --insecure
```

`tag = "latest"` remains supported as the single-tag form. Use `push_tags` when
you need to apply more than one tag. Runtime `--tag` is repeatable and replaces
configured tags for that invocation.

`skip_existing` is opt-in and defaults to `False`. When enabled, `push_bundle`
checks the configured or runtime `compare_tag`, which defaults to `latest`.
Missing compare tags push normally. If the compare tag already points at the
same image manifest digest or the same Flux content layer digest, the push is
skipped and no requested tags are applied.

Pass `--no-reproducible` only when the Flux artifact should carry the current
push timestamp and therefore receive a new digest even if the bundle content is
unchanged.

`--insecure` is intended for HTTP preview registries or registry proxies. It
adds `--insecure` to image pushes and `--insecure-registry` to Flux artifact
pushes.

For each image with a `push` target on `image_ref`, it runs:

```text
oci_push --repository "$push_prefix/$repository_suffix" --tag "$tag" ...
```

Then for each bundle, it runs:

```text
flux push artifact "oci://$artifact_prefix/$artifact_suffix:$tag"
```

## Publish Sets

Use `publish_bundle_set` when you want one declaration to create individual
publish targets and an all target:

```starlark
load("@rules_flux_deploy//flux_deploy:defs.bzl", "publish_bundle_set")

publish_bundle_set(
    name = "publish",
    bundles = [
        ":app_deploy",
        ":db_deploy",
        ":nats_deploy",
    ],
    push_prefix = "ghcr.io/adiom-data",
    bundle_pull_secret = "ghcr-pull",
    namespace_id = "prod",
    manifest_tag = "deploy-ref",
    push_tags = ["{STABLE_GIT_COMMIT}", "latest"],
    compare_tag = "latest",
    skip_existing = True,
)
```

This creates:

```text
:publish_app_deploy
:publish_db_deploy
:publish_nats_deploy
:publish_all
:publish_app_deploy_manifest
:publish_db_deploy_manifest
:publish_nats_deploy_manifest
:publish_manifest
```

The manifest targets produce JSON describing the Flux bundle locations and
orchestration metadata. Bundle refs are untagged unless `manifest_tag` is set:

```json
{
  "bundles": [
    {
      "name": "app_deploy",
      "oci_bundle": "oci://ghcr.io/adiom-data/app-deploy:deploy-ref",
      "overlay_path": "./",
      "namespace_id": "prod",
      "bundle_pull_secret": "ghcr-pull",
      "force": false
    },
    {
      "name": "migration",
      "oci_bundle": "oci://ghcr.io/adiom-data/migration-deploy:deploy-ref",
      "overlay_path": "base",
      "force": true
    }
  ]
}
```
