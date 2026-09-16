# TiempoGranular — hydra patch

Served at `https://altred.xyz/TiempoGranular/`.

Four clips from `/archivos/`, one per hydra output, laid out 2×2 by `render()`,
with the TG logo and the spectrum PNG layered over the canvas as real `<img>`
elements.

Deploy: copy `index.html` to `/var/www/altred.xyz/TiempoGranular/`. Nothing in
nginx is needed — it is static HTML under the default location.

## Preparing rarae_aves_2016.webm

The original is **VP8, 1280×720, 30fps, 74 minutes, 586 MB**. The bitrate is
sensible for that length; the length is the problem. As an archive master it is
fine and should be kept. As a texture in a browser it is the wrong shape — the
patch decodes four videos at once, and one of them being a 74-minute 720p
stream starves the other three.

Both recipes drop the audio (`-an`): nothing here plays sound, and the Vorbis
track is pure weight. `-movflags +faststart` moves the index to the front so
playback can begin before the file has arrived, and `-pix_fmt yuv420p` keeps it
decodable everywhere.

### The version the patch uses — a loop, not the whole piece

Pick a passage worth looping and take a few minutes of it. `-ss` before `-i`
seeks by keyframe, which is near-instant even on a 586 MB file:

    ffmpeg -ss 00:05:00 -i rarae_aves_2016.webm -t 180 \
      -vf "scale=960:-2,fps=24" \
      -c:v libx264 -crf 30 -preset veryfast \
      -pix_fmt yuv420p -an -movflags +faststart \
      rarae_aves_2016_web.mp4

Roughly 15–25 MB for three minutes. Adjust `-ss` to choose the passage and
`-t` for its length.

H.264 rather than VP9: VP9 would be perhaps 30% smaller but takes many times
longer to encode, and this is a background texture being contrast-stretched and
modulated — the difference will not survive the patch.

### Speeding it up

The patch uses a sped-up cut. `setpts` rescales presentation timestamps, so
`0.25*PTS` plays four times faster; there is no audio to keep in sync because
`-an` already dropped it.

    ffmpeg -i rarae_aves_2016_web.mp4 -vf "setpts=0.25*PTS" \
      -c:v libx264 -crf 30 -preset veryfast \
      -pix_fmt yuv420p -an -movflags +faststart \
      rarae_aves_2016_fast.mp4

Change the multiplier for a different rate: `0.5` is 2×, `0.125` is 8×. Faster
also means smaller, since there are fewer frames to store.

### Optional: the whole piece, compressed

For watching rather than for the patch. This re-encodes 74 minutes and will
take a while:

    ffmpeg -i rarae_aves_2016.webm \
      -vf "scale=854:-2,fps=24" \
      -c:v libx264 -crf 32 -preset veryfast \
      -pix_fmt yuv420p -an -movflags +faststart \
      rarae_aves_2016_full.mp4

Expect roughly 60–110 MB. Keep the original `.webm` regardless — these are
lossy re-encodes of an already-lossy source, and nothing is gained by
discarding the master.

## Swapping clips

`CLIPS` at the top of the script. Everything in `/archivos/` is available:
`storm.webm` (985 K), `am.webm` (7.6 M), `arbol.webm` (12 M), `8am.webm` (44 M),
`8m.webm` (40 M), `std.mp4` (47 M), `std_nosound_lr.mp4` (30 M),
`storm_thunder.mp4` (1 M).

Four entries, four outputs. More than four would need extra `sN`/`oN` pairs.
