#!/usr/bin/env bash
#
# Copy only web-publishable files from a source folder into the webroot.
#
#   publish-safe-copy.sh SRC DEST [--dry-run]
#
# Use this instead of `mv` when the source is an old server folder. Moving one
# wholesale publishes everything in it, and these folders are rarely just a
# website: /var/www/dorkbotmde, for example, is a home directory containing
# .ssh2/, .bash_history, a personal mbox and 127 .php files. A file being
# unlisted in the index is not protection — anything inside the webroot is
# reachable by URL whether or not something links to it.
#
# So this copies an allowlist of extensions and nothing else. Anything not
# named in PUBLISHABLE stays behind, including every file type nobody thought
# about.

set -euo pipefail

SRC="${1:-}"
DEST="${2:-}"
DRY="${3:-}"

if [ -z "$SRC" ] || [ -z "$DEST" ]; then
  echo "usage: publish-safe-copy.sh SRC DEST [--dry-run]" >&2
  exit 1
fi
[ -d "$SRC" ] || { echo "error: no such directory: $SRC" >&2; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "error: rsync is not installed. Run: apt install rsync" >&2; exit 1; }

# Extensions that are safe to serve as static files from a vhost with no
# application handler. Deliberately excludes .php, .dump, .sql, .xml and .tex:
# without a PHP handler a .php is downloaded as source, and the rest are data
# or build files rather than published pages.
PUBLISHABLE="html htm css js gif png jpg jpeg JPG JPEG svg ico webp pdf txt md mov mp4 webm m4a flac wav ogv zip woff woff2 ttf eot otf swf"

# Names excluded regardless of extension: shell and mail state, editor and OS
# cruft. The leading-dot rule already covers most, but these are spelled out
# because the cost of missing one is publishing someone's mail.
args=(-a --prune-empty-dirs)
for x in ".*" "__MACOSX" "mail" "mbox" "dead.letter" "Desktop" ".ssh" ".ssh2" "*.php" "*.dump" "*.sql" "*.sqlite*" "*.db" "*.bak" "*.log" "*.conf" "*.ini" "*.env" "*.key" "*.pem" "*.yaml" "*.yml"; do
  args+=(--exclude="$x")
done

# Descend into every directory, keep only the allowlisted extensions, drop the
# rest. --prune-empty-dirs then removes folders that kept nothing.
args+=(--include="*/")
for e in $PUBLISHABLE; do args+=(--include="*.$e"); done
args+=(--exclude="*")

if [ "$DRY" = "--dry-run" ]; then
  args+=(--dry-run --itemize-changes)
  echo "DRY RUN — nothing is copied"
fi

mkdir -p "$DEST"
rsync "${args[@]}" "$SRC/" "$DEST/"

if [ "$DRY" != "--dry-run" ]; then
  echo
  echo "copied into $DEST:"
  find "$DEST" -type f | wc -l | sed 's/^/  files: /'
  du -sh "$DEST" 2>/dev/null | cut -f1 | sed 's/^/  size:  /'
  echo
  echo "left behind in $SRC (not published):"
  # Report what was deliberately skipped, so the decision is visible.
  find "$SRC" -type f \( -name ".*" -o -name "mbox" -o -name "dead.letter" -o -name "*.php" -o -name "*.dump" -o -name "*.sql" \) 2>/dev/null | wc -l | sed 's/^/  sensitive-or-app files: /'
fi
