#!/usr/bin/env bash
#
# Repoint dead self-hosted domains in hotglue content at their current location.
#
#   rewrite-old-domains.sh --dry-run    count what would change, change nothing
#   rewrite-old-domains.sh              back up, then rewrite
#
# These sites have moved host several times — mdelibre.co, an IP, allowed.org —
# and each move left absolute URLs baked into the page data. hotglue stores
# objects as plain text, so they can be rewritten in place.
#
# Every host pattern ends with (:[0-9]+)? so an explicit port is consumed along
# with the hostname. Without it, http://<host>:8000/radiolibre.mp3 rewrites to
# ".../mdelibre:8000/radiolibre.mp3" — the port stranded mid-URL. That is the
# same shape of mistake that produced cc.88.99.123.96, made a second time.
#
# What actually protects subdomains is the "https?://" anchor on every pattern:
# in "http://cooperaciones.mdelibre.co" the text after "://" is "cooperaciones.",
# so the bare mdelibre.co rule cannot match it, and likewise cc.88.99.123.96 is
# untouched by the 88.99.123.96 rule. Rules are still listed most-specific-first
# as a second line of defence — if you add a pattern, KEEP THE ANCHOR, because
# an unanchored one would match mid-hostname and mangle every subdomain.
#
# This is not hypothetical: a previous pass over this content replaced
# mdelibre.co with a bare IP and turned cc.mdelibre.co into cc.88.99.123.96,
# which is why that stranded 47-reference host exists at all.
#
# Only hosts that were OURS and are now dead are listed. Live third-party sites
# (dorkbot.org, unloquer.org, the WordPress blogs) are left alone, and so are
# dead third-party ones (jardincosmico.net, labsurlab) — rewriting those would
# invent links that never existed.

set -euo pipefail

BASE="${BASE:-https://altred.xyz/mdelibre}"

# Dots escaped so $BASE can appear inside a pattern. The counts use grep -E
# and the substitution uses perl, so the pattern must be valid in both — which
# rules out perl-only \Q...\E quoting.
BASE_RE="${BASE//./\\.}"

ROOTS=(/var/www/html /var/www/dorkbotmde /var/www/hotglues)

# "regex<TAB>replacement", most specific first. Extended regex, | delimiter.
# Deliberately NOT rewritten: cc.88.99.123.96 (47 refs, only "/" and "/?chat").
# "cc." was a stranded subdomain from an earlier mdelibre.co -> IP replacement,
# but no install on this server has a "chat" page — cooperaciones/content/ holds
# Calendario, RedCoop, libreria, memoria, talleres and friends, no chat. Pointing
# those links at /cooperaciones would fabricate a page that never existed here.
# A dead link is honest; a wrong one is not.
RULES=(
  "https?://cooperaciones\.mdelibre\.co(:[0-9]+)?	$BASE/cooperaciones"
  "https?://antifa\.allowed\.org(:[0-9]+)?	$BASE"
  "https?://88\.99\.123\.96(:[0-9]+)?	$BASE"
  "https?://mdelibre\.co(:[0-9]+)?	$BASE"
  # Stale PATH prefix, not a host. On an older server the installs lived under
  # /old/html/, so links read http://<host>/old/html/repo/. The host rules above
  # fix the hostname but leave that segment, producing /mdelibre/old/html/repo/
  # which 404s while /mdelibre/repo/ serves fine. This runs last, after the
  # hostnames have been normalised onto $BASE.
  "$BASE_RE/old/html	$BASE"
  # The old Icecast stream. Once the host rules have normalised
  # http://<host>:8000/radiolibre.mp3 onto $BASE, repoint it at the live mount.
  # radiolibre.altred.xyz proxies *.mp3 to Icecast, so this resolves as soon as
  # a source connects to /live.mp3 (nothing is broadcasting as I write this).
  "$BASE_RE/radiolibre\.mp3	https://radiolibre.altred.xyz/live.mp3"
  # /bogdec was the Bogota Declaration. No install has that page any more, but
  # the text survives in the wiki tree as a Google cache snapshot taken on
  # 2011-01-01 of projects.dorkbot.org/dorkbot-wiki/.../DeclaracionBogota/iEMS.
  # The related images are separate, under dorkbotmde/bogota_declaration/.
  # Every observed reference is the bare /bogdec with no sub-path, so a plain
  # match is safe here; if sub-paths ever appear this rule would mangle them.
  # TiempoGranular's media, which lived on a hydra-server on port 9999 of this
  # same machine. Those files are now linked at /archivos/, the identical path
  # the old URLs used, so only the host and port change.
  "https?://116\.203\.239\.139:9999	https://altred.xyz"
  "$BASE_RE/bogdec	https://altred.xyz/mdelibre/dorkbotmde/dorkbotmde_wiki/DorkbotMdeWiki%20DeclaracionBogota%20iEMS%20-%20dorkbot-wiki.html"
)

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

for r in "${ROOTS[@]}"; do
  [ -d "$r" ] || { echo "skip: $r (missing)" >&2; }
done

# grep exits 1 when it matches nothing. Under `set -e` with pipefail that
# aborts the script precisely when a rewrite has fully succeeded and there is
# nothing left to find, so the count is guarded.
# Files that may contain URLs worth rewriting: hotglue's object files (any
# extension, under content/) plus the static HTML archives that sit beside them.
# The k.0_lab and dorkbotmde_wiki trees are plain mirrored HTML with absolute
# links to a long-dead IP, and they are not under any content/ directory — the
# original version of this script silently skipped every one of them.
# "$@" is forwarded so callers can pass -print0. Without it, find_files -print0
# silently returned newline-separated paths and every NUL-expecting consumer
# (xargs -0, tar --null -T -) read the whole list as one filename.
find_files() {
  find "${ROOTS[@]}" -type f \
    \( -path '*/content/*' -o -iname '*.html' -o -iname '*.htm' -o -iname '*.css' -o -iname '*.js' \) \
    "$@" 2>/dev/null
}

# Counted over the same set that gets rewritten, so the reported numbers cannot
# promise fixes to files the rewrite never visits.
count_refs() {
  { find_files -print0 | xargs -0 grep -ohiE "$1" 2>/dev/null || true; } | wc -l | tr -d ' '
}

count_files() { find_files | wc -l | tr -d ' '; }
NFILES="$(count_files)"
[ "$NFILES" -gt 0 ] || { echo "error: no content files found under ${ROOTS[*]}" >&2; exit 1; }
echo "content files: $NFILES"
echo

if [ "$DRY" -eq 1 ]; then
  echo "DRY RUN — nothing is written"
  echo
  total=0
  for rule in "${RULES[@]}"; do
    pat="${rule%%	*}"
    rep="${rule##*	}"
    n=$(count_refs "$pat")
    total=$((total + n))
    printf "  %-44s -> %-46s %s refs\n" "$pat" "$rep" "$n"
  done
  echo
  echo "  $total reference(s) match the content as it stands"
  echo
  echo "  Counts are measured against the CURRENT text, so a rule that matches"
  echo "  what an earlier rule produces reports 0 here and still applies. The"
  echo "  /old/html and radiolibre.mp3 rules are both of that kind: they only"
  echo "  see their input once the hostname rules above have run."
  echo
  echo "  run without --dry-run to apply (a backup is taken first)"
  exit 0
fi

backup="/root/hotglue-content-$(date +%F-%H%M%S).tar.gz"
# Back up precisely the files this run can modify — not just content/, now that
# static HTML outside it is rewritten too.
find_files -print0 | tar czf "$backup" --null -T -
echo "backup: $backup ($(du -h "$backup" | cut -f1))"
echo

for rule in "${RULES[@]}"; do
  pat="${rule%%	*}"
  rep="${rule##*	}"
  before=$(count_refs "$pat")
  if [ "$before" -gt 0 ]; then
    # perl rather than sed: sed -i takes a mandatory suffix on BSD and none on
    # GNU, so the same line cannot run in both places. perl -pi is identical
    # everywhere, which also makes this testable off the server.
    find_files -print0 | xargs -0 perl -pi -e "s|$pat|$rep|gi"
  fi
  after=$(count_refs "$pat")
  printf "  %-44s %s -> %s remaining\n" "$pat" "$before" "$after"
done

echo
echo "done. restore with:  tar xzf $backup -C /"
