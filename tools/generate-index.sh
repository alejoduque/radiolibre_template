#!/usr/bin/env bash
#
# Build a static index page for published folders under the webroot.
#
# Runs `tree` over an explicit allowlist of directories and renders the result
# as one HTML page. Nothing in nginx needs to change: the output is a plain
# index.html inside a directory that is already served.
#
# The allowlist is the whole security model. A directory that is not named in
# PUBLISH is never walked and never appears in the output, so folders you reach
# by a long unguessable URL stay unlisted.
#
# Usage:
#   ./generate-index.sh            build the page
#   ./generate-index.sh --dry-run  print what would be published, write nothing
#
# Override any setting from the environment, e.g.
#   WEBROOT=/tmp/test OUTPUT=/tmp/test/archivo/index.html ./generate-index.sh

set -euo pipefail

# ----------------------------------------------------------------- settings

# Root of the served files.
WEBROOT="${WEBROOT:-/var/www/altred.xyz}"

# Where to write the page. Must be a directory that nginx already serves.
OUTPUT="${OUTPUT:-$WEBROOT/archivo/index.html}"

PAGE_TITLE="${PAGE_TITLE:-Archivo}"
PAGE_INTRO="${PAGE_INTRO:-Archivos publicados de RadioLibre.}"

# Directories to publish, relative to WEBROOT. THIS IS THE ALLOWLIST.
# Anything not listed here is invisible to this script. Edit this list.
#
# "." means the top level of the webroot itself — content sitting directly in
# /var/www/altred.xyz. Name subdirectories to publish those instead, or as
# well.
PUBLISH=(
  .
)

# Folders and files to keep OUT of the listing even though they sit inside a
# published directory. This is what makes "reachable by a long URL, but not
# advertised" work: publishing "." would otherwise list every folder at the top
# level, including the ones whose whole point is not being discoverable.
#
# Names are matched at any depth. Add the folder name, not a path.
PRIVATE=(
  # privado-url-larga-x7f3
)

# Other sites to link to, as "URL|Label" pairs. These are listed as links, not
# walked as directories.
#
# This is the right way to include another site that lives elsewhere on the
# server. Do NOT add a CMS directory (Grav, WordPress, and similar) to PUBLISH
# instead: their trees hold account files, security salts and database
# credentials, and publishing a file listing of one exposes all of it. Link to
# the running site; never index its source.
SITES=(
  # "https://adj.altred.xyz/|ADJ"
  # "https://etc.altred.xyz/|etc"
)

# For testing, PUBLISH_DIRS overrides the list above: a whitespace-separated
# string, since a bash array cannot be exported into the environment.
if [ -n "${PUBLISH_DIRS:-}" ]; then
  read -r -a PUBLISH <<< "$PUBLISH_DIRS"
fi

# How deep to descend.
MAX_DEPTH="${MAX_DEPTH:-4}"

# Never list these, at any depth. tree already hides dotfiles unless -a is
# given; they are repeated here so the intent is explicit and survives edits.
#
# Grouped by why they are excluded:
#   backups      — *.bak and friends. These are the ones that were sitting
#                  publicly in the webroot; never publish them.
#   server config — icecast.xml and anything config-shaped. An Icecast config
#                  contains source and admin passwords in clear text, so it
#                  must never be listed, and ideally never be in the webroot.
#   secrets      — keys, certificates, environment files, dumps.
#   site machinery — index.html and assets/, which are the site itself rather
#                  than published content.
IGNORE="${IGNORE:-.*|*.bak|*.bak-*|*.backup|*.old|*bkp*|*~|*.swp|*.tmp|*.part|icecast*|*.xml|*.xsl|*.conf|*.cfg|*.ini|*.env|*.key|*.pem|*.crt|*.csr|*.sql|*.dump|*.log|*.sh|*.py|*.php|id_rsa*|authorized_keys|htpasswd|*.yaml|*.yml|*.twig|*.phar|vendor|cache|logs|tmp|accounts|node_modules|__pycache__|index.html|assets}"

# ------------------------------------------------------------------- checks

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

command -v tree    >/dev/null 2>&1 || die "tree is not installed. Run: apt install tree"
command -v python3 >/dev/null 2>&1 || die "python3 is not installed."

[ -d "$WEBROOT" ] || die "WEBROOT does not exist: $WEBROOT"

# Never clobber a site's own landing page.
webroot_abs="$(cd "$WEBROOT" && pwd -P)"
out_dir="$(dirname "$OUTPUT")"
if [ "$(cd "$out_dir" 2>/dev/null && pwd -P || echo "$out_dir")" = "$webroot_abs" ] \
   && [ "$(basename "$OUTPUT")" = "index.html" ]; then
  die "refusing to overwrite the site's own $WEBROOT/index.html. Point OUTPUT at a subdirectory."
fi

# ------------------------------------------------------------------ collect

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
manifest="$tmp/manifest"
: > "$manifest"

# Anything named PRIVATE is folded into the ignore list, so it is never walked
# and never appears — the same mechanism that hides backups and configs.
for p in ${PRIVATE+"${PRIVATE[@]}"}; do
  [ -n "$p" ] && IGNORE="$IGNORE|$p"
done

# For testing, as with PUBLISH_DIRS.
if [ -n "${PRIVATE_DIRS:-}" ]; then
  read -r -a _priv <<< "$PRIVATE_DIRS"
  for p in "${_priv[@]}"; do IGNORE="$IGNORE|$p"; done
fi

# The generated page lives in a directory under the webroot; listing that
# directory in its own index is just noise, so exclude it automatically.
out_rel="${out_dir#"$webroot_abs"/}"
if [ "$out_rel" != "$out_dir" ] && [ -n "$out_rel" ]; then
  IGNORE="$IGNORE|${out_rel%%/*}"
fi

published=0
for rel in "${PUBLISH[@]}"; do
  if [ "$rel" = "." ]; then
    dir="$WEBROOT"
  else
    dir="$WEBROOT/$rel"
  fi

  if [ ! -d "$dir" ]; then
    printf 'skip: %s (not a directory)\n' "$rel" >&2
    continue
  fi

  # Refuse anything that resolves outside the webroot, which is how a stray
  # symlink would otherwise publish /etc. "." is the webroot itself, so it is
  # allowed to match exactly; everything else must be strictly beneath it.
  real="$(cd "$dir" && pwd -P)"
  case "$real" in
    "$webroot_abs") [ "$rel" = "." ] || { printf 'skip: %s (resolves to the webroot itself)\n' "$rel" >&2; continue; } ;;
    "$webroot_abs"/*) : ;;
    *) printf 'skip: %s (resolves outside the webroot: %s)\n' "$rel" "$real" >&2; continue ;;
  esac

  json="$tmp/tree.$published.json"
  # -J json, -s sizes, -D dates, --noreport drops the trailing summary,
  # --dirsfirst groups folders. tree does not follow symlinks without -l.
  tree -J -s -D --timefmt '%Y-%m-%d' \
       -L "$MAX_DEPTH" -I "$IGNORE" \
       --noreport --dirsfirst \
       -- "$dir" > "$json"

  printf '%s\t%s\n' "$rel" "$json" >> "$manifest"
  published=$((published + 1))
done

[ "$published" -gt 0 ] || die "nothing to publish: none of the PUBLISH entries exist under $WEBROOT"

if [ "$DRY_RUN" -eq 1 ]; then
  # Print every path that would become public. The whole point of this tool is
  # controlling what is exposed, so the rehearsal has to show the actual list,
  # not just the directory names.
  echo "would write: $OUTPUT"
  echo "would publish $published director(ies). Entries that would become public:"
  echo
  MANIFEST="$manifest" python3 - <<'PYTHON'
import json, os

PROXIED = (".mp3", ".ogg", ".aac", ".opus", ".m3u", ".pls")
files = dirs = blocked = 0

def walk(nodes, base):
    """Return the lines this level would emit, so empty folders can be dropped
    exactly as the HTML renderer drops them."""
    global files, dirs, blocked
    lines = []
    for node in nodes:
        kind, name = node.get("type"), node.get("name", "")
        if kind not in ("directory", "file") or not name:
            continue
        path = "/".join(base + [name])
        if kind == "directory":
            kids = walk(node.get("contents", []), base + [name])
            if not kids:
                continue
            dirs += 1
            lines.append(f"  dir   /{path}/")
            lines.extend(kids)
        else:
            files += 1
            if name.lower().endswith(PROXIED):
                blocked += 1
                lines.append(f"  BLOCK /{path}   (Icecast proxy swallows this extension)")
            else:
                lines.append(f"  file  /{path}")
    return lines

with open(os.environ["MANIFEST"], encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        rel, path = line.split("\t", 1)
        with open(path, encoding="utf-8", errors="replace") as jf:
            data = json.load(jf)
        root = next((n for n in data if n.get("type") == "directory"), None)
        for line in walk(root.get("contents", []) if root else [],
                         [] if rel == "." else [rel]):
            print(line)

print()
print(f"  {dirs} folder(s), {files} file(s)"
      + (f", {blocked} not servable" if blocked else ""))
print("  nothing written (--dry-run)")
PYTHON
  exit 0
fi

# ------------------------------------------------------------------- render

mkdir -p "$out_dir"

SITES_LIST="$(printf '%s\n' ${SITES+"${SITES[@]}"})" \
MANIFEST="$manifest" PAGE_TITLE="$PAGE_TITLE" PAGE_INTRO="$PAGE_INTRO" \
python3 - > "$OUTPUT" <<'PYTHON'
import html, json, os, urllib.parse
from datetime import datetime, timezone

manifest = os.environ["MANIFEST"]
title = os.environ["PAGE_TITLE"]
intro = os.environ["PAGE_INTRO"]

def human(n):
    if not isinstance(n, int) or n < 0:
        return ""
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"

def href(parts):
    """Percent-encode each path segment separately so slashes stay slashes."""
    return "/".join(urllib.parse.quote(p, safe="") for p in parts)

# Audio the Icecast proxy swallows: these paths are proxied to 127.0.0.1:8000
# and can never be downloaded as files, so flag them instead of linking.
PROXIED = (".mp3", ".ogg", ".aac", ".opus", ".m3u", ".pls")

counts = {"dirs": 0, "files": 0, "bytes": 0, "blocked": 0}

def render(nodes, base, depth=0):
    out = []
    for node in nodes:
        kind = node.get("type")
        name = node.get("name", "")
        # Only real files and directories are published. tree reports a
        # symlink as type "link"; dropping those means a link pointing at /etc
        # or at someone's home directory can never be published by accident.
        if kind not in ("directory", "file") or not name:
            continue

        parts = base + [name]
        # Every filename reaching HTML is escaped; every one reaching an href
        # is percent-encoded. Names are attacker-influenced if anyone can
        # upload.
        safe_name = html.escape(name)
        link = html.escape(href(parts), quote=True)

        if kind == "directory":
            kids = render(node.get("contents", []), parts, depth + 1)
            # A folder whose entire contents were excluded is not published as
            # an empty shell: that would still advertise that it exists, and
            # its name alone can be telling.
            if not kids:
                continue
            counts["dirs"] += 1
            body = f'<ul>{kids}</ul>'
            out.append(
                f'<li class="dir"><details{" open" if depth == 0 else ""}>'
                f'<summary><span class="name">{safe_name}/</span></summary>'
                f'{body}</details></li>'
            )
        else:
            counts["files"] += 1
            size = node.get("size")
            if isinstance(size, int):
                counts["bytes"] += size
            meta = " ".join(
                x for x in (human(size), html.escape(str(node.get("time", "")))) if x
            )
            if name.lower().endswith(PROXIED):
                counts["blocked"] += 1
                out.append(
                    f'<li class="file blocked"><span class="name">{safe_name}</span>'
                    f'<span class="meta">{meta}</span>'
                    f'<span class="warn" title="nginx envía esta extensión a Icecast; '
                    f'el archivo no se puede descargar">no servible</span></li>'
                )
            else:
                out.append(
                    f'<li class="file"><a href="/{link}">{safe_name}</a>'
                    f'<span class="meta">{meta}</span></li>'
                )
    return "".join(out)

sections = []
with open(manifest, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        rel, path = line.split("\t", 1)
        with open(path, encoding="utf-8", errors="replace") as jf:
            data = json.load(jf)
        # tree -J returns [ {the directory}, {"type":"report"} ]
        root = next((n for n in data if n.get("type") == "directory"), None)
        contents = root.get("contents", []) if root else []
        # "." is the webroot itself: links must be /file, not /./file.
        base = [] if rel == "." else [rel]
        body = render(contents, base)
        # Built outside the f-string: an f-string expression cannot contain a
        # backslash, and python 3.8 (Ubuntu 20.04) enforces that strictly.
        empty = "<li class='empty'>vacío</li>"
        rel_href = "" if rel == "." else html.escape(href([rel]), quote=True) + "/"
        rel_text = html.escape("raíz del sitio" if rel == "." else rel + "/")
        sections.append(
            f'<section><h2><a href="/{rel_href}">{rel_text}</a></h2>'
            f'<ul class="tree">{body or empty}</ul></section>'
        )

# Curated links to other sites. Only http(s) URLs are emitted, so a stray
# javascript: or data: entry cannot become a live link.
site_items = []
for raw in os.environ.get("SITES_LIST", "").splitlines():
    raw = raw.strip()
    if not raw:
        continue
    url, _, label = raw.partition("|")
    url, label = url.strip(), (label.strip() or url.strip())
    if not url.lower().startswith(("http://", "https://")):
        continue
    site_items.append(
        f'<li class="file"><a href="{html.escape(url, quote=True)}">'
        f'{html.escape(label)}</a></li>'
    )
if site_items:
    sections.append(
        '<section><h2>Sitios</h2><ul class="tree">'
        + "".join(site_items) + "</ul></section>"
    )

generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
note = ""
if counts["blocked"]:
    note = (
        f'<p class="note">{counts["blocked"]} archivo(s) de audio no se listan como '
        f'enlace: nginx envía .mp3/.ogg/.aac/.opus/.m3u/.pls a Icecast, así que no '
        f'se pueden descargar desde aquí.</p>'
    )

print(f"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="robots" content="noindex, nofollow">
<title>{html.escape(title)}</title>
<style>
:root {{ color-scheme: dark; }}
body {{ background:#000; color:#fff; margin:0; padding:24px;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; line-height:1.5; }}
.wrap {{ max-width:900px; margin:0 auto; }}
h1 {{ text-transform:uppercase; letter-spacing:2px; font-size:1.6em; margin:0 0 4px; }}
h2 {{ font-size:1.05em; text-transform:uppercase; letter-spacing:1px;
  border-bottom:1px solid #444; padding-bottom:6px; margin:32px 0 8px; }}
a {{ color:#fff; text-decoration:none; border-bottom:1px solid #555; }}
a:hover {{ color:#000; background:#fff; border-bottom-color:#fff; }}
.intro, .generated, .note {{ color:#aaa; font-size:.85em; }}
.note {{ border-left:2px solid #ff9b9b; padding-left:10px; margin:16px 0; }}
ul {{ list-style:none; padding-left:18px; margin:4px 0; }}
ul.tree {{ padding-left:0; }}
li {{ padding:1px 0; }}
li.dir > details > summary {{ cursor:pointer; list-style:none; }}
li.dir > details > summary::before {{ content:'+'; display:inline-block; width:1.2em; color:#888; }}
li.dir > details[open] > summary::before {{ content:'-'; }}
li.file::before {{ content:''; display:inline-block; width:1.2em; }}
.meta {{ color:#777; font-size:.8em; margin-left:10px; }}
.warn {{ color:#ff9b9b; font-size:.75em; margin-left:10px; text-transform:uppercase; }}
.empty {{ color:#666; font-style:italic; }}
.blocked .name {{ color:#888; text-decoration:line-through; }}
footer {{ margin-top:40px; border-top:1px solid #333; padding-top:12px; }}
</style>
</head>
<body>
<div class="wrap">
<h1>{html.escape(title)}</h1>
<p class="intro">{html.escape(intro)}</p>
{note}
{"".join(sections)}
<footer>
<p class="generated">{counts["dirs"]} carpetas, {counts["files"]} archivos,
{human(counts["bytes"])} &middot; generado {generated}</p>
<p class="generated"><a href="https://radiolibre.altred.xyz/">&larr; radiolibre</a></p>
</footer>
</div>
</body>
</html>""")
PYTHON

chmod 644 "$OUTPUT"
printf 'wrote %s (%s bytes) covering %d director(ies)\n' \
  "$OUTPUT" "$(wc -c < "$OUTPUT" | tr -d ' ')" "$published"
