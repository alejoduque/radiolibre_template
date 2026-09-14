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
PUBLISH=(
  audio
  documentos
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
IGNORE="${IGNORE:-.*|*.bak|*.bak-*|*.backup|*~|*.swp|*.tmp|*.part|*.env|*.key|*.pem|*.crt|*.csr|*.conf|*.cfg|*.ini|*.sql|*.dump|*.log|*.sh|*.py|*.php|id_rsa*|authorized_keys|htpasswd|.htpasswd|node_modules|__pycache__|.git|index.html}"

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

published=0
for rel in "${PUBLISH[@]}"; do
  dir="$WEBROOT/$rel"

  if [ ! -d "$dir" ]; then
    printf 'skip: %s (not a directory)\n' "$rel" >&2
    continue
  fi

  # Refuse anything that resolves outside the webroot, which is how a stray
  # symlink would otherwise publish /etc.
  real="$(cd "$dir" && pwd -P)"
  case "$real" in
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
  echo "would publish $published director(ies):"
  cut -f1 "$manifest" | sed 's/^/  /'
  echo "would write: $OUTPUT"
  exit 0
fi

# ------------------------------------------------------------------- render

mkdir -p "$out_dir"

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
            counts["dirs"] += 1
            kids = render(node.get("contents", []), parts, depth + 1)
            body = f'<ul>{kids}</ul>' if kids else '<ul><li class="empty">vacío</li></ul>'
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
        body = render(contents, [rel])
        # Built outside the f-string: an f-string expression cannot contain a
        # backslash, and python 3.8 (Ubuntu 20.04) enforces that strictly.
        empty = "<li class='empty'>vacío</li>"
        rel_href = html.escape(href([rel]), quote=True)
        rel_text = html.escape(rel)
        sections.append(
            f'<section><h2><a href="/{rel_href}/">{rel_text}/</a></h2>'
            f'<ul class="tree">{body or empty}</ul></section>'
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
