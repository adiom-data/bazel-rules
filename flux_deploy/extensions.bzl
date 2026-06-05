"""Module extensions for rules_flux_deploy tool dependencies."""

KUSTOMIZE_VERSION = "5.8.1"
FLUX_VERSION = "2.8.6"

KUSTOMIZE_SHA256 = {
    ("darwin", "amd64"): "ee7cf0c1e3592aa7bb66ba82b359933a95e7f2e0b36e5f53ed0a4535b017f2f8",
    ("darwin", "arm64"): "8886f8a78474e608cc81234f729fda188a9767da23e28925802f00ece2bab288",
    ("linux", "amd64"): "029a7f0f4e1932c52a0476cf02a0fd855c0bb85694b82c338fc648dcb53a819d",
    ("linux", "arm64"): "0953ea3e476f66d6ddfcd911d750f5167b9365aa9491b2326398e289fef2c142",
}

FLUX_SHA256 = {
    ("darwin", "amd64"): "83ce032f39248ed04324f3e50344794575fb5f7149f24c071972e320b64826a6",
    ("darwin", "arm64"): "20de67ebf2da689dd165b004dc073469f33aa2a3eac45a69f38a40435e14d20b",
    ("linux", "amd64"): "c53cc990ae266f7840f64c81515d701d8821d558a9062aa4211d71b38cf044be",
    ("linux", "arm64"): "bc460320c2d33ad833791277896dd1aaf1cff6b3e64ba397c44238f00d4ae5bc",
}

def _platform(rctx):
    os_name = rctx.os.name.lower()
    if os_name.startswith("mac os") or os_name.startswith("darwin"):
        os_name = "darwin"
    elif os_name.startswith("linux"):
        os_name = "linux"
    else:
        fail("unsupported host OS for rules_flux_deploy tools: %s" % rctx.os.name)

    arch = rctx.os.arch.lower()
    if arch in ["x86_64", "amd64"]:
        arch = "amd64"
    elif arch in ["aarch64", "arm64"]:
        arch = "arm64"
    else:
        fail("unsupported host architecture for rules_flux_deploy tools: %s" % rctx.os.arch)

    return os_name, arch

def _tools_repo_impl(rctx):
    os_name, arch = _platform(rctx)
    platform = (os_name, arch)
    if platform not in KUSTOMIZE_SHA256 or platform not in FLUX_SHA256:
        fail("unsupported platform for rules_flux_deploy tools: %s_%s" % platform)

    kustomize_archive = "kustomize_v%s_%s_%s.tar.gz" % (KUSTOMIZE_VERSION, os_name, arch)
    flux_archive = "flux_%s_%s_%s.tar.gz" % (FLUX_VERSION, os_name, arch)

    rctx.download_and_extract(
        url = "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v%s/%s" % (KUSTOMIZE_VERSION, kustomize_archive),
        sha256 = KUSTOMIZE_SHA256[platform],
    )
    rctx.download_and_extract(
        url = "https://github.com/fluxcd/flux2/releases/download/v%s/%s" % (FLUX_VERSION, flux_archive),
        sha256 = FLUX_SHA256[platform],
    )

    rctx.rename("kustomize", "kustomize_bin")
    rctx.rename("flux", "flux_bin")
    rctx.file("BUILD.bazel", """
genrule(
    name = "flux",
    srcs = ["flux_bin"],
    outs = ["flux_tool"],
    cmd = "cp $< $@ && chmod +x $@",
    executable = True,
    visibility = ["//visibility:public"],
)

genrule(
    name = "kustomize",
    srcs = ["kustomize_bin"],
    outs = ["kustomize_tool"],
    cmd = "cp $< $@ && chmod +x $@",
    executable = True,
    visibility = ["//visibility:public"],
)
""")

_tools_repo = repository_rule(
    implementation = _tools_repo_impl,
)

def _flux_deploy_dependencies_impl(_ctx):
    _tools_repo(name = "rules_flux_deploy_tools")

flux_deploy_dependencies = module_extension(
    implementation = _flux_deploy_dependencies_impl,
)
