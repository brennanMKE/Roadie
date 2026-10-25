"""test_skins.py -- read scripts/test-skins.tsv and check a cache of test skins (#0198). Stdlib only; run with -I.

  python3 -I scripts/test_skins.py parse MANIFEST          -> name<TAB>museum_id<TAB>md5 per row
  python3 -I scripts/test_skins.py check MANIFEST CACHE    -> ok|missing|bad-md5<TAB>name per row; exit 1 unless all ok
"""
import hashlib
import os
import re
import sys

MD5_RE = re.compile(r"^[0-9a-f]{32}$")


def parse_manifest(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) < 3:
                raise ValueError(f"{path}:{lineno}: expected name, museum_id, md5, why")
            name, museum_id, md5 = cols[0], cols[1], cols[2]
            if not MD5_RE.match(md5):
                raise ValueError(f"{path}:{lineno}: bad md5 {md5!r}")
            if not name or "/" in name:
                raise ValueError(f"{path}:{lineno}: bad name {name!r}")
            rows.append({"name": name, "museum_id": museum_id, "md5": md5,
                         "why": cols[3] if len(cols) > 3 else ""})
    return rows


def file_md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def check(rows, cache):
    results = []
    for row in rows:
        path = os.path.join(cache, row["name"] + ".wsz")
        if not os.path.isfile(path):
            status = "missing"
        elif file_md5(path) != row["md5"]:
            status = "bad-md5"
        else:
            status = "ok"
        results.append((status, row["name"]))
    return results


def main(argv):
    if len(argv) == 3 and argv[1] == "parse":
        for row in parse_manifest(argv[2]):
            print(f"{row['name']}\t{row['museum_id']}\t{row['md5']}")
        return 0
    if len(argv) == 4 and argv[1] == "check":
        results = check(parse_manifest(argv[2]), argv[3])
        for status, name in results:
            print(f"{status}\t{name}")
        return 0 if all(s == "ok" for s, _ in results) else 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
