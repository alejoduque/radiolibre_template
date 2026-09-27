#!/bin/bash
# deploy.sh — put iScream on reporta.altred.xyz, from the Mac, over ssh.
#
#   deploy/deploy.sh check      what is on the server now (read-only)
#   deploy/deploy.sh install    first time: packages, users, Ergo, certificate, env file
#   deploy/deploy.sh push -n    rehearsal: list what push would upload
#   deploy/deploy.sh push       upload app + configs, npm install, nginx -t, restart
#
# Same access as altred.xyz/deploy.sh: root@altred.xyz on port 8888 (override
# with HOST= / PORT=). One ssh connection per run, so one password prompt.
#
# Secrets never travel from here: /etc/iscream/iscream.env and
# /etc/matterbridge/matterbridge.toml are created and edited on the server.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOST="${HOST:-root@altred.xyz}"
PORT="${PORT:-8888}"
DOMAIN=reporta.altred.xyz
ERGO_VERSION="${ERGO_VERSION:-2.19.1}"

SOCK="${TMPDIR:-/tmp}/iscream-deploy-$$"
SSH=(ssh -p "$PORT" -o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=60)
cleanup() { ssh -p "$PORT" -o ControlPath="$SOCK" -O exit "$HOST" 2>/dev/null || true; }
trap cleanup EXIT
remote() { "${SSH[@]}" "$HOST" "export LC_ALL=C.UTF-8 LANG=C.UTF-8; $*"; }
up() { rsync -az -e "${SSH[*]}" "$@"; }

cmd="${1:-}"
DRY=0
[ "${2:-}" = "-n" ] && DRY=1

case "$cmd" in
check)
  remote "
    echo '== vhost';    ls -l /etc/nginx/sites-enabled/ | grep -i reporta || echo 'none for $DOMAIN'
    echo '== cert';     ls /etc/letsencrypt/live/ | grep -x $DOMAIN || echo 'no certificate for $DOMAIN'
    echo '== services'; systemctl is-active iscream ergo matterbridge 2>&1 | paste -sd' ' -
    echo '== ports';    ss -ltnp | grep -E ':(3000|8097|6667|6697|8000) ' || true
    echo '== tools';    node -v 2>&1; ffmpeg -version 2>/dev/null | head -1 || echo 'no ffmpeg'
    echo '== system';   uname -m; . /etc/os-release && echo \$PRETTY_NAME
    echo '== old icecream (2021)'
    for pid in \$(pgrep -f '[a]udio_stream_archive/icecream/server.js'); do
      echo \"pid \$pid, started by: \$(ps -o user= -p \$pid) · unit: \$(ps -o unit= -p \$pid 2>/dev/null)\"
      tr '\\0' ' ' < /proc/\$pid/cmdline; echo
    done
    systemctl list-units --all --no-legend 2>/dev/null | grep -iE 'icecream|reporta|pm2|forever' || true
    crontab -l 2>/dev/null | grep -iE 'icecream|server.js' || true
    crontab -u radio -l 2>/dev/null | grep -iE 'icecream|server.js' || true
    grep -lsE 'icecream|server.js' /etc/rc.local /etc/systemd/system/*.service 2>/dev/null || true
  "
  echo '== https'
  curl -sS -o /dev/null -w "%{http_code} %{ssl_verify_result}\n" "https://$DOMAIN/" || true
  curl -sS "https://$DOMAIN/api/estado" || true; echo
  ;;

install)
  remote "set -e
    command -v ffmpeg >/dev/null || apt-get install -y ffmpeg
    command -v node   >/dev/null || apt-get install -y nodejs npm
    [ \"\$(uname -m)\" = x86_64 ] || { echo 'Ergo download below assumes x86_64' >&2; exit 1; }
    command -v certbot >/dev/null || apt-get install -y certbot
    for u in iscream ergo; do
      id \$u >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin \$u
    done
    install -d -m 755 /opt/iscream /var/www/acme
    install -d -o ergo -g ergo -m 700 /var/lib/ergo

    # Ergo: a single static binary.
    if [ ! -x /opt/ergo/ergo ]; then
      tmp=\$(mktemp -d)
      curl -fsSL https://github.com/ergochat/ergo/releases/download/v$ERGO_VERSION/ergo-$ERGO_VERSION-linux-x86_64.tar.gz | tar xz -C \$tmp
      rm -rf /opt/ergo && mv \$tmp/ergo-$ERGO_VERSION-linux-x86_64 /opt/ergo
    fi
    [ -d /var/lib/ergo/languages ] || cp -r /opt/ergo/languages /var/lib/ergo/ && chown -R ergo:ergo /var/lib/ergo

    # Env file: created once, filled with Icecast's own source password if
    # it can be read, then never overwritten.
    install -d -m 750 -g iscream /etc/iscream
    if [ ! -f /etc/iscream/iscream.env ]; then
      pw=\$(sed -n 's:.*<source-password>\(.*\)</source-password>.*:\1:p' /etc/icecast2/icecast.xml 2>/dev/null | head -1)
      cat > /etc/iscream/iscream.env <<EOF
PORT=3000
BIND=127.0.0.1
ICECAST_HOST=127.0.0.1
ICECAST_PORT=8000
ICECAST_MOUNT=/reporta.mp3
ICECAST_SOURCE_PASSWORD=\$pw
MP3_BITRATE=128k
CHAT_BRIDGED=0
DEBUG=0
EOF
      chown root:iscream /etc/iscream/iscream.env; chmod 640 /etc/iscream/iscream.env
      [ -n \"\$pw\" ] && echo 'env: source password taken from icecast.xml' || echo 'env: SET ICECAST_SOURCE_PASSWORD in /etc/iscream/iscream.env'
    fi
  "

  # Certificate: serve only the port-80 block until the cert exists.
  if ! remote "test -d /etc/letsencrypt/live/$DOMAIN"; then
    sed '/^server {/,$!d' "$HERE/deploy/nginx/$DOMAIN.conf" | awk '/^server \{/{n++} n==1' \
      | "${SSH[@]}" "$HOST" "cat > /etc/nginx/sites-available/$DOMAIN.conf"
    remote "set -e
      ln -sf /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/$DOMAIN.conf
      nginx -t && systemctl reload nginx
      certbot certonly --webroot -w /var/www/acme -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring"
  fi
  up "$HERE/deploy/ergo/certbot-deploy-hook.sh" "$HOST:/etc/letsencrypt/renewal-hooks/deploy/ergo.sh"
  remote "chmod 755 /etc/letsencrypt/renewal-hooks/deploy/ergo.sh
          RENEWED_LINEAGE=/etc/letsencrypt/live/$DOMAIN /etc/letsencrypt/renewal-hooks/deploy/ergo.sh"
  echo "install done. Next: deploy/deploy.sh push"
  ;;

push)
  FLAGS=(-rlptz --delete --exclude node_modules --exclude '*.env' --exclude .DS_Store)
  [ $DRY = 1 ] && FLAGS+=(-n -i)
  up "${FLAGS[@]}" "$HERE/server.js" "$HERE/package.json" "$HERE/package-lock.json" "$HERE/lib" "$HERE/www" "$HOST:/opt/iscream/"
  if [ $DRY = 1 ]; then echo "(rehearsal: configs and units not shown)"; exit 0; fi

  up "$HERE/deploy/nginx/$DOMAIN.conf" "$HOST:/etc/nginx/sites-available/$DOMAIN.conf.new"
  up "$HERE/deploy/iscream.service" "$HERE/deploy/ergo/ergo.service" "$HERE/deploy/matterbridge/matterbridge.service" "$HOST:/etc/systemd/system/"
  up "$HERE/deploy/ergo/ircd.yaml" "$HERE/deploy/ergo/ircd.motd" "$HOST:/var/lib/ergo/"

  remote "set -e
    # Port 3000 must be free or ours: the 2021 icecream held it for years.
    holder=\$(ss -ltnpH 'sport = :3000' | grep -v 'iscream' | grep -o 'pid=[0-9]*' | head -1 || true)
    if [ -n \"\$holder\" ] && ! systemctl is-active -q iscream; then
      echo \"port 3000 is held by another process (\$holder). Stop the old icecream first (see README).\" >&2; exit 1
    fi
    # --production, not --omit=dev: the server has npm 6 (node 14).
    cd /opt/iscream && npm ci --production --no-audit --silent
    chown -R root:root /opt/iscream
    chown ergo:ergo /var/lib/ergo/ircd.yaml /var/lib/ergo/ircd.motd
    # Ergo resolves tls/ and ircd.db relative to the working directory.
    [ -f /var/lib/ergo/ircd.db ] || (cd /var/lib/ergo && runuser -u ergo -- /opt/ergo/ergo initdb --conf /var/lib/ergo/ircd.yaml)

    # Swap the vhost in only if nginx accepts it.
    cd /etc/nginx/sites-available
    [ -f $DOMAIN.conf ] && cp $DOMAIN.conf $DOMAIN.conf.bak || true
    mv $DOMAIN.conf.new $DOMAIN.conf
    ln -sf /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/$DOMAIN.conf
    if ! nginx -t 2>/dev/null; then
      nginx -t || true
      [ -f $DOMAIN.conf.bak ] && mv $DOMAIN.conf.bak $DOMAIN.conf
      echo 'nginx rejected the vhost; restored the previous one' >&2; exit 1
    fi

    systemctl daemon-reload
    systemctl enable --now ergo iscream
    systemctl restart ergo iscream
    systemctl reload nginx
    systemctl is-active iscream ergo
  "
  ;;

*)
  sed -n '2,12p' "$0"; exit 1 ;;
esac
