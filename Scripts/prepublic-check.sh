#!/usr/bin/env bash
# Checks to run before the repository is made public (T6.3 prerequisite): it changes nothing, and
# never changes the repository's visibility. Every check runs and the summary is always printed.
#   1. gitleaks over the whole history (every ref) and over the files git would publish. Known false
#      positives: generated test vectors (.gitleaksignore) and the public Sparkle key
#      (`# gitleaks:allow` in project.yml).
#   2. The 10 largest blobs ever committed.
#   3. No real RFB capture, key, certificate, profile, archive or private tracking doc ever committed.
#   4. Personal or local details anywhere in history (private IPv4 ranges, minim6, @lauriat, /Users/,
#      .ts.net): warnings, with the accepted ones marked.
# Usage: ./Scripts/prepublic-check.sh     (exit 1 if check 1 or 3 fails)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
RESULTS=()
FAILED=0
record() {   # record <ok|fail|warn> <message>
  RESULTS+=("$1  $2")
  [ "$1" != "fail" ] || FAILED=1
}

TREE="$(mktemp -d)"
trap 'rm -rf "$TREE"' EXIT

echo "▶︎ 1. gitleaks"
if command -v gitleaks >/dev/null; then
  if gitleaks git . --log-opts="--all" --redact --no-banner; then
    record ok "gitleaks history (all refs): no leaks"
  else
    record fail "gitleaks history (all refs): leaks found (see above)"
  fi
  # A copy of the files git would publish or could add (tracked files that still exist, untracked
  # ones not ignored), so build/, .dmgbuild-venv/ and other ignored local state are not scanned.
  if git ls-files -z --cached --others --exclude-standard | python3 -I -c '
import os, shutil, sys
dest, copied, missing = sys.argv[1], 0, 0
for path in sys.stdin.buffer.read().split(b"\0"):
    if not path:
        continue
    path = path.decode()
    if not os.path.isfile(path):          # tracked but deleted in the working tree, or a symlink to a dir
        missing += 1
        continue
    os.makedirs(os.path.join(dest, os.path.dirname(path)), exist_ok=True)
    shutil.copy2(path, os.path.join(dest, path))
    copied += 1
print("  copied %d files, skipped %d missing" % (copied, missing))' "$TREE"; then
    if (cd "$TREE" && gitleaks dir . --redact --no-banner --gitleaks-ignore-path "$ROOT/.gitleaksignore"); then
      record ok "gitleaks working tree: no leaks"
    else
      record fail "gitleaks working tree: leaks found (see above)"
    fi
  else
    record fail "gitleaks working tree: could not copy the tree"
  fi
else
  record fail "gitleaks not installed (brew install gitleaks)"
fi

echo "▶︎ 2. largest blobs in history"
if git rev-list --objects --all \
  | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' \
  | python3 -I -c '
import sys
blobs = []
for line in sys.stdin:
    kind, _, size, *rest = line.rstrip("\n").split(" ", 3)
    if kind == "blob":
        blobs.append((int(size), rest[0] if rest else ""))
blobs.sort(reverse=True)
print("  %d blobs, %.2f MB" % (len(blobs), sum(s for s, _ in blobs) / 1e6))
for size, path in blobs[:10]:
    print("  %9d  %s" % (size, path))'; then
  record ok "largest blobs listed"
else
  record fail "could not list blobs"
fi

echo "▶︎ 3. files that must never have been committed"
FORBIDDEN="$(git log --all --name-only --pretty=format: | sort -u | python3 -I -c '
import re, sys
patterns = [r"Captures/new/", r"Captures/.*-server\.bin$", r"Captures/.*-summary\.json$", r"Captures/.*\.png$",
            r"\.(p12|pem|key|cer|provisionprofile|mobileprovision|xcarchive|dmg)$", r"(^|/)\.env",
            r"^(COMMANDS|MEMORY|TODOS|PLAN|CHANGES)\.md$", r"^\.(omc|claude)/"]
hits = [p for p in (l.strip() for l in sys.stdin) if p and any(re.search(x, p) for x in patterns)]
print("\n".join(hits))')"
if [ -n "$FORBIDDEN" ]; then
  echo "$FORBIDDEN" | sed "s/^/  ✗ /"
  record fail "forbidden files in history: $(echo "$FORBIDDEN" | wc -l | tr -d ' ')"
else
  echo "  none"
  record ok "no forbidden file in history"
fi

echo "▶︎ 4. personal or local details in history"
# No \b: git grep's ERE does not support it (the IP alternatives would never match); Python
# re-checks each line with word boundaries.
PATTERN='(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3})|minim6|@lauriat|/Users/|\.ts\.net'
WARNINGS="$(git rev-list --all | xargs git grep -I -n -E "$PATTERN" 2>/dev/null \
  | HEAD_SHA="$(git rev-parse HEAD)" PATTERN="$PATTERN" python3 -I -c '
import collections, os, re, subprocess, sys
pattern = re.compile(r"(?<![0-9.])(?:" + os.environ["PATTERN"] + r")(?![0-9])")
head = os.environ["HEAD_SHA"]
# Accepted: RFC 1918 / CGNAT range literals in the address classifier, its tests and the TRD; example
# addresses in tests, the -LibraryDemo sample library and the editor placeholder; Bonjour and
# discovery fixtures; "minim6" used as a server name inside test byte streams.
accepted_paths = re.compile(r"^(Packages/[^/]+/(Sources/RFBKit/Transport|Tests)/.*\.swift|RemoteDeckTests/.*\.swift"
                            r"|RemoteDeck/Discovery/.*\.swift|RemoteDeck/Library/LibraryDemo\.swift|RemoteDeck/Localization/Strings\.swift)$")
accepted_pairs = {("TRD.md", "100.64.0.0")}
class Accepted:
    @staticmethod
    def match(path, value):
        return bool(accepted_paths.match(path)) or (path, value) in accepted_pairs
accepted = Accepted()
hits = collections.defaultdict(lambda: [set(), set()])   # (path, match) -> [commits, lines]
for line in sys.stdin:
    try:
        sha, path, _, text = line.rstrip("\n").split(":", 3)
    except ValueError:
        continue
    for m in pattern.finditer(text):
        entry = hits[(path, m.group(0))]
        entry[0].add(sha)
        entry[1].add(text.strip()[:100])
at_head = set(subprocess.run(["git", "grep", "-I", "-l", "-E", os.environ["PATTERN"], head],
                             capture_output=True, text=True).stdout.replace(head + ":", "").split())
for (path, match), (commits, lines) in sorted(hits.items()):
    tag = "accepted" if accepted.match(path, match) else "REVIEW  "
    where = "at HEAD" if path in at_head else "history only"
    print("%s  %-22s %-60s %3d commits, %s" % (tag, match, path, len(commits), where))')"
if [ -n "$WARNINGS" ]; then
  echo "$WARNINGS" | sed "s/^/  /"
  REVIEW="$(echo "$WARNINGS" | grep -c '^REVIEW' || true)"
  record warn "personal/local details: $REVIEW to review, $(echo "$WARNINGS" | grep -c '^accepted' || true) accepted"
else
  echo "  none"
  record ok "no personal or local detail in history"
fi

echo
echo "Summary"
for R in "${RESULTS[@]}"; do echo "  $R"; done
if [ "$FAILED" = 0 ]; then
  echo "✅ pre-public checks passed (review the warnings before changing visibility)"
else
  echo "✗ pre-public checks failed" >&2
  exit 1
fi
