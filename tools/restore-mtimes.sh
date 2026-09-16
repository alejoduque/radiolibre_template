#!/usr/bin/env bash
#
# Put back the modification times that the rewrite tools destroyed.
#
#   restore-mtimes.sh --dry-run    report what would change, touch nothing
#   restore-mtimes.sh              restore the oldest known mtime per file
#
# rewrite-old-domains.sh and fix-link-case.py edit files in place, and any
# in-place edit resets mtime to now. That turned twenty-year-old pages into
# files dated 2026 — and since the index shows that date, the archive started
# claiming its own contents were made yesterday.
#
# Those tools take a tar backup before writing, and tar preserves mtimes, so
# the real dates survive inside /root/*.tar.gz. This walks every backup, and
# for each file applies the OLDEST timestamp found across all of them. Oldest
# rather than newest because each successive backup captures the damage done
# by the run before it.
#
# Only timestamps are touched. File CONTENT is never restored — the rewrites
# themselves are wanted, it is only their side effect on mtime that is not.

set -euo pipefail

BACKUP_GLOB="${BACKUP_GLOB:-/root/*.tar.gz}"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

shopt -s nullglob
backups=( $BACKUP_GLOB )
shopt -u nullglob
[ "${#backups[@]}" -gt 0 ] || { echo "error: no backups matching $BACKUP_GLOB" >&2; exit 1; }

echo "backups found: ${#backups[@]}"
for b in "${backups[@]}"; do echo "  $b"; done
echo

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Extract every backup into one tree. Later extractions overwrite earlier ones,
# so afterwards each path carries whichever copy tar wrote last; the oldest is
# picked per-file below instead of relying on that order.
i=0
for b in "${backups[@]}"; do
  i=$((i + 1))
  d="$tmp/b$i"
  mkdir -p "$d"
  # -m would use the current time; we specifically want the stored mtimes.
  tar xzf "$b" -C "$d" 2>/dev/null || {
    echo "  skip (not readable as tar): $b" >&2
    continue
  }
done

restored=0
skipped=0
missing=0

while IFS= read -r -d '' src; do
  # b<N>/var/www/... -> /var/www/...
  rel="${src#$tmp/}"
  rel="${rel#*/}"
  target="/$rel"

  [ -f "$target" ] || { missing=$((missing + 1)); continue; }

  src_epoch="$(stat -c %Y "$src" 2>/dev/null || stat -f %m "$src")"
  tgt_epoch="$(stat -c %Y "$target" 2>/dev/null || stat -f %m "$target")"

  # Only ever move a timestamp backwards.
  if [ "$src_epoch" -lt "$tgt_epoch" ]; then
    if [ "$DRY" -eq 1 ]; then
      printf '  %s\n     %s -> %s\n' "$target" \
        "$(date -d "@$tgt_epoch" +%Y-%m-%d 2>/dev/null || date -r "$tgt_epoch" +%Y-%m-%d)" \
        "$(date -d "@$src_epoch" +%Y-%m-%d 2>/dev/null || date -r "$src_epoch" +%Y-%m-%d)"
    else
      touch -r "$src" "$target"
    fi
    restored=$((restored + 1))
  else
    skipped=$((skipped + 1))
  fi
done < <(find "$tmp" -type f -print0)

echo
echo "  would restore: $restored"
echo "  already older: $skipped"
echo "  no longer present: $missing"
[ "$DRY" -eq 1 ] && echo "  nothing touched (--dry-run)"
exit 0
