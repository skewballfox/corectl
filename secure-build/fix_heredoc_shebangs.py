"""Rewrite shebang heredoc RUN steps so they build with `buildah --isolation chroot`.

buildah runs a heredoc whose body starts with a shebang (`RUN <<EOF` + `#!/bin/bash`)
from a file under /dev/pipes, which chroot isolation doesn't provide:
`/bin/bash: /dev/pipes/buildahheredoc...: No such file or directory` (exit 127).

Feeding the body to the interpreter on stdin is equivalent:
`RUN <<EOF` + `#!/bin/bash` becomes `RUN /bin/bash <<'EOF'`. The quoted delimiter
leaves variable expansion to that shell at run time, as with the shebang form
(unquoted, buildah would expand the body itself at parse time).

Usage: fix_heredoc_shebangs.py <Dockerfile>   (edited in place)
"""

import re
import sys
from pathlib import Path

# RUN plus optional flags (--mount=..., --network=...) and nothing else, then one heredoc.
# With a command in front (`RUN python3 <<EOF`) the body is that command's stdin and a
# leading `#!` is just text, so those are left alone.
HEREDOC_RUN = re.compile(
    r"^(?P<run>RUN(?:\s+--\S+)*)\s+<<(?P<dash>-?)(?P<quote>[\"']?)(?P<delim>\w+)(?P=quote)\s*$"
)


def rewrite(lines: list[str]) -> tuple[list[str], int]:
    out: list[str] = []
    changed = 0
    i = 0
    while i < len(lines):
        match (HEREDOC_RUN.match(lines[i].rstrip("\n")), lines[i + 1] if i + 1 < len(lines) else ""):
            case (m, body) if m and body.startswith("#!"):
                interpreter = body[2:].strip()
                out.append(f"{m['run']} {interpreter} <<{m['dash']}'{m['delim']}'\n")
                changed += 1
                i += 2
            case _:
                out.append(lines[i])
                i += 1
    return out, changed


def main() -> None:
    dockerfile = Path(sys.argv[1])
    lines, changed = rewrite(dockerfile.read_text().splitlines(keepends=True))
    if changed:
        dockerfile.write_text("".join(lines))
        print(f"Rewrote {changed} shebang heredoc(s) in {dockerfile.name} for chroot isolation")


if __name__ == "__main__":
    main()
