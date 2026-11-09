#!/usr/bin/env python3
"""One-shot zig-0.17 migration sweep: `**` array-fill -> @splat.

Zig 0.17 removed the array-multiplication operator (`[1]u8{0} ** 8`).
The release-notes migration is `@splat`, but @splat's result type comes
from the result location, so this sweep rewrites:

  [_]T{x} ** N   ->  @as([N]T, @splat(x))     (explicit type + count survive)
  .{x} ** N      ->  @splat(x)                (relies on result location:
                                               field init / typed const / fn
                                               arg - the compiler flags any
                                               site without one)

NOT rewritten (reported for manual fixes):
  - multi-element repeats (`.{1, 2} ** 8` - block repetition, not a fill;
    @splat cannot express it)
  - string repeats (`"x" ** 200`)

Usage:
  migration_splat_sweep.py --dry-run [FILE]   print planned rewrites
  migration_splat_sweep.py --apply [FILE]     rewrite in place
                                              (no FILE = every .zig under
                                              src/, tools/, build.zig)
"""

import re
import sys
import pathlib

TYPE_RE = r"[A-Za-z0-9_.?\[\] ]+"
TYPED_PREFIX_RE = re.compile(r"\[_\](" + TYPE_RE + r")\{")
ANON_PREFIX_RE = re.compile(r"\.\{")


def scan_count(s: str) -> int:
    """End index of a count expression at the start of `s`.

    Consumes identifiers (incl. @"quoted" and @builtin forms), member
    dots, and BALANCED call-paren / index-bracket groups - so a trailing
    `))` after `** 6` is left alone, while
    `@typeInfo(T).@"enum".fields.len` is consumed whole. A leading `(`
    (parenthesized count like `(N * 2)`) is consumed as one balanced
    group, which stays valid inside the generated `[...]` length.
    """
    i = 0
    n = len(s)
    consumed = False
    while i < n:
        ch = s[i]
        if ch == "@":
            i += 1
            if i < n and s[i] == '"':
                j = s.find('"', i + 1)
                if j == -1:
                    break
                i = j + 1
                consumed = True
            else:
                start = i
                while i < n and (s[i].isalnum() or s[i] == "_"):
                    i += 1
                if i == start:
                    break
                consumed = True
        elif ch.isalnum() or ch == "_":
            while i < n and (s[i].isalnum() or s[i] == "_"):
                i += 1
            consumed = True
        elif ch == ".":
            i += 1
        elif ch == "(" or ch == "[":
            open_ch, close_ch = ("(", ")") if ch == "(" else ("[", "]")
            depth = 0
            j = i
            while j < n:
                if s[j] == open_ch:
                    depth += 1
                elif s[j] == close_ch:
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            if depth != 0:
                break
            i = j + 1
            consumed = True
        else:
            break
    return i if consumed else 0


def match_mult(line: str, after_idx: int) -> tuple[str, int] | None:
    """Match ` ** <count>` starting at after_idx; (count, end_index) or None."""
    m = re.match(r" \*\* ", line[after_idx:])
    if not m:
        return None
    rest = line[after_idx + m.end() :]
    end = scan_count(rest)
    if end == 0:
        return None
    return rest[:end], after_idx + m.end() + end


def find_matching_brace(line: str, open_idx: int) -> int | None:
    """Index of the brace matching line[open_idx] == '{', or None."""
    depth = 0
    for i in range(open_idx, len(line)):
        if line[i] == "{":
            depth += 1
        elif line[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return None


def split_top_level_commas(content: str) -> int:
    """Number of top-level comma-separated elements inside the braces."""
    depth = 0
    count = 1
    for ch in content:
        if ch == "{" or ch == "[" or ch == "(":
            depth += 1
        elif ch == "}" or ch == "]" or ch == ")":
            depth -= 1
        elif ch == "," and depth == 0:
            count += 1
    return count


def rewrite_line(line: str, reports: list[str], path: str, lineno: int) -> str:
    # Process right-to-left so earlier replacement offsets stay valid.
    changed = True
    while changed:
        changed = False
        for m in reversed(list(TYPED_PREFIX_RE.finditer(line))):
            open_idx = m.end() - 1
            close_idx = find_matching_brace(line, open_idx)
            if close_idx is None:
                continue
            after = line[close_idx + 1 :]
            mult = match_mult(line, close_idx + 1)
            if not mult:
                continue
            content = line[open_idx + 1 : close_idx]
            if split_top_level_commas(content) != 1:
                reports.append(f"{path}:{lineno}: MULTI-ELEMENT (manual): {line.strip()}")
                continue
            elem_type = m.group(1)
            count, mult_end = mult
            replacement = f"@as([{count}]{elem_type}, @splat({content}))"
            line = line[: m.start()] + replacement + line[mult_end:]
            changed = True
            break
        if changed:
            continue
        for m in reversed(list(ANON_PREFIX_RE.finditer(line))):
            open_idx = m.end() - 1
            close_idx = find_matching_brace(line, open_idx)
            if close_idx is None:
                continue
            after = line[close_idx + 1 :]
            mult = match_mult(line, close_idx + 1)
            if not mult:
                continue
            content = line[open_idx + 1 : close_idx]
            if split_top_level_commas(content) != 1:
                reports.append(f"{path}:{lineno}: MULTI-ELEMENT (manual): {line.strip()}")
                continue
            # Only treat `.{x} ** N` as an array fill when the line looks like
            # code, not prose (markdown bold like `**text**` never has the
            # `.{ ... } **` prefix, but the guard keeps the sweep honest).
            _, mult_end = mult
            replacement = f"@splat({content})"
            line = line[: m.start()] + replacement + line[mult_end:]
            changed = True
            break
    return line


def is_skippable(line: str) -> bool:
    stripped = line.lstrip()
    return stripped.startswith("//") or stripped.startswith("\\\\")


def process_file(path: pathlib.Path, apply: bool, reports: list[str]) -> bool:
    text = path.read_text()
    lines = text.splitlines(keepends=True)
    touched = False
    for i, raw in enumerate(lines):
        if is_skippable(raw) or "**" not in raw:
            continue
        newline = "\n" if raw.endswith("\n") else ""
        body = raw[:-1] if newline else raw
        rewritten = rewrite_line(body, reports, str(path), i + 1)
        if rewritten != body:
            touched = True
            lines[i] = rewritten + newline
            if not apply:
                print(f"--- {path}:{i + 1}")
                print(f"  old: {body.strip()}")
                print(f"  new: {rewritten.strip()}")
    if apply and touched:
        path.write_text("".join(lines))
    return touched


def main() -> None:
    args = sys.argv[1:]
    if not args or args[0] not in ("--dry-run", "--apply"):
        sys.exit(__doc__)
    apply = args[0] == "--apply"
    if len(args) > 1:
        files = [pathlib.Path(args[1])]
    else:
        files = [pathlib.Path("build.zig")]
        files += sorted(pathlib.Path("src").rglob("*.zig"))
        files += sorted(pathlib.Path("tools").rglob("*.zig"))
    reports: list[str] = []
    touched = 0
    for f in files:
        if not f.exists():
            continue
        if process_file(f, apply, reports):
            touched += 1
    for report in reports:
        print(report)
    verb = "rewrote" if apply else "would rewrite"
    print(f"{verb} {touched} file(s); {len(reports)} manual site(s) reported")


if __name__ == "__main__":
    main()
