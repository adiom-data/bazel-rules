def _quote(s):
    return "'" + str(s).replace("'", "'\"'\"'") + "'"

def _fake_push_with_runfile_impl(ctx):
    script = ctx.actions.declare_file(ctx.attr.name + ".sh")
    commands = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "data_path=%s" % _quote(ctx.file.data.short_path),
        "found=",
        "for root in \"${RUNFILES_DIR:-}\" \"$0.runfiles\"; do",
        "  [[ -n \"${root}\" ]] || continue",
        "  if [[ -f \"${root}/_main/${data_path}\" ]]; then",
        "    found=\"${root}/_main/${data_path}\"",
        "    break",
        "  fi",
        "done",
        "if [[ -z \"${found}\" ]]; then",
        "  echo \"missing nested push runfile: ${data_path}\" >&2",
        "  exit 1",
        "fi",
        "echo \"fake image push $* $(cat \"${found}\")\"",
    ]
    ctx.actions.write(script, "\n".join(commands), is_executable = True)
    return DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [ctx.file.data]),
    )

fake_push_with_runfile = rule(
    implementation = _fake_push_with_runfile_impl,
    executable = True,
    attrs = {
        "data": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
    },
)
