#!/usr/bin/env python3
"""Count lines in the project's .zig files, split into code / comment / test / blank.

Looks at .zig files in the repo root and recursively under src/. Generated
files (generated_*.zig, which are gitignored build artifacts) are excluded by
default; pass --include-generated to count them too.

A line falls into exactly one bucket:
  code     - not a full-line comment, and not inside a `test` block
  comment  - first non-whitespace token is `//` (trailing comments on code
             lines are NOT counted separately; the line counts as code)
  test     - inside a `test "..." { ... }` block (every line inside, including
             comments and blanks inside the block, counts as test)
  blank    - whitespace only, outside any test block

Braces inside string/char literals and after `//` are ignored when tracking
nesting, so strings containing `{`/`}` don't confuse the test-block scanner.
"""
import argparse
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def collect_files(include_generated: bool) -> list[str]:
    files: list[str] = []
    for name in sorted(os.listdir(ROOT)):
        if not name.endswith(".zig"):
            continue
        if not include_generated and name.startswith("generated_"):
            continue
        files.append(os.path.join(ROOT, name))
    src_dir = os.path.join(ROOT, "src")
    for dirpath, _dirnames, filenames in sorted(os.walk(src_dir)):
        for fn in sorted(filenames):
            if not fn.endswith(".zig"):
                continue
            if not include_generated and fn.startswith("generated_"):
                continue
            files.append(os.path.join(dirpath, fn))
    return sorted(files)


def is_full_line_comment(stripped: str) -> bool:
    return stripped.startswith("//")


def scan_line(line: str, pending_test: bool):
    """Walk one line, ignoring strings and `//` comments.

    Returns (events, new_pending, saw_test_keyword) where events is a list of
    ('open', is_test_block) / ('close',) tuples in source order, new_pending
    is whether a `test` keyword is still awaiting its `{`, and saw_test_keyword
    reports whether this line contains a `test` keyword.
    """
    events: list[tuple] = []
    new_pending = pending_test
    saw_test = False
    in_str: str | None = None
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if in_str is not None:
            if c == "\\":
                i += 2
                continue
            if c == in_str:
                in_str = None
            i += 1
            continue
        # `//` starts a comment to end of line; stop scanning.
        if c == "/" and i + 1 < n and line[i + 1] == "/":
            break
        if c == '"' or c == "'":
            in_str = c
            i += 1
            continue
        # Detect the `test` keyword (word-bounded on both sides).
        if (
            c == "t"
            and line[i : i + 4] == "test"
            and (i + 4 >= n or not (line[i + 4].isalnum() or line[i + 4] == "_"))
            and (i == 0 or not (line[i - 1].isalnum() or line[i - 1] == "_"))
        ):
            saw_test = True
            i += 4
            continue
        if c == "{":
            is_test_open = saw_test or pending_test
            events.append(("open", is_test_open))
            saw_test = False
            pending_test = False
        elif c == "}":
            events.append(("close",))
        i += 1
    new_pending = pending_test or saw_test
    return events, new_pending, saw_test


def count_file(path: str) -> dict[str, int]:
    counts = {"code": 0, "comment": 0, "test": 0, "blank": 0, "total": 0}
    depth_stack: list[bool] = []  # one bool per open brace: is it a test block?
    pending_test = False
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            counts["total"] += 1
            stripped = line.strip()
            currently_in_test = any(depth_stack)
            events, pending_test, saw_test = scan_line(line, pending_test)
            opened_test_this_line = any(
                ev[1] for ev in events if ev[0] == "open"
            )
            is_test_line = (
                currently_in_test or saw_test or opened_test_this_line
            )
            if is_test_line:
                counts["test"] += 1
            elif not stripped:
                counts["blank"] += 1
            elif is_full_line_comment(stripped):
                counts["comment"] += 1
            else:
                counts["code"] += 1
            for ev in events:
                if ev[0] == "open":
                    depth_stack.append(ev[1])
                else:
                    if depth_stack:
                        depth_stack.pop()
    return counts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--include-generated",
        action="store_true",
        help="also count generated_*.zig files (excluded by default)",
    )
    parser.add_argument(
        "--no-per-file",
        action="store_true",
        help="suppress the per-file table; print totals only",
    )
    args = parser.parse_args()

    files = collect_files(args.include_generated)
    if not files:
        print("no .zig files found", file=sys.stderr)
        return 1

    totals = {"code": 0, "comment": 0, "test": 0, "blank": 0, "total": 0}
    rows = []
    for path in files:
        counts = count_file(path)
        rel = os.path.relpath(path, ROOT)
        rows.append((rel, counts))
        for key in totals:
            totals[key] += counts[key]

    if not args.no_per_file:
        header = f"{'file':<42} {'code':>6} {'comment':>8} {'test':>6} {'blank':>6} {'total':>7}"
        print(header)
        print("-" * len(header))
        for rel, counts in rows:
            print(
                f"{rel:<42} {counts['code']:>6} {counts['comment']:>8} "
                f"{counts['test']:>6} {counts['blank']:>6} {counts['total']:>7}"
            )
        print("-" * len(header))

    print(
        f"{'TOTAL':<42} {totals['code']:>6} {totals['comment']:>8} "
        f"{totals['test']:>6} {totals['blank']:>6} {totals['total']:>7}"
    )
    code_plus_comment = totals["code"] + totals["comment"]
    print(
        f"\n{totals['total']} total lines across {len(files)} files "
        f"({code_plus_comment} code+comment, {totals['test']} test, "
        f"{totals['blank']} blank)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
