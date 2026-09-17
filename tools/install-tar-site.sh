#!/usr/bin/env bash
#
# Publish an uploaded tarball of an old website as a folder of the webroot.
#
#   install-tar-site.sh TAR NAME [--dry-run]
#
#   install-tar-site.sh /allgpslogstil2005website.tar gpslogs
#     -> https://altred.xyz/gpslogs/
#
# Nothing in nginx needs to change for a static site: NAME becomes a plain
# directory under /var/www/altred.xyz and the default location serves it. Add
# a nav entry in generate-index.sh so the landing page links to it.
#
# The tar is NOT extracted into the webroot. Old site archives are like the old
# server folders — a website plus whatever else was lying next to it (shell
# history, mail, .php sources, dumps). Everything is unpacked into a staging
# directory outside the webroot first, and publish-safe-copy.sh then copies
# only the allowlisted file types across. The staging copy is left in place so
# what was skipped can be inspected.
#
# Fetch, like the other scripts:
#   curl -fsSL https://raw.githubusercontent.com/alejoduque/radiolibre_template/main/tools/install-tar-site.sh -o /usr/local/bin/install-tar-site.sh
#   curl -fsSL https://raw.githubusercontent.com/alejoduque/radiolibre_template/main/tools/publish-safe-copy.sh -o /usr/local/bin/publish-safe-copy.sh
#   chmod +x /usr/local/bin/install-tar-site.sh /usr/local/bin/publish-safe-copy.sh

set -euo pipefail

TAR="${1:-}"
NAME="${2:-}"
DRY="${3:-}"

WEBROOT="${WEBROOT:-/var/www/altred.xyz}"
STAGING="${STAGING:-/var/www/staging}"

if [ -z "$TAR" ] || [ -z "$NAME" ]; then
  echo "usage: install-tar-site.sh TAR NAME [--dry-run]" >&2
  exit 1
fi
[ -f "$TAR" ] || { echo "error: no such file: $TAR" >&2; exit 1; }
[ -d "$WEBROOT" ] || { echo "error: WEBROOT does not exist: $WEBROOT" >&2; exit 1; }

# NAME is one path segment: it becomes the URL and the folder. Anything with a
# slash or a leading dot would land somewhere other than $WEBROOT/NAME.
case "$NAME" in
  ""|.*|*/*) echo "error: NAME must be a plain folder name, got: $NAME" >&2; exit 1 ;;
esac

# The copier lives beside this script in the repo and in /usr/local/bin once
# fetched; look in both places.
here="$(cd "$(dirname "$0")" && pwd)"
COPY="$here/publish-safe-copy.sh"
[ -x "$COPY" ] || COPY="$(command -v publish-safe-copy.sh || true)"
[ -n "$COPY" ] && [ -x "$COPY" ] || { echo "error: publish-safe-copy.sh not found next to this script or on PATH" >&2; exit 1; }

# Refuse a tar that would write outside its own directory. Absolute members
# and ".." components are the two ways a tarball escapes the extraction dir.
if tar -tf "$TAR" | grep -Eq '^/|(^|/)\.\.(/|$)'; then
  echo "error: $TAR contains absolute or ../ paths; not extracting" >&2
  exit 1
fi

DEST="$WEBROOT/$NAME"
stage="$STAGING/$NAME"

if [ -e "$DEST" ]; then
  echo "error: $DEST already exists. Remove it first if this is a re-install." >&2
  exit 1
fi

echo "unpacking $TAR -> $stage"
mkdir -p "$stage"
tar -xf "$TAR" -C "$stage"

# A tar made with `tar cf site.tar site/` wraps everything in one folder.
# Serve from inside that folder, so the URL is /NAME/ and not /NAME/site/.
src="$stage"
entries=("$stage"/*)
if [ ${#entries[@]} -eq 1 ] && [ -d "${entries[0]}" ]; then
  src="${entries[0]}"
  echo "single top-level folder, serving from: $src"
fi

# Say what the site is before copying, so a PHP site is not silently published
# as downloadable source (this vhost only runs PHP under /mdelibre/).
php_count="$(find "$src" -type f -name '*.php' | wc -l | tr -d ' ')"
if [ "$php_count" != "0" ]; then
  echo "note: $php_count .php files in the archive. They will NOT be copied —"
  echo "      only /mdelibre/ has a PHP handler. If the site needs them, it"
  echo "      belongs under /mdelibre/ instead."
fi
if [ ! -e "$src/index.html" ] && [ ! -e "$src/index.htm" ]; then
  echo "warning: no index.html at the top of the site; /$NAME/ will 404 until one exists."
  echo "         top level of the archive:"
  ls -1 "$src" | head -20 | sed 's/^/           /'
fi

if [ "$DRY" = "--dry-run" ]; then
  "$COPY" "$src" "$DEST" --dry-run
  rmdir "$DEST" 2>/dev/null || true
  exit 0
fi

"$COPY" "$src" "$DEST"
chown -R www-data:www-data "$DEST" 2>/dev/null || true
find "$DEST" -type d -exec chmod 755 {} + -o -type f -exec chmod 644 {} +

echo
echo "published: https://altred.xyz/$NAME/"
echo "staging copy kept at $stage — delete it once the site is checked."
