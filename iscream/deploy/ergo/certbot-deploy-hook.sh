#!/bin/sh
# /etc/letsencrypt/renewal-hooks/deploy/ergo.sh
# Hand the renewed reporta.altred.xyz certificate to Ergo (port 6697) and
# have it reload without dropping anyone.
set -e
case "$RENEWED_LINEAGE" in */reporta.altred.xyz) ;; *) exit 0 ;; esac
install -d -o ergo -g ergo -m 700 /var/lib/ergo/tls
install -o ergo -g ergo -m 600 "$RENEWED_LINEAGE/fullchain.pem" /var/lib/ergo/tls/fullchain.pem
install -o ergo -g ergo -m 600 "$RENEWED_LINEAGE/privkey.pem"   /var/lib/ergo/tls/privkey.pem
systemctl reload ergo || true
