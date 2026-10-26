#!/usr/bin/env python3
"""Static checker for the pg_sta SQL scripts.

It finds three classes of defect that PostgreSQL does *not* report at
CREATE time (they only blow up the first time the function is executed):

  1. UNBALANCED PARENS  - a stray ')' or a missing ')' inside a function
                           body.  Reported as a syntax error only when the
                           function is first called.
  2. ODD JSONB ARGS     - jsonb_build_object() with an odd number of
                           arguments.  PostgreSQL concatenates string
                           constants that are separated by a newline, which
                           silently turns two arguments into three.
  3. FORMAT ARITY       - format(fmt, args...) where the number of
                           arguments does not match the number of %s/%I/%L
                           placeholders in fmt ("too few arguments for
                           format()").

The checker models the PostgreSQL lexer closely enough for the pg_sta
scripts: comments are stripped, dollar-quoted bodies are opaque at the top
level (and analysed separately), and string constants separated by a
newline are merged the way the server merges them.

Usage:  python3 scripts/lint_sql.py sql/pg_sta--0.1.1.sql [more.sql ...]
Exit code 0 = clean, 1 = problems found.
"""
import re
import sys

WS = re.compile(r"[ \t\r\n]+")
TOKEN = re.compile(
    r"""(?P<dstr>\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$)
  | (?P<str>'(?:[^']|'')*')
  | (?P<num>\d+(?:\.\d+)?)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_$.]*)
  | (?P<op>[^\sA-Za-z0-9_'"]+)""",
    re.VERBOSE)

# %s, %I, %L, %1$s ... and the literal %% escape
PLACEHOLDER = re.compile(r"%(?:(%)|([1-9])?\$?([sIL]))")


def tokenize(sql):
    """Split SQL into tokens, dropping comments."""
    toks, i, n = [], 0, len(sql)
    while i < n:
        m = WS.match(sql, i)
        if m:
            i = m.end()
            continue
        if sql.startswith("--", i):
            j = sql.find("\n", i)
            i = n if j < 0 else j
            continue
        if sql.startswith("/*", i):
            j = sql.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        m = TOKEN.match(sql, i)
        if not m:
            i += 1
            continue
        kind = m.lastgroup
        if kind == "dstr":
            tag = m.group()
            end = sql.find(tag, m.end())
            if end < 0:
                end = n
            toks.append(("dstr", sql[m.start():end + len(tag)], m.start(),
                         end + len(tag)))
            i = end + len(tag)
            continue
        if kind == "op":
            for k, ch in enumerate(m.group()):
                toks.append(("op", ch, m.start() + k, m.start() + k + 1))
        else:
            toks.append((kind, m.group(), m.start(), m.end()))
        i = m.end()
    return toks


def merge_strings(sql, toks):
    """Merge adjacent string constants separated by a newline.

    PostgreSQL concatenates 'a ' and 'b' when a newline separates them
    ('a ' 'b' on one line is a syntax error).  The merged token keeps the
    full literal text so that format() placeholder counting is correct.
    """
    out, i = [], 0
    while i < len(toks):
        kind, val, s, e = toks[i]
        if kind == "str":
            parts = [val]
            j = i + 1
            while j < len(toks):
                k2, v2, s2, e2 = toks[j]
                if k2 != "str":
                    break
                gap = sql[e:s2]
                if gap.strip() == "" and "\n" in gap:
                    parts.append(v2)
                    e = e2
                    i = j
                    j += 1
                else:
                    break
            merged = "".join(p[1:-1].replace("''", "'") for p in parts)
            out.append(("str", merged, s, e))
        else:
            out.append((kind, val, s, e))
        i += 1
    return out


def call_args(toks, open_idx, close_idx):
    """Return the argument list of a call spanning toks[open_idx]='(' .. close_idx=')'.

    Each argument is returned as a list of (kind, value) token tuples so that
    string literals can be recognised (their merged value has no quotes).
    """
    depth, args, cur = 0, [], []
    for j in range(open_idx + 1, close_idx):
        kind, val, s, e = toks[j]
        if kind == "op":
            if val in "([":
                depth += 1
            elif val in ")]":
                depth -= 1
            elif val == "," and depth == 0:
                args.append(cur)
                cur = []
                continue
        cur.append((kind, val))
    if cur:
        args.append(cur)
    return args


def placeholder_info(literal):
    """Return (count, max_positional) for a format() template."""
    count, highest = 0, 0
    for m in PLACEHOLDER.finditer(literal):
        if m.group(1) == "%":
            continue
        count += 1
        if m.group(2):
            highest = max(highest, int(m.group(2)))
    return count, highest


def analyse(sql, toks, base_line=1):
    """Return a list of (kind, line, detail) problems."""
    problems, stack = [], []
    for idx, (kind, val, s, e) in enumerate(toks):
        if kind != "op":
            continue
        if val == "(":
            stack.append(idx)
            continue
        if val != ")":
            continue
        if not stack:
            problems.append(("UNBALANCED_CLOSE", base_line + sql[:s].count("\n"),
                             "unmatched ')'"))
            continue
        open_idx = stack.pop()
        name = toks[open_idx - 1][1] if open_idx else "?"
        args = call_args(toks, open_idx, idx)
        line = base_line + sql[:s].count("\n")
        if name == "jsonb_build_object" and len(args) % 2 != 0:
            problems.append(("ODD_JSONB_ARGS", line,
                             "jsonb_build_object() got %d argument(s)" % len(args)))
        if name == "format" and args:
            head = args[0]
            if len(head) == 1 and head[0][0] == "str":
                count, highest = placeholder_info(head[0][1])
                supplied = len(args) - 1
                need = highest if highest else count
                if highest:
                    ok = supplied >= need
                else:
                    ok = supplied == count
                if not ok:
                    problems.append((
                        "FORMAT_ARITY", line,
                        "format() template has %d placeholder(s) but %d argument(s) "
                        "were supplied" % (count, supplied)))
    for idx in stack:
        problems.append(("UNBALANCED_OPEN", base_line + sql[:idx].count("\n"),
                         "unclosed '('"))
    return problems


def check_source(sql, label, problems, base_line=1):
    toks = merge_strings(sql, tokenize(sql))
    for kind, line, detail in analyse(sql, toks, base_line):
        problems.append((label, kind, line, detail))


def check_file(path):
    src = open(path).read()
    problems = []
    # dollar-quoted bodies are opaque at the top level; analyse each on its own
    for m in re.finditer(r"\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$", src):
        tag = m.group()
        end = src.find(tag, m.end())
        if end < 0:
            continue
        body = src[m.end():end]
        base = 1 + src[:m.end()].count("\n")
        check_source(body, "body", problems, base)
    # and the top level with every dollar-quoted body blanked out
    top = re.sub(r"\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$.*?\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$",
                 "''", src, flags=re.S)
    check_source(top, "toplevel", problems, 1)
    return problems


def main(paths):
    total = 0
    for path in paths:
        problems = check_file(path)
        for label, kind, line, detail in sorted(set(problems),
                                                key=lambda p: (p[2], p[1])):
            print("%s:%d: %s [%s] %s" % (path, line, kind, label, detail))
            total += 1
    if total:
        print("--- %d problem(s) found" % total)
        return 1
    print("--- no problems found in %d file(s)" % len(paths))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["sql/pg_sta--0.1.1.sql"]))
