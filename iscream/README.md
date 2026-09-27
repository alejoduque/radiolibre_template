# iScream — Sistema de Alerta Temprana de Radiolibre

Served at **https://reporta.altred.xyz/**. Anyone can go on air from a phone
browser to the Radiolibre Icecast (up to 8 people at once, on `/reporta.mp3`,
`/reporta2.mp3` … `/reporta8.mp3`, all heard on
[radiolibre.altred.xyz](https://radiolibre.altred.xyz/)) and talk in
`#radiolibre` without installing an app or creating an account. **Nothing is
recorded on the server**: the audio only passes through ffmpeg, and the chat
keeps no history.

It's a rewrite of the 2021 reporta service, a fork of
[jamie/icecream](https://gitlab.com/jamie/icecream).

```
phone ── MediaRecorder (webm/opus · Safari: mp4/aac)
   │  wss://reporta.altred.xyz/ws/stream
   ▼
server.js ──stdin──▶ ffmpeg ──icecast://──▶ Icecast 127.0.0.1:8000/reporta[N].mp3  (first free of 8)
                                            (the password stays in /etc/iscream/iscream.env)
phone ── chat.js ── wss://reporta.altred.xyz/irc ──▶ Ergo 127.0.0.1:8097 ── #radiolibre
                                  IRC apps: reporta.altred.xyz:6697 (TLS) ─┘
                                  optional: matterbridge ⇄ Libera #radiolibre ⇄ Telegram
```

## Layout

```
server.js            static files, /api/estado, /ws/stream bridge (and /irc proxy in dev)
lib/stream.js        metadata sanitising, ffmpeg args, error mapping, the pool of mounts
www/                 the page: index.html, css/iscream.css, js/broadcast.js, js/chat.js, img/ (1-bit GIFs from altred.xyz)
test/                node --test
iscream.env.example  every setting; the real file is /etc/iscream/iscream.env on the server
deploy/              nginx vhost, systemd units, Ergo config, matterbridge example, deploy.sh
```

## Running locally

```sh
npm install
npm test
node server.js                                     # dry run: audio is decoded and discarded
open http://localhost:3000/
```

To try the chat, run Ergo from its release tarball with a dev copy of
`deploy/ergo/ircd.yaml`. Remove the `:6697` TLS listener, add
`http://localhost:3000` to `allowed-origins`, then:

```sh
ergo initdb --conf ircd.yaml && ergo run --conf ircd.yaml
CHAT_PROXY=ws://127.0.0.1:8097 node server.js
```

To stream for real, set `ICECAST_SOURCE_PASSWORD` (and `ICECAST_HOST`). The
microphone only works on `https://` or `localhost`.

## Deploying

From the Mac, same ssh access as `altred.xyz/deploy.sh` (root@altred.xyz, port 8888):

```sh
deploy/deploy.sh check      # read-only: vhost, cert, services, ports
deploy/deploy.sh install    # once: ffmpeg/node/certbot, users, Ergo, certificate, /etc/iscream/iscream.env
deploy/deploy.sh push -n    # rehearsal
deploy/deploy.sh push       # app → /opt/iscream, configs, nginx -t (rolls back on failure), restart
```

`ICECAST_SOURCE_PASSWORD` must be the password of the `/reporta.mp3`
`<mount>` block in `/etc/icecast2/icecast.xml`, not the global
`<source-password>`: a mount's own password overrides the global one.

### Broadcast slots

`ICECAST_SLOTS` (default 8) sets how many people can be on air at once. Each
needs a `<mount>` block in icecast.xml; this clones the `/reporta.mp3` block
for the others (idempotent, backs up, reloads Icecast without dropping anyone):

```sh
ssh -p 8888 root@altred.xyz 'python3 - 8' < deploy/icecast-add-slots.py
```

Before handing out a slot, server.js asks Icecast's status page which mounts
already have a source, so a mount fed from elsewhere (butt, a studio) is skipped. Before the first push, check that the
2021 `node server.js` is not still holding port 3000 (`deploy.sh check` shows it).

### Chat administration

- The Ergo oper password in `ircd.yaml` is a placeholder no one can use. To
  administer, run `/opt/ergo/ergo genpasswd` on the server, put the hash in
  `/var/lib/ergo/ircd.yaml`, then `systemctl reload ergo`.
- Register `#radiolibre` once from any client with `/msg NickServ REGISTER …`,
  then `/msg ChanServ REGISTER #radiolibre`.

### Bridging to Libera and Telegram (optional)

1. Install [matterbridge](https://github.com/42wim/matterbridge/releases) at
   `/opt/matterbridge/matterbridge`, with a `matterbridge` system user.
2. Copy `deploy/matterbridge/matterbridge.toml.example` to
   `/etc/matterbridge/matterbridge.toml` and fill in the Libera bot's NickServ
   password, the Telegram BotFather token and the group's chat id.
3. `systemctl enable --now matterbridge`, set `CHAT_BRIDGED=1` in
   `/etc/iscream/iscream.env`, then `systemctl restart iscream`. The page now
   warns that chat messages also land on Libera and Telegram.

## Privacy

- nginx has `access_log off` for this host. Ergo keeps no history, cloaks IPs
  and doesn't log raw lines. server.js logs only start/stop and the metadata
  the broadcaster chose to publish.
- The font still loads from zkm.de, like on radiolibre.altred.xyz. That is the
  one third-party request the page makes.

## Credits and licence

Based on icecream by Jamie McClelland (GPL-3.0), itself derived from Facebook's
Canvas-Streaming-Example (see `LICENSE.icecream`). Chat by [Ergo](https://ergo.chat/).
The 1-bit GIFs come from altred.xyz's `oldwebs/1bit` archive.
