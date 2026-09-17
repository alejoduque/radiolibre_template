# Web Templates

## radiolibre.altred.xyz

The live site and player for [radiolibre.altred.xyz](https://radiolibre.altred.xyz/).
Static files, no build step. See [its README](./radiolibre.altred.xyz/README.md)
for deployment and for the Icecast quirks the player works around.

## Radiolibre (2020 template)

The original `radiolibre.cc` template. Kept for reference — its player points at
`live.radiolibre.cc`, which no longer resolves.

![Radiolibre.cc](./previews/radiolibrecc.png)

## altred.xyz

Pages and tools for the archive host. `altred.xyz/TiempoGranular/` is the
hydra page; `server/nginx/altred.xyz.conf` is the vhost; `tools/` holds the
index generator and the publish scripts, all fetched onto the server with
`curl` from this repo. Sites uploaded as a tarball (the GPS logs site at
`/gpslogs/`) go in through `tools/install-tar-site.sh`.
