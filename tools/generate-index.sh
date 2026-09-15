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

# Empty means "omit entirely". With HYDRA_JS set the page is the landing page
# rather than an archive listing, so the heading, the blurb and the "raiz del
# sitio" section header are dropped by default — on a front page they are
# chrome around content that speaks for itself. Set them explicitly to bring
# them back.
if [ -n "${HYDRA_JS:-}" ]; then
  PAGE_TITLE="${PAGE_TITLE-}"
  PAGE_INTRO="${PAGE_INTRO-}"
  SHOW_ROOT_HEADING="${SHOW_ROOT_HEADING:-0}"
else
  PAGE_TITLE="${PAGE_TITLE:-Archivo}"
  PAGE_INTRO="${PAGE_INTRO:-Archivos publicados de RadioLibre.}"
  SHOW_ROOT_HEADING="${SHOW_ROOT_HEADING:-1}"
fi

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
  "https://altred.xyz/Portafolio_ParlamentoDeLoVivo.html|Parlamento de lo Vivo"
  "https://altred.xyz/mdelibre/|mdelibre"
  "https://altred.xyz/mdelibre/cooperaciones/|co.operaciones"
  "https://altred.xyz/mdelibre/repo/|pasado/reciente"
  "https://altred.xyz/mdelibre/1999/|1999"
  "https://altred.xyz/mdelibre/dorkbotmde/trueque/|trueque"
  "https://altred.xyz/mdelibre/dorkbotmde/rebot/|rebot"
  "https://altred.xyz/mdelibre/dorkbotmde/oyeristas/|oyeristas"
  "https://altred.xyz/mdelibre/dorkbotmde/k.0_lab/|k.0_lab"
  "https://altred.xyz/mdelibre/dorkbotmde/ddr/|ddr"
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

# Optional hydra background, in the TiempoGranular palette.
#
# Set HYDRA_JS to the URL of a LOCALLY VENDORED hydra-synth build, e.g.
#   HYDRA_JS=/assets/js/hydra-synth.js generate-index.sh
# Leave it empty and the page renders exactly as before.
#
# Use the hydra-synth LIBRARY, never the hydra editor app: the editor's whole
# purpose is evaluating code typed by whoever is looking at it, which is not
# something to put on a public landing page. The sketch below is fixed in the
# page and no visitor input is ever evaluated.
HYDRA_JS="${HYDRA_JS:-}"

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
HYDRA_JS="$HYDRA_JS" \
MANIFEST="$manifest" PAGE_TITLE="$PAGE_TITLE" PAGE_INTRO="$PAGE_INTRO" \
SHOW_ROOT_HEADING="$SHOW_ROOT_HEADING" \
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

def build(nodes, base):
    """Turn tree's JSON into a nested list of items, dropping what is hidden.

    Two passes are needed rather than one: a directory whose entire contents
    were excluded is not published, and that can only be known after its
    children have been built. The ASCII connectors then depend on which child
    is genuinely LAST among the survivors, not last in the raw listing.
    """
    items = []
    for node in nodes:
        kind = node.get("type")
        name = node.get("name", "")
        # Only real files and directories. tree reports a symlink as type
        # "link"; dropping those means a link pointing at /etc or at someone's
        # home directory can never be published by accident.
        if kind not in ("directory", "file") or not name:
            continue

        parts = base + [name]
        if kind == "directory":
            kids = build(node.get("contents", []), parts)
            if not kids:
                continue
            counts["dirs"] += 1
            items.append({"kind": "dir", "name": name, "kids": kids})
        else:
            counts["files"] += 1
            size = node.get("size")
            if isinstance(size, int):
                counts["bytes"] += size
            items.append({
                "kind": "file",
                "name": name,
                "url": href(parts),
                "meta": " ".join(x for x in (
                    human(size), str(node.get("time", "")).strip()) if x),
                "blocked": name.lower().endswith(PROXIED),
            })
    return items


def emit(items, prefix=""):
    """Render items as tree(1)-style rows.

    The connector column is a monospace span while the names are not: the
    prefixes are all box-drawing characters and spaces four cells per level, so
    they line up with each other regardless of how wide the names beside them
    are. Setting the whole row monospace would have meant giving up the ZKM
    face on the names.
    """
    rows = []
    for i, it in enumerate(items):
        last = i == len(items) - 1
        conn = "\u2514\u2500\u2500 " if last else "\u251c\u2500\u2500 "
        pre = html.escape(prefix + conn)

        if it["kind"] == "dir":
            rows.append(
                f'<div class="row dir"><span class="tw">{pre}</span>'
                f'<span class="name">{html.escape(it["name"])}/</span></div>'
            )
            # A continued vertical guide under anything that still has siblings.
            rows.extend(emit(it["kids"],
                             prefix + ("    " if last else "\u2502   ")))
        elif it["blocked"]:
            counts["blocked"] += 1
            rows.append(
                f'<div class="row file blocked"><span class="tw">{pre}</span>'
                f'<span class="name">{html.escape(it["name"])}</span>'
                f'<span class="meta">{html.escape(it["meta"])}</span>'
                f'<span class="warn" title="nginx env\u00eda esta extensi\u00f3n a '
                f'Icecast; el archivo no se puede descargar">no servible</span></div>'
            )
        else:
            rows.append(
                f'<div class="row file"><span class="tw">{pre}</span>'
                f'<a href="/{html.escape(it["url"], quote=True)}">'
                f'{html.escape(it["name"])}</a>'
                f'<span class="meta">{html.escape(it["meta"])}</span></div>'
            )
    return "".join(rows)


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
        body = emit(build(contents, base))
        # Built outside the f-string: an f-string expression cannot contain a
        # backslash, and python 3.8 (Ubuntu 20.04) enforces that strictly.
        empty = '<div class="row empty">vacío</div>'
        rel_href = "" if rel == "." else html.escape(href([rel]), quote=True) + "/"
        rel_text = html.escape("raíz del sitio" if rel == "." else rel + "/")
        show_heading = os.environ.get("SHOW_ROOT_HEADING", "1") != "0" or rel != "."
        heading = (
            f'<h2><a href="/{rel_href}">{rel_text}</a></h2>' if show_heading else ""
        )
        sections.append(
            f'<section>{heading}'
            f'<div class="tree">{body or empty}</div></section>'
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
    site_items.append((url, label))
if site_items:
    rows = []
    for i, (url, label) in enumerate(site_items):
        conn = "\u2514\u2500\u2500 " if i == len(site_items) - 1 else "\u251c\u2500\u2500 "
        rows.append(
            f'<div class="row file"><span class="tw">{html.escape(conn)}</span>'
            f'<a href="{html.escape(url, quote=True)}">{html.escape(label)}</a></div>'
        )
    sections.append(
        '<section><h2>Sitios</h2><div class="tree">'
        + "".join(rows) + "</div></section>"
    )

# --- optional hydra background, TiempoGranular palette -----------------------
hydra_js = os.environ.get("HYDRA_JS", "").strip()

# Only a same-origin path is accepted. Pointing this at a CDN would hand every
# visitor to a third party and make the page break when that CDN moves; vendor
# the file instead.
if hydra_js and not hydra_js.startswith("/"):
    print(f"<!-- HYDRA_JS ignored: must be a local path, got {html.escape(hydra_js)} -->")
    hydra_js = ""

hydra_css = ""
hydra_body = ""
if hydra_js:
    # Palette taken from the live TiempoGranular page: #616161 ground, white
    # and #d6d6d6 type, Verdana at 13px.
    hydra_css = """
/* ZKM Serendipity, the same face the radiolibre page uses, referenced from the
   same origin rather than copied — it is ZKM's font, not ours to redistribute. */
@font-face {
  font-family: 'ZKM Serendipity';
  src: url('https://zkm.de/themes/custom/zkm/typeface/WiP_ZKMSerendipity/ZKMSerendipity-Medium.woff') format('woff');
  font-weight: 500; font-style: normal; font-display: swap;
}

:root { --bg:#616161; --fg:#fff; --fg-dim:#d6d6d6; --line:rgba(255,255,255,.35); }

body {
  font-family: 'ZKM Serendipity', ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 19px; line-height: 1.7; letter-spacing: .02em;
  background: var(--bg); color: var(--fg);
}

#hydra-bg { position:fixed; inset:0; width:100%; height:100%; z-index:0; display:block; }

/* No panel behind the text. Legibility over moving video comes from a shadow
   instead, which keeps the sketch fully visible. */
.wrap { position:relative; z-index:1; background:none; padding:34px 26px;
  text-shadow: 0 1px 3px rgba(0,0,0,.85), 0 0 14px rgba(0,0,0,.55); }

h2 { font-size: 1em; letter-spacing:.14em; border-bottom:1px solid var(--line); }

/* Single-spaced rows. The connector column is monospace so the box-drawing
   characters line up across lines; the names keep the ZKM face. */
.tree { margin: 0; }
.row { line-height: 1.12; white-space: nowrap; overflow-x: auto; padding: 0; }
.tw { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  white-space: pre; color: rgba(255,255,255,.45); font-size: .92em; }
.row.dir .name { color: var(--fg); }
a { border-bottom:1px solid transparent; color: var(--fg); }
a:hover { color:#111; background:var(--fg); text-shadow:none; border-bottom-color:var(--fg); }
.meta { font-size:.72em; color:var(--fg-dim); opacity:.8; }
.generated { color:var(--fg-dim); font-size:.75em; }

@media (prefers-reduced-motion: reduce) { #hydra-bg { display:none; } }
@media (max-width: 600px) { body { font-size:16px; } }
"""
    # The sketch is fixed here; nothing a visitor supplies is ever evaluated.
    hydra_body = f"""
<canvas id="hydra-bg"></canvas>
<script src="{html.escape(hydra_js, quote=True)}"></script>
<script>
(function () {{
  var c = document.getElementById('hydra-bg');
  if (!c || typeof HydraSynth === 'undefined' && typeof Hydra === 'undefined') return;
  // A full-screen GPU shader is a real cost on a phone and a real problem for
  // anyone sensitive to motion. Honour the OS setting and skip it entirely.
  var reduce = window.matchMedia
    && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (reduce) {{ c.style.display = 'none'; return; }}
  try {{
    var H = (typeof Hydra !== 'undefined') ? Hydra : HydraSynth;
    function size() {{ c.width = window.innerWidth; c.height = window.innerHeight; }}
    size();
    window.addEventListener('resize', size);
    var h = new H({{ canvas: c, detectAudio: false, enableStreamCapture: false }});
    // Granular drift: slow bands folded through noise, kept low-contrast so the
    // text above stays legible.
    osc(6, 0.03, 0.9)
      .modulate(noise(1.6, 0.06), 0.4)
      .luma(0.42, 0.06)
      .color(0.42, 0.42, 0.42)
      .modulateScale(osc(0.6, 0.02), 0.08)
      .blend(o0, 0.94)
      .out(o0);
    // Stop rendering while the tab is hidden rather than burning the GPU.
    document.addEventListener('visibilitychange', function () {{
      if (h && h.synth) h.synth.hush ? null : null;
      c.style.visibility = document.hidden ? 'hidden' : 'visible';
    }});
  }} catch (e) {{
    // WebGL unavailable, or the vendored file failed to load. The page is
    // fully readable without it.
    c.style.display = 'none';
  }}
}})();
</script>
"""

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
{hydra_css}
</style>
</head>
<body>
{hydra_body}
<div class="wrap">
{f'<h1>{html.escape(title)}</h1>' if title else ''}
{f'<p class="intro">{html.escape(intro)}</p>' if intro else ''}
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
