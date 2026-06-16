"""Rules for image references, kustomize renders, and Flux pushes."""

load("@rules_oci//oci:defs.bzl", "oci_push")

ImageRefInfo = provider(
    doc = "Describes how a Kubernetes image reference maps to a publishable image.",
    fields = {
        "yaml_ref": "Image name as it appears in checked-in YAML/kustomization files.",
        "repository_suffix": "Stable repository suffix appended to a publish/reference prefix.",
        "digest": "File containing the image digest.",
        "push": "Optional executable oci_push target for publishing this image.",
        "push_runfiles": "Runfiles required by the optional push executable.",
    },
)

DeployBundleInfo = provider(
    doc = "Describes a Flux deploy bundle and the images it references.",
    fields = {
        "bundle": "Rendered deploy directory, when produced by a rule.",
        "srcs": "Static source files for an unrendered deploy bundle.",
        "source_prefix": "Prefix stripped from static source files.",
        "artifact_suffix": "Stable repository suffix for the Flux OCI artifact.",
        "bundle_name": "Human-readable/logical bundle name used in publish manifests.",
        "overlay_path": "Path inside the Flux OCI artifact to reconcile.",
        "force": "Whether deploy orchestration should force this bundle, e.g. for migrations.",
        "images": "ImageRefInfo values referenced by this bundle.",
    },
)

def _sh_quote(s):
    return "'" + str(s).replace("'", "'\"'\"'") + "'"

def _strip_prefix(path, prefix):
    if not prefix:
        return path
    normalized = prefix[:-1] if prefix.endswith("/") else prefix
    if path == normalized:
        return path.rsplit("/", 1)[-1]
    marker = normalized + "/"
    if path.startswith(marker):
        return path[len(marker):]
    fail("source file %r is outside source_prefix %r" % (path, prefix))

def _image_ref_rule_impl(ctx):
    push_runfiles = ctx.runfiles()
    if ctx.attr.push:
        push_runfiles = ctx.attr.push[DefaultInfo].default_runfiles
    return [
        ImageRefInfo(
            yaml_ref = ctx.attr.yaml_ref,
            repository_suffix = ctx.attr.repository_suffix,
            digest = ctx.file.digest,
            push = ctx.executable.push,
            push_runfiles = push_runfiles,
        ),
        DefaultInfo(files = depset([ctx.file.digest] + ([ctx.executable.push] if ctx.executable.push else []))),
    ]

_image_ref_rule = rule(
    implementation = _image_ref_rule_impl,
    attrs = {
        "yaml_ref": attr.string(
            mandatory = True,
            doc = "Image name as it appears in static Kubernetes YAML or kustomization files.",
        ),
        "repository_suffix": attr.string(
            mandatory = True,
            doc = "Stable repository suffix appended to the optional reference prefix.",
        ),
        "digest": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "File containing the image digest, such as a rules_oci .digest target.",
        ),
        "push": attr.label(
            cfg = "target",
            executable = True,
            doc = "Optional executable oci_push target used by push_bundle.",
        ),
    },
    doc = "Associates a static Kubernetes image reference with a publishable image suffix and digest.",
)

def _image_digest_label(image):
    image = str(image)
    if image.startswith(":") or ":" in image:
        return image + ".digest"
    fail("image_ref image labels must include an explicit target name, e.g. //pkg:image")

def image_ref(name, yaml_ref, repository_suffix, image = None, push = None, **kwargs):
    """Associates a Kubernetes image ref with an image digest.

    The digest target is inferred using the rules_oci `[name].digest`
    convention. Pass `push` to let push_bundle publish this image.
    """
    if not image:
        fail("image_ref requires image")
    _image_ref_rule(
        name = name,
        yaml_ref = yaml_ref,
        repository_suffix = repository_suffix,
        digest = _image_digest_label(image),
        push = push,
        **kwargs
    )

def deploy_image(name, image, yaml_ref, repository_suffix, push_name = None, visibility = None, **kwargs):
    """Creates a no-repository oci_push target and an image_ref for deployment."""
    push_target_name = push_name or (name + "_push")
    oci_push(
        name = push_target_name,
        image = image,
        visibility = visibility,
    )
    image_ref(
        name = name,
        image = image,
        push = ":" + push_target_name,
        yaml_ref = yaml_ref,
        repository_suffix = repository_suffix,
        visibility = visibility,
        **kwargs
    )

def _expand_status_placeholders_shell(var_name, status_file):
    return """
if [[ -s {status_file} ]]; then
  while IFS=' ' read -r key value; do
    [[ -n "${{key}}" ]] || continue
    {var_name}="${{{var_name}//\\{{${{key}}\\}}/${{value}}}}"
  done < {status_file}
fi
""".format(
        var_name = var_name,
        status_file = _sh_quote(status_file),
    )

def _expand_status_array_placeholders_shell(array_name, status_file):
    return """
if [[ -s {status_file} ]]; then
  for i in "${{!{array_name}[@]}}"; do
    value="${{{array_name}[$i]}}"
    while IFS=' ' read -r key status_value; do
      [[ -n "${{key}}" ]] || continue
      value="${{value//\\{{${{key}}\\}}/${{status_value}}}}"
    done < {status_file}
    {array_name}[$i]="${{value}}"
  done
fi
""".format(
        array_name = array_name,
        status_file = _sh_quote(status_file),
    )

def _shell_array_assignment(name, values):
    return "%s=(%s)" % (name, " ".join([_sh_quote(value) for value in values]))

def _effective_tags(ctx):
    if ctx.attr.tag and ctx.attr.push_tags:
        fail("%s: specify only one of tag or push_tags" % ctx.label)
    if ctx.attr.push_tags:
        return ctx.attr.push_tags
    return [ctx.attr.tag or "latest"]

def _copy_commands(files, rels, out_expr, out_is_shell_expr = False):
    commands = []
    for i in range(len(files)):
        dest = out_expr + "/" + rels[i]
        dest_dir = dest.rsplit("/", 1)[0] if "/" in dest else out_expr
        if out_is_shell_expr:
            commands.append("mkdir -p \"%s\"" % dest_dir)
            commands.append("cp -p %s \"%s\"" % (_sh_quote(files[i].path), dest))
        else:
            commands.append("mkdir -p %s" % _sh_quote(dest_dir))
            commands.append("cp -p %s %s" % (_sh_quote(files[i].path), _sh_quote(dest)))
    return commands

def _runfiles_helpers():
    return """if [[ -z "${RUNFILES_DIR:-}" && -d "$0.runfiles" ]]; then
  export RUNFILES_DIR="$0.runfiles"
fi
if [[ -z "${RUNFILES_MANIFEST_FILE:-}" && -f "$0.runfiles_manifest" ]]; then
  export RUNFILES_MANIFEST_FILE="$0.runfiles_manifest"
fi

rlocation() {
  local path="$1"
  local key="_main/${path}"
  if [[ "${path}" == ../* ]]; then
    key="${path#../}"
  fi
  if [[ -n "${RUNFILES_DIR:-}" && -e "${RUNFILES_DIR}/${key}" ]]; then
    printf '%s\\n' "${RUNFILES_DIR}/${key}"
  elif [[ -e "$0.runfiles/${key}" ]]; then
    printf '%s\\n' "$0.runfiles/${key}"
  elif [[ -n "${RUNFILES_DIR:-}" && -e "${RUNFILES_DIR}/_main/${path}" ]]; then
    printf '%s\\n' "${RUNFILES_DIR}/_main/${path}"
  elif [[ -e "$0.runfiles/_main/${path}" ]]; then
    printf '%s\\n' "$0.runfiles/_main/${path}"
  elif [[ -n "${RUNFILES_MANIFEST_FILE:-}" ]]; then
    awk -v key="${key}" '$1 == key { print substr($0, length($1) + 2); exit }' "${RUNFILES_MANIFEST_FILE}"
  else
    printf '%s\\n' "${path}"
  fi
}

physical_directory() {
  local path="$1"
  if [[ ! -d "${path}" ]]; then
    echo "expected directory path: ${path}" >&2
    exit 2
  fi
  (cd "${path}" && pwd -P)
}
"""

def _image_kustomization_impl(ctx):
    out = ctx.actions.declare_directory(ctx.attr.name)
    inputs = list(ctx.files.srcs)
    inputs.extend(ctx.attr.kustomize_tool[DefaultInfo].files.to_list())
    rels = []
    for src in ctx.files.srcs:
        rels.append(_strip_prefix(src.short_path, ctx.attr.source_prefix))

    commands = [
        "set -euo pipefail",
        "rm -rf %s" % _sh_quote(out.path),
        "mkdir -p %s" % _sh_quote(out.path),
    ]
    commands.extend(_copy_commands(ctx.files.srcs, rels, out.path))

    commands.append("repository_prefix_override_all=%s" % _sh_quote(ctx.attr.repository_prefix_override_all))
    if ctx.attr.stamp:
        inputs.append(ctx.info_file)
        commands.append(_expand_status_placeholders_shell("repository_prefix_override_all", ctx.info_file.path))
    commands.append('repository_prefix_override_all="${repository_prefix_override_all%/}"')
    commands.append("image_edits=()")
    commands.append("kustomize_tool=\"${PWD}/%s\"" % ctx.executable.kustomize_tool.path)
    commands.append("kustomize_dirs=()")
    if ctx.attr.kustomize_dirs:
        for kustomize_dir in ctx.attr.kustomize_dirs:
            commands.append("kustomize_dirs+=(%s)" % _sh_quote(out.path + "/" + kustomize_dir))
    else:
        commands.extend([
            "while IFS= read -r kustomization_file; do",
            "  kustomize_dirs+=(\"${kustomization_file%/*}\")",
            "done < <(find %s -type f \\( -name kustomization.yaml -o -name kustomization.yml \\) | sort)" % _sh_quote(out.path),
        ])

    image_infos = []
    for target in ctx.attr.images:
        info = target[ImageRefInfo]
        image_infos.append(info)
        inputs.append(info.digest)
        commands.append("digest=$(cat %s)" % _sh_quote(info.digest.path))
        commands.append("repo=%s" % _sh_quote(info.yaml_ref))
        commands.append("if [[ -n \"${repository_prefix_override_all}\" ]]; then repo=\"${repository_prefix_override_all}/%s\"; fi" % info.repository_suffix.lstrip("/"))
        commands.append("image_edits+=(%s=\"${repo}@${digest}\")" % _sh_quote(info.yaml_ref))

    commands.extend([
        "if [[ ${#image_edits[@]} -gt 0 ]]; then",
        "  for kustomize_dir in \"${kustomize_dirs[@]}\"; do",
        "    (cd \"${kustomize_dir}\" && \"${kustomize_tool}\" edit set image \"${image_edits[@]}\")",
        "  done",
        "fi",
    ])

    ctx.actions.run_shell(
        outputs = [out],
        inputs = depset(inputs),
        tools = [ctx.executable.kustomize_tool],
        command = "\n".join(commands),
        mnemonic = "KustomizationRender",
        progress_message = "Rendering kustomization %{label}",
    )

    return [
        DefaultInfo(files = depset([out])),
        DeployBundleInfo(
            bundle = out,
            srcs = [],
            source_prefix = "",
            artifact_suffix = ctx.attr.artifact_suffix,
            bundle_name = ctx.attr.bundle_name or ctx.label.name,
            overlay_path = ctx.attr.overlay_path,
            force = ctx.attr.force,
            images = image_infos,
        ),
    ]

image_kustomization = rule(
    implementation = _image_kustomization_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Kustomize source files copied into the rendered deploy directory.",
        ),
        "source_prefix": attr.string(
            doc = "Prefix stripped from src short paths when copying into the rendered directory.",
        ),
        "images": attr.label_list(
            providers = [ImageRefInfo],
            doc = "image_ref targets to rewrite with kustomize.",
        ),
        "artifact_suffix": attr.string(
            doc = "Stable repository suffix for this Flux OCI deploy artifact, e.g. app-deploy.",
        ),
        "bundle_name": attr.string(
            doc = "Logical bundle name emitted in publish manifests. Defaults to the target name.",
        ),
        "overlay_path": attr.string(
            default = ".",
            doc = "Path inside the Flux OCI artifact to reconcile.",
        ),
        "force": attr.bool(
            default = False,
            doc = "Whether deploy orchestration should force this bundle, e.g. for migrations.",
        ),
        "repository_prefix_override_all": attr.string(
            doc = "Optional bundle-wide repository prefix override, e.g. ghcr.io/acme or {STABLE_REFERENCE_PREFIX}. If omitted, each original YAML image repo is preserved.",
        ),
        "kustomize_dirs": attr.string_list(
            doc = "Directories, relative to the rendered deploy root, where kustomize edit should run. If omitted, all directories containing kustomization.yaml or kustomization.yml are edited.",
        ),
        "kustomize_tool": attr.label(
            cfg = "exec",
            default = Label("@rules_flux_deploy_tools//:kustomize"),
            executable = True,
            allow_single_file = True,
            doc = "Executable kustomize tool used for `kustomize edit set image`.",
        ),
        "stamp": attr.bool(
            default = False,
            doc = "Whether to expand {KEY} placeholders in repository_prefix_override_all from Bazel stable status.",
        ),
    },
    doc = "Copies a deploy tree and rewrites image refs to digest-pinned refs using image_ref metadata.",
)

kustomization = image_kustomization

def _flux_push_impl(ctx):
    input_modes = 0
    if ctx.file.bundle:
        input_modes += 1
    if ctx.attr.path:
        input_modes += 1
    if ctx.files.srcs:
        input_modes += 1
    if input_modes != 1:
        fail("flux_push requires exactly one of bundle, path, or srcs")

    script = ctx.actions.declare_file(ctx.attr.name + ".sh")
    runfiles = []
    runfiles.append(ctx.executable.flux_tool)
    commands = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
        "artifact=%s" % _sh_quote(ctx.attr.artifact),
        "tag=%s" % _sh_quote(ctx.attr.tag),
        "source=%s" % _sh_quote(ctx.attr.source),
        "revision=%s" % _sh_quote(ctx.attr.revision),
        "reproducible=%s" % ("true" if ctx.attr.reproducible else "false"),
        "insecure=%s" % ("true" if ctx.attr.insecure else "false"),
        "",
    ]
    commands.append(_runfiles_helpers())

    if ctx.attr.stamp:
        commands.append(_expand_status_placeholders_shell("artifact", ctx.info_file.path))
        commands.append(_expand_status_placeholders_shell("tag", ctx.info_file.path))
        commands.append(_expand_status_placeholders_shell("source", ctx.info_file.path))
        commands.append(_expand_status_placeholders_shell("revision", ctx.info_file.path))

    if ctx.file.bundle:
        runfiles.append(ctx.file.bundle)
        commands.append("path=$(rlocation %s)" % _sh_quote(ctx.file.bundle.short_path))
        commands.append("path=$(physical_directory \"${path}\")")
    elif ctx.attr.path:
        commands.append("path=%s" % _sh_quote(ctx.attr.path))
    else:
        runfiles.extend(ctx.files.srcs)
        rels = []
        for src in ctx.files.srcs:
            rels.append(_strip_prefix(src.short_path, ctx.attr.source_prefix))
        commands.extend([
            "work=\"${TMPDIR:-/tmp}/flux-push.%s.$$\"" % ctx.attr.name,
            "trap 'rm -rf \"$work\"' EXIT",
            "mkdir -p \"$work\"",
        ])
        commands.extend(_copy_commands(ctx.files.srcs, rels, "$work", out_is_shell_expr = True))
        commands.append("path=\"${work}\"")

    commands.extend([
        "",
        "while [[ $# -gt 0 ]]; do",
        "  case \"$1\" in",
        "    --artifact) artifact=\"$2\"; shift 2 ;;",
        "    --tag) tag=\"$2\"; shift 2 ;;",
        "    --path) path=\"$2\"; shift 2 ;;",
        "    --source) source=\"$2\"; shift 2 ;;",
        "    --revision) revision=\"$2\"; shift 2 ;;",
        "    --reproducible) reproducible=true; shift ;;",
        "    --no-reproducible) reproducible=false; shift ;;",
        "    --insecure) insecure=true; shift ;;",
        "    --no-insecure) insecure=false; shift ;;",
        "    *) echo \"unknown argument: $1\" >&2; exit 2 ;;",
        "  esac",
        "done",
        "",
        "flux_tool=$(rlocation %s)" % _sh_quote(ctx.executable.flux_tool.short_path),
        "flux_args=(push artifact \"${artifact}:${tag}\" --path=\"${path}\" --source=\"${source}\" --revision=\"${revision}\")",
        "if [[ \"${reproducible}\" == true ]]; then flux_args+=(--reproducible); fi",
        "if [[ \"${insecure}\" == true ]]; then flux_args+=(--insecure-registry); fi",
        "exec \"${flux_tool}\" \"${flux_args[@]}\"",
        "",
    ])

    ctx.actions.write(script, "\n".join(commands), is_executable = True)
    all_runfiles = ctx.runfiles(files = runfiles)
    all_runfiles = all_runfiles.merge(ctx.attr.flux_tool[DefaultInfo].default_runfiles)
    if ctx.attr.bundle:
        all_runfiles = all_runfiles.merge(ctx.attr.bundle[DefaultInfo].default_runfiles)
    return DefaultInfo(
        executable = script,
        runfiles = all_runfiles,
    )

flux_push = rule(
    implementation = _flux_push_impl,
    executable = True,
    attrs = {
        "artifact": attr.string(
            mandatory = True,
            doc = "OCI artifact without tag. This may be a proxy push location.",
        ),
        "tag": attr.string(
            default = "latest",
            doc = "Default artifact tag. Override with `bazel run target -- --tag ...`.",
        ),
        "bundle": attr.label(
            allow_single_file = True,
            doc = "Rendered deploy directory from kustomization.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Raw deploy files, often a filegroup, to stage and push without rendering.",
        ),
        "source_prefix": attr.string(
            doc = "Prefix stripped from src short paths when staging raw srcs.",
        ),
        "path": attr.string(
            doc = "Path to push when no bundle target is supplied.",
        ),
        "source": attr.string(
            default = "local",
            doc = "Flux source metadata.",
        ),
        "revision": attr.string(
            default = "local",
            doc = "Flux revision metadata.",
        ),
        "flux_tool": attr.label(
            cfg = "target",
            default = Label("@rules_flux_deploy_tools//:flux"),
            executable = True,
            allow_single_file = True,
            doc = "Executable Flux CLI.",
        ),
        "stamp": attr.bool(
            default = False,
            doc = "Whether to expand {KEY} placeholders in artifact, tag, source, and revision from Bazel stable status.",
        ),
        "reproducible": attr.bool(
            default = True,
            doc = "Whether to pass `--reproducible` to Flux so repeated pushes of identical content have the same digest.",
        ),
        "insecure": attr.bool(
            default = False,
            doc = "Whether to pass `--insecure-registry` to Flux.",
        ),
    },
    doc = "Executable rule that runs `flux push artifact` for a deploy directory.",
)

def _image_key(info):
    return info.repository_suffix

def _push_bundle_impl(ctx):
    configured_tags = _effective_tags(ctx)
    crane = ctx.toolchains["@rules_oci//oci:crane_toolchain_type"]
    jq = ctx.toolchains["@aspect_bazel_lib//lib:jq_toolchain_type"]
    script = ctx.actions.declare_file(ctx.attr.name + ".sh")
    runfiles = []
    runfiles.append(ctx.executable.flux_tool)
    runfiles.append(crane.crane_info.binary)
    runfiles.append(jq.jqinfo.bin)
    commands = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
        "push_prefix=%s" % _sh_quote(ctx.attr.push_prefix),
        "artifact_prefix=%s" % _sh_quote(ctx.attr.artifact_prefix),
        _shell_array_assignment("configured_tags", configured_tags),
        "runtime_tags=()",
        "compare_tag=%s" % _sh_quote(ctx.attr.compare_tag),
        "source=%s" % _sh_quote(ctx.attr.source),
        "revision=%s" % _sh_quote(ctx.attr.revision),
        "push_images=%s" % ("true" if ctx.attr.push_images else "false"),
        "skip_existing=%s" % ("true" if ctx.attr.skip_existing else "false"),
        "reproducible=%s" % ("true" if ctx.attr.reproducible else "false"),
        "insecure=%s" % ("true" if ctx.attr.insecure else "false"),
        "",
    ]

    if ctx.attr.stamp:
        commands.append(_expand_status_placeholders_shell("push_prefix", ctx.info_file.path))
        commands.append(_expand_status_placeholders_shell("artifact_prefix", ctx.info_file.path))
        commands.append(_expand_status_array_placeholders_shell("configured_tags", ctx.info_file.path))
        commands.append(_expand_status_placeholders_shell("compare_tag", ctx.info_file.path))
        commands.append(_expand_status_placeholders_shell("source", ctx.info_file.path))
        commands.append(_expand_status_placeholders_shell("revision", ctx.info_file.path))
    commands.append(_runfiles_helpers())
    commands.extend([
        "",
        "crane_tool=$(rlocation %s)" % _sh_quote(crane.crane_info.binary.short_path),
        "jq_tool=$(rlocation %s)" % _sh_quote(jq.jqinfo.bin.short_path),
        "",
        "is_missing_ref_error() {",
        "  grep -Eiq '(MANIFEST_UNKNOWN|NAME_UNKNOWN|TAG_UNKNOWN|not[ -]?found|404)' \"$1\"",
        "}",
        "",
        "is_transient_image_tag_error() {",
        "  grep -Eiq '(MANIFEST_UNKNOWN|manifest unknown|fetching .+@sha256:)' \"$1\"",
        "}",
        "",
        "run_image_push_with_retries() {",
        "  local attempt max delay status log",
        "  attempt=1",
        "  max=3",
        "  delay=1",
        "  while true; do",
        "    log=$(mktemp)",
        "    if \"$@\" >\"${log}\" 2>&1; then",
        "      cat \"${log}\"",
        "      rm -f \"${log}\"",
        "      return 0",
        "    fi",
        "    status=$?",
        "    cat \"${log}\" >&2",
        "    if [[ \"${attempt}\" -ge \"${max}\" ]] || ! is_transient_image_tag_error \"${log}\"; then",
        "      rm -f \"${log}\"",
        "      return \"${status}\"",
        "    fi",
        "    echo \"image push failed while tagging a just-pushed digest; retrying in ${delay}s (${attempt}/${max})\" >&2",
        "    rm -f \"${log}\"",
        "    sleep \"${delay}\"",
        "    attempt=$((attempt + 1))",
        "    delay=$((delay * 2))",
        "  done",
        "}",
        "",
        "remote_digest() {",
        "  local ref=\"$1\"",
        "  local err status",
        "  err=$(mktemp)",
        "  if [[ \"${insecure}\" == true ]]; then",
        "    if digest=$(\"${crane_tool}\" digest --insecure \"${ref}\" 2>\"${err}\"); then",
        "      rm -f \"${err}\"",
        "      printf '%s\\n' \"${digest}\"",
        "      return 0",
        "    fi",
        "    status=$?",
        "  else",
        "    if digest=$(\"${crane_tool}\" digest \"${ref}\" 2>\"${err}\"); then",
        "      rm -f \"${err}\"",
        "      printf '%s\\n' \"${digest}\"",
        "      return 0",
        "    fi",
        "    status=$?",
        "  fi",
        "  if is_missing_ref_error \"${err}\"; then",
        "    rm -f \"${err}\"",
        "    printf '\\n'",
        "    return 0",
        "  fi",
        "  cat \"${err}\" >&2",
        "  rm -f \"${err}\"",
        "  return \"${status}\"",
        "}",
        "",
        "remote_flux_layer_digest() {",
        "  local ref=\"$1\"",
        "  local err manifest layer_digest status",
        "  err=$(mktemp)",
        "  if [[ \"${insecure}\" == true ]]; then",
        "    if manifest=$(\"${crane_tool}\" manifest --insecure \"${ref}\" 2>\"${err}\"); then",
        "      rm -f \"${err}\"",
        "      layer_digest=$(printf '%s\\n' \"${manifest}\" | \"${jq_tool}\" -r '.layers[0].digest // empty')",
        "      if [[ -z \"${layer_digest}\" ]]; then",
        "        echo \"could not read Flux layer digest from ${ref}\" >&2",
        "        return 2",
        "      fi",
        "      printf '%s\\n' \"${layer_digest}\"",
        "      return 0",
        "    fi",
        "    status=$?",
        "  else",
        "    if manifest=$(\"${crane_tool}\" manifest \"${ref}\" 2>\"${err}\"); then",
        "      rm -f \"${err}\"",
        "      layer_digest=$(printf '%s\\n' \"${manifest}\" | \"${jq_tool}\" -r '.layers[0].digest // empty')",
        "      if [[ -z \"${layer_digest}\" ]]; then",
        "        echo \"could not read Flux layer digest from ${ref}\" >&2",
        "        return 2",
        "      fi",
        "      printf '%s\\n' \"${layer_digest}\"",
        "      return 0",
        "    fi",
        "    status=$?",
        "  fi",
        "  if is_missing_ref_error \"${err}\"; then",
        "    rm -f \"${err}\"",
        "    printf '\\n'",
        "    return 0",
        "  fi",
        "  cat \"${err}\" >&2",
        "  rm -f \"${err}\"",
        "  return \"${status}\"",
        "}",
        "",
        "stage_flux_bundle() {",
        "  local bundle_path=\"$1\"",
        "  local work",
        "  work=$(mktemp -d \"${TMPDIR:-/tmp}/flux-bundle.XXXXXX\")",
        "  mkdir -p \"${work}/bundle\"",
        "  cp -R \"${bundle_path}/.\" \"${work}/bundle/\"",
        "  chmod a-w \"${work}/bundle\"",
        "  printf '%s\\n' \"${work}\"",
        "}",
        "",
        "cleanup_flux_bundle_stage() {",
        "  local work=\"$1\"",
        "  [[ -n \"${work}\" ]] || return 0",
        "  chmod -R u+w \"${work}\" 2>/dev/null || true",
        "  rm -rf \"${work}\"",
        "}",
        "",
        "active_flux_bundle_stage=",
        "cleanup_active_flux_bundle_stage() {",
        "  cleanup_flux_bundle_stage \"${active_flux_bundle_stage}\"",
        "  active_flux_bundle_stage=",
        "}",
        "trap cleanup_active_flux_bundle_stage EXIT",
        "",
        "flux_content_layer_digest() {",
        "  local bundle_path=\"$1\"",
        "  local work artifact hash",
        "  work=$(mktemp -d \"${TMPDIR:-/tmp}/flux-build.XXXXXX\")",
        "  artifact=\"${work}/artifact.tgz\"",
        "  \"${flux_tool}\" build artifact --path \"${bundle_path}\" --output \"${artifact}\" >/dev/null",
        "  if [[ ! -f \"${artifact}\" ]]; then",
        "    echo \"flux build artifact did not create ${artifact}\" >&2",
        "    rm -rf \"${work}\"",
        "    return 2",
        "  fi",
        "  hash=$(shasum -a 256 \"${artifact}\" | awk '{print $1}')",
        "  rm -rf \"${work}\"",
        "  printf 'sha256:%s\\n' \"${hash}\"",
        "}",
    ])

    bundle_infos = []
    image_infos = {}
    image_runfiles = []
    for target in ctx.attr.bundles:
        bundle = target[DeployBundleInfo]
        bundle_infos.append(bundle)
        if bundle.bundle:
            runfiles.append(bundle.bundle)
        for image in bundle.images:
            image_infos[_image_key(image)] = image
            runfiles.append(image.digest)
            if image.push:
                runfiles.append(image.push)
                image_runfiles.append(image.push_runfiles)

    commands.extend([
        "while [[ $# -gt 0 ]]; do",
        "  case \"$1\" in",
        "    --push-prefix) push_prefix=\"$2\"; shift 2 ;;",
        "    --artifact-prefix) artifact_prefix=\"$2\"; shift 2 ;;",
        "    --tag) runtime_tags+=(\"$2\"); shift 2 ;;",
        "    --compare-tag) compare_tag=\"$2\"; shift 2 ;;",
        "    --source) source=\"$2\"; shift 2 ;;",
        "    --revision) revision=\"$2\"; shift 2 ;;",
        "    --skip-images) push_images=false; shift ;;",
        "    --skip-existing) skip_existing=true; shift ;;",
        "    --no-skip-existing) skip_existing=false; shift ;;",
        "    --reproducible) reproducible=true; shift ;;",
        "    --no-reproducible) reproducible=false; shift ;;",
        "    --insecure) insecure=true; shift ;;",
        "    --no-insecure) insecure=false; shift ;;",
        "    *) echo \"unknown argument: $1\" >&2; exit 2 ;;",
        "  esac",
        "done",
        "",
        "push_prefix=\"${push_prefix%/}\"",
        "artifact_prefix=\"${artifact_prefix%/}\"",
        "if [[ -z \"${artifact_prefix}\" ]]; then artifact_prefix=\"${push_prefix}\"; fi",
        "if [[ ${#runtime_tags[@]} -gt 0 ]]; then effective_tags=(\"${runtime_tags[@]}\"); else effective_tags=(\"${configured_tags[@]}\"); fi",
        "if [[ ${#effective_tags[@]} -eq 0 ]]; then echo \"at least one --tag is required\" >&2; exit 2; fi",
        "if [[ -z \"${compare_tag}\" ]]; then echo \"--compare-tag is required\" >&2; exit 2; fi",
        "",
    ])

    if image_infos:
        commands.extend([
            "if [[ \"${push_images}\" == true ]]; then",
        ])
        for key in sorted(image_infos.keys()):
            image = image_infos[key]
            if not image.push:
                commands.append("  echo %s >&2" % _sh_quote("image %s has no push target; skipping" % image.repository_suffix))
                continue
            commands.append("  image_repository=%s" % _sh_quote(image.yaml_ref))
            commands.append("  if [[ -n \"${push_prefix}\" ]]; then image_repository=\"${push_prefix}/%s\"; fi" % image.repository_suffix.lstrip("/"))
            commands.append("  image_push_tool=$(rlocation %s)" % _sh_quote(image.push.short_path))
            commands.append("  skip_image_push=false")
            commands.append("  if [[ \"${skip_existing}\" == true ]]; then")
            commands.append("    local_digest_file=$(rlocation %s)" % _sh_quote(image.digest.short_path))
            commands.append("    local_digest=$(cat \"${local_digest_file}\")")
            commands.append("    remote_compare_digest=$(remote_digest \"${image_repository}:${compare_tag}\")")
            commands.append("    if [[ -n \"${remote_compare_digest}\" && \"${remote_compare_digest}\" == \"${local_digest}\" ]]; then")
            commands.append("      echo \"image ${image_repository}:${compare_tag} already points to ${local_digest}; skipping\"")
            commands.append("      skip_image_push=true")
            commands.append("    fi")
            commands.append("  fi")
            commands.append("  if [[ \"${skip_image_push}\" != true ]]; then")
            commands.append("  image_push_args=(--repository \"${image_repository}\")")
            commands.append("  for tag in \"${effective_tags[@]}\"; do image_push_args+=(--tag \"${tag}\"); done")
            commands.append("  if [[ \"${insecure}\" == true ]]; then image_push_args+=(--insecure); fi")
            commands.append("  run_image_push_with_retries \"${image_push_tool}\" \"${image_push_args[@]}\"")
            commands.append("  fi")
        commands.append("fi")
        commands.append("")

    for bundle in bundle_infos:
        if not bundle.artifact_suffix:
            fail("push_bundle bundle is missing artifact_suffix")
        if not bundle.bundle:
            fail("push_bundle currently requires rendered image_kustomization bundles")
        commands.extend([
            "if [[ -z \"${artifact_prefix}\" ]]; then echo \"--artifact-prefix or --push-prefix is required for %s\" >&2; exit 2; fi" % bundle.artifact_suffix,
            "artifact=\"oci://${artifact_prefix}/%s\"" % bundle.artifact_suffix.lstrip("/"),
            "artifact_ref=\"${artifact#oci://}\"",
            "bundle_path=$(rlocation %s)" % _sh_quote(bundle.bundle.short_path),
            "bundle_path=$(physical_directory \"${bundle_path}\")",
            "flux_tool=$(rlocation %s)" % _sh_quote(ctx.executable.flux_tool.short_path),
            "staged_bundle_work=",
            "push_bundle_path=\"${bundle_path}\"",
            "skip_flux_push=false",
            "if [[ \"${skip_existing}\" == true ]]; then",
            "  staged_bundle_work=$(stage_flux_bundle \"${bundle_path}\")",
            "  active_flux_bundle_stage=\"${staged_bundle_work}\"",
            "  push_bundle_path=\"${staged_bundle_work}/bundle\"",
            "  local_layer_digest=$(flux_content_layer_digest \"${push_bundle_path}\")",
            "  remote_layer_digest=$(remote_flux_layer_digest \"${artifact_ref}:${compare_tag}\")",
            "  if [[ -n \"${remote_layer_digest}\" && \"${remote_layer_digest}\" == \"${local_layer_digest}\" ]]; then",
            "    echo \"flux artifact ${artifact}:${compare_tag} already contains ${local_layer_digest}; skipping\"",
            "    skip_flux_push=true",
            "  fi",
            "fi",
            "if [[ \"${skip_flux_push}\" != true ]]; then",
            "for tag in \"${effective_tags[@]}\"; do",
            "  flux_args=(push artifact \"${artifact}:${tag}\" --path=\"${push_bundle_path}\" --source=\"${source}\" --revision=\"${revision}\")",
            "  if [[ \"${reproducible}\" == true ]]; then flux_args+=(--reproducible); fi",
            "  if [[ \"${insecure}\" == true ]]; then flux_args+=(--insecure-registry); fi",
            "  \"${flux_tool}\" \"${flux_args[@]}\"",
            "done",
            "fi",
            "cleanup_active_flux_bundle_stage",
            "",
        ])

    ctx.actions.write(script, "\n".join(commands), is_executable = True)
    all_runfiles = ctx.runfiles(files = runfiles)
    all_runfiles = all_runfiles.merge(ctx.attr.flux_tool[DefaultInfo].default_runfiles)
    all_runfiles = all_runfiles.merge(crane.default.default_runfiles)
    all_runfiles = all_runfiles.merge(jq.default.default_runfiles)
    for target in ctx.attr.bundles:
        all_runfiles = all_runfiles.merge(target[DefaultInfo].default_runfiles)
    for image_runfiles_entry in image_runfiles:
        all_runfiles = all_runfiles.merge(image_runfiles_entry)
    return DefaultInfo(
        executable = script,
        runfiles = all_runfiles,
    )

push_bundle = rule(
    implementation = _push_bundle_impl,
    executable = True,
    attrs = {
        "bundles": attr.label_list(
            mandatory = True,
            providers = [DeployBundleInfo],
            doc = "image_kustomization bundle targets to publish.",
        ),
        "push_prefix": attr.string(
            doc = "Default registry/repository prefix used for image pushes and, unless artifact_prefix is set, Flux artifacts.",
        ),
        "artifact_prefix": attr.string(
            doc = "Default registry/repository prefix used for Flux artifacts. Defaults to push_prefix at runtime.",
        ),
        "tag": attr.string(
            doc = "Single image and Flux artifact tag. Use either tag or tags.",
        ),
        "push_tags": attr.string_list(
            doc = "Image and Flux artifact tags. Use either tag or push_tags. Defaults to [\"latest\"] when neither is set.",
        ),
        "compare_tag": attr.string(
            default = "latest",
            doc = "Remote tag inspected by skip_existing.",
        ),
        "source": attr.string(
            default = "local",
            doc = "Flux source metadata.",
        ),
        "revision": attr.string(
            default = "local",
            doc = "Flux revision metadata.",
        ),
        "flux_tool": attr.label(
            cfg = "target",
            default = Label("@rules_flux_deploy_tools//:flux"),
            executable = True,
            allow_single_file = True,
            doc = "Executable Flux CLI.",
        ),
        "push_images": attr.bool(
            default = True,
            doc = "Whether to push images before pushing Flux bundles.",
        ),
        "skip_existing": attr.bool(
            default = False,
            doc = "Whether to skip pushes when compare_tag already points at the local image digest or Flux content layer digest.",
        ),
        "stamp": attr.bool(
            default = False,
            doc = "Whether to expand {KEY} placeholders in push_prefix, artifact_prefix, tag, source, and revision from Bazel stable status.",
        ),
        "reproducible": attr.bool(
            default = True,
            doc = "Whether to pass `--reproducible` to Flux so repeated pushes of identical content have the same digest.",
        ),
        "insecure": attr.bool(
            default = False,
            doc = "Whether to pass `--insecure` to image pushes and `--insecure-registry` to Flux pushes.",
        ),
    },
    toolchains = [
        "@aspect_bazel_lib//lib:jq_toolchain_type",
        "@rules_oci//oci:crane_toolchain_type",
    ],
    doc = "Executable rule that pushes referenced images and Flux deploy bundles.",
)

def _publish_manifest_impl(ctx):
    configured_tags = _effective_tags(ctx)
    manifest_tag = ctx.attr.compare_tag if ctx.attr.skip_existing else configured_tags[0]
    out = ctx.actions.declare_file(ctx.attr.name + ".json")
    inputs = []
    commands = [
        "set -euo pipefail",
        "push_prefix=%s" % _sh_quote(ctx.attr.push_prefix),
        "artifact_prefix=%s" % _sh_quote(ctx.attr.artifact_prefix),
        "tag=%s" % _sh_quote(manifest_tag),
        "",
    ]
    if ctx.attr.stamp:
        inputs.append(ctx.info_file)
        commands.append(_expand_status_placeholders_shell("push_prefix", ctx.info_file.path))
        commands.append(_expand_status_placeholders_shell("artifact_prefix", ctx.info_file.path))
        commands.append(_expand_status_placeholders_shell("tag", ctx.info_file.path))

    commands.extend([
        "push_prefix=\"${push_prefix%/}\"",
        "artifact_prefix=\"${artifact_prefix%/}\"",
        "if [[ -z \"${artifact_prefix}\" ]]; then artifact_prefix=\"${push_prefix}\"; fi",
        "if [[ -z \"${artifact_prefix}\" ]]; then echo \"artifact_prefix or push_prefix is required for %s\" >&2; exit 2; fi" % ctx.label,
        "if [[ -z \"${tag}\" ]]; then echo \"tag is required for %s\" >&2; exit 2; fi" % ctx.label,
        "",
        "json_quote() {",
        "  local s=\"$1\"",
        "  s=${s//\\\\/\\\\\\\\}",
        "  s=${s//\\\"/\\\\\\\"}",
        "  s=${s//$'\\n'/\\\\n}",
        "  s=${s//$'\\r'/\\\\r}",
        "  s=${s//$'\\t'/\\\\t}",
        "  printf '\"%s\"' \"$s\"",
        "}",
        "",
        "out=%s" % _sh_quote(out.path),
        "mkdir -p \"${out%/*}\"",
        "{",
        "  printf '{\\n'",
        "  printf '  \"bundles\": [\\n'",
    ])

    bundle_infos = []
    for target in ctx.attr.bundles:
        bundle_infos.append(target[DeployBundleInfo])

    for i in range(len(bundle_infos)):
        bundle = bundle_infos[i]
        if not bundle.artifact_suffix:
            fail("publish_manifest bundle is missing artifact_suffix")
        comma = "," if i < len(bundle_infos) - 1 else ""
        commands.extend([
            "  bundle_name=%s" % _sh_quote(bundle.bundle_name),
            "  artifact_suffix=%s" % _sh_quote(bundle.artifact_suffix.lstrip("/")),
            "  overlay_path=%s" % _sh_quote(bundle.overlay_path),
            "  oci_bundle=\"oci://${artifact_prefix}/${artifact_suffix}:${tag}\"",
            "  printf '    {\"name\": '",
            "  json_quote \"${bundle_name}\"",
            "  printf ', \"oci_bundle\": '",
            "  json_quote \"${oci_bundle}\"",
            "  printf ', \"overlay_path\": '",
            "  json_quote \"${overlay_path}\"",
            "  printf ', \"force\": %s' " % ("true" if bundle.force else "false"),
            "  printf '}%s\\n'" % comma,
        ])

    commands.extend([
        "  printf '  ]\\n'",
        "  printf '}\\n'",
        "} > \"${out}\"",
    ])

    ctx.actions.run_shell(
        outputs = [out],
        inputs = depset(inputs),
        command = "\n".join(commands),
        mnemonic = "PublishManifest",
        progress_message = "Writing publish manifest %{label}",
    )

    return DefaultInfo(files = depset([out]))

publish_manifest = rule(
    implementation = _publish_manifest_impl,
    attrs = {
        "bundles": attr.label_list(
            mandatory = True,
            providers = [DeployBundleInfo],
            doc = "image_kustomization bundle targets to describe.",
        ),
        "push_prefix": attr.string(
            doc = "Default registry/repository prefix used when artifact_prefix is not set.",
        ),
        "artifact_prefix": attr.string(
            doc = "Default registry/repository prefix used for Flux artifacts. Defaults to push_prefix.",
        ),
        "tag": attr.string(
            doc = "Single Flux artifact tag for manifest references. Use either tag or tags.",
        ),
        "push_tags": attr.string_list(
            doc = "Flux artifact tags. Use either tag or push_tags. Defaults to [\"latest\"] when neither is set.",
        ),
        "compare_tag": attr.string(
            default = "latest",
            doc = "Tag emitted in manifests when skip_existing is enabled.",
        ),
        "skip_existing": attr.bool(
            default = False,
            doc = "Whether manifest references should use compare_tag.",
        ),
        "stamp": attr.bool(
            default = False,
            doc = "Whether to expand {KEY} placeholders in push_prefix, artifact_prefix, and tag from Bazel stable status.",
        ),
    },
    doc = "Generates a JSON manifest describing Flux deploy bundles for orchestration.",
)

def _target_name(label):
    label = str(label)
    if ":" in label:
        return label.rsplit(":", 1)[1]
    return label.rsplit("/", 1)[-1]

def publish_bundle_set(name, bundles, all_name = None, visibility = None, **kwargs):
    """Creates one push_bundle target per bundle plus an all target.

    For `name = "publish"` and bundle `:app_deploy`, this creates
    `:publish_app_deploy`. It also creates `:publish_all` unless `all_name` is
    supplied.
    """
    if "tag" in kwargs and "push_tags" in kwargs:
        fail("publish_bundle_set %s: specify only one of tag or push_tags" % name)
    for bundle in bundles:
        publish_manifest(
            name = name + "_" + _target_name(bundle) + "_manifest",
            bundles = [bundle],
            visibility = visibility,
            push_prefix = kwargs.get("push_prefix", ""),
            artifact_prefix = kwargs.get("artifact_prefix", ""),
            tag = kwargs.get("tag", ""),
            push_tags = kwargs.get("push_tags", []),
            compare_tag = kwargs.get("compare_tag", "latest"),
            skip_existing = kwargs.get("skip_existing", False),
            stamp = kwargs.get("stamp", False),
        )
        push_bundle(
            name = name + "_" + _target_name(bundle),
            bundles = [bundle],
            visibility = visibility,
            **kwargs
        )
    publish_manifest(
        name = name + "_manifest",
        bundles = bundles,
        visibility = visibility,
        push_prefix = kwargs.get("push_prefix", ""),
        artifact_prefix = kwargs.get("artifact_prefix", ""),
        tag = kwargs.get("tag", ""),
        push_tags = kwargs.get("push_tags", []),
        compare_tag = kwargs.get("compare_tag", "latest"),
        skip_existing = kwargs.get("skip_existing", False),
        stamp = kwargs.get("stamp", False),
    )
    push_bundle(
        name = all_name or (name + "_all"),
        bundles = bundles,
        visibility = visibility,
        **kwargs
    )
