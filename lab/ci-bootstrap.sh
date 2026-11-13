#!/usr/bin/env bash
# Sets up Woodpecker CI from nothing, after `lab.sh up gitea`:
#   1. admin user lab_admin, its SSH key, the nix-lab repository and the `gitea` git remote,
#      and the Woodpecker OAuth app in Gitea (through its CLI and API)
#   2. a fresh host key and sops admin key, kept in secrets/ (gitignored)
#   3. secrets/woodpecker.yaml, encrypted for both keys, and .sops.yaml
#   4. `lab.sh up woodpecker`, which sends the host key so sops can decrypt at boot
# Usage: ci-bootstrap.sh [--regen]   --regen replaces the keys, the OAuth app and the secrets.
# Needs: docker, curl, python3. Bash 3.2 compatible.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SECRETS=${LAB_SECRETS:-$ROOT/secrets}  # gitignored, except woodpecker.yaml
IMAGE=${LAB_NIX_IMAGE:-nixos/nix}
GITEA=192.168.64.10
USER_NAME=lab_admin # must match WOODPECKER_ADMIN in hosts/woodpecker/default.nix
REDIRECT=http://woodpecker.lab.home.arpa:8000/authorize
PWFILE=$SECRETS/gitea/admin-password
REGEN=0; [ "${1:-}" = --regen ] && REGEN=1

lab() { "$ROOT/lab/lab.sh" "$@"; }
api() { # api METHOD PATH [json]
  curl -fsS -u "$USER_NAME:$(cat "$PWFILE")" -X "$1" -H 'Content-Type: application/json' \
    ${3:+-d "$3"} "http://$GITEA:3000/api/v1$2"
}
json() { python3 -c "import sys,json;d=json.load(sys.stdin);$1"; }

if [ -f "$ROOT/secrets/woodpecker.yaml" ] && [ "$REGEN" = 0 ]; then
  echo "secrets/woodpecker.yaml exists. Use --regen to replace it." >&2; exit 1
fi

echo "== Gitea: wait, admin user"
for _ in $(seq 1 30); do curl -fs "http://$GITEA:3000/api/v1/version" >/dev/null && break; sleep 2; done
curl -fs "http://$GITEA:3000/api/v1/version" >/dev/null || { echo "Gitea is not answering on $GITEA:3000" >&2; exit 1; }
gitea_cli() { lab ssh gitea "sudo -u gitea gitea --config /var/lib/gitea/custom/conf/app.ini $*"; }
if gitea_cli admin user list | awk 'NR>1{print $2}' | grep -qx "$USER_NAME"; then
  [ -f "$PWFILE" ] || { echo "user $USER_NAME exists but $PWFILE is missing: reset it with gitea admin user change-password" >&2; exit 1; }
else
  mkdir -p "$(dirname "$PWFILE")"; chmod 700 "$SECRETS" "$(dirname "$PWFILE")"
  head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$PWFILE"; chmod 600 "$PWFILE"
  gitea_cli admin user create --admin --username "$USER_NAME" --email "$USER_NAME@lab.home.arpa" \
    --password "$(cat "$PWFILE")" --must-change-password=false
fi

echo "== Gitea: SSH key and the nix-lab repository (so git push works)"
PUBKEY=${LAB_KEY:-$ROOT/secrets/ssh/id_nix_lab}.pub
for id in $(api GET /user/keys | json "print(' '.join(str(k['id']) for k in d if k['title']=='nix-lab'))"); do
  api DELETE "/user/keys/$id" >/dev/null
done
api POST /user/keys "$(python3 -c 'import json,sys;print(json.dumps({"title":"nix-lab","key":open(sys.argv[1]).read().strip()}))' "$PUBKEY")" >/dev/null
api GET "/repos/$USER_NAME/nix-lab" >/dev/null 2>&1 || api POST /user/repos '{"name":"nix-lab"}' >/dev/null
REMOTE="gitea@$GITEA:$USER_NAME/nix-lab.git"
git -C "$ROOT" remote set-url gitea "$REMOTE" 2>/dev/null || git -C "$ROOT" remote add gitea "$REMOTE"
git -C "$ROOT" config core.sshCommand "ssh -F $ROOT/secrets/ssh/config"

echo "== Gitea: OAuth app (replaces an old one named Woodpecker)"
for id in $(api GET /user/applications/oauth2 | json "print(' '.join(str(a['id']) for a in d if a['name']=='Woodpecker'))"); do
  api DELETE "/user/applications/oauth2/$id" >/dev/null
done
app=$(api POST /user/applications/oauth2 "{\"name\":\"Woodpecker\",\"redirect_uris\":[\"$REDIRECT\"],\"confidential_client\":true}")
WP_CLIENT=$(echo "$app" | json "print(d['client_id'])")
WP_CSECRET=$(echo "$app" | json "print(d['client_secret'])")

echo "== keys and encrypted secrets (in a container; plain text never touches the Mac's disk)"
[ "$REGEN" = 1 ] && rm -rf "$SECRETS/woodpecker" "$SECRETS/sops-age"
mkdir -p "$SECRETS" "$ROOT/secrets"; chmod 700 "$SECRETS"
# shellcheck disable=SC2016 # the variables are expanded inside the container, not here
INNER='set -e
HK=/lab-secrets/woodpecker/etc/ssh/ssh_host_ed25519_key; AGE=/lab-secrets/sops-age/keys.txt
mkdir -p /lab-secrets/woodpecker/etc/ssh /lab-secrets/sops-age
[ -f $AGE ] || age-keygen -o $AGE 2>/dev/null
[ -f $HK ] || ssh-keygen -q -t ed25519 -N "" -C root@woodpecker -f $HK
cat >/src/.sops.yaml <<EOS
# Who can decrypt which secrets file. Recipients are public age keys.
#   admin:      secrets/sops-age/keys.txt (edits secrets), gitignored, never committed
#   woodpecker: derived from the host SSH key (ssh-to-age), decrypts at boot
keys:
  - &admin $(age-keygen -y $AGE)
  - &woodpecker $(ssh-to-age < $HK.pub)
creation_rules:
  - path_regex: secrets/woodpecker\.yaml\$
    key_groups:
      - age: [ *admin, *woodpecker ]
EOS
AGENT=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n")
cat >/tmp/plain.yaml <<EOS
server_env: |
  WOODPECKER_AGENT_SECRET=$AGENT
  WOODPECKER_GITEA_CLIENT=$WP_CLIENT
  WOODPECKER_GITEA_SECRET=$WP_CSECRET
agent_env: |
  WOODPECKER_AGENT_SECRET=$AGENT
EOS
cd /src
sops --encrypt --filename-override secrets/woodpecker.yaml --input-type yaml --output-type yaml /tmp/plain.yaml >secrets/woodpecker.yaml
# The host key must decrypt it, as the VM will at boot.
SOPS_AGE_KEY=$(ssh-to-age -private-key -i $HK) SOPS_AGE_KEY_FILE=/dev/null sops -d secrets/woodpecker.yaml >/dev/null
echo "secrets/woodpecker.yaml encrypted and verified"'
docker run --rm -v nix-lab-store:/nix -v "$ROOT":/src -v "$SECRETS":/lab-secrets -w /src \
  -e INNER="$INNER" -e WP_CLIENT="$WP_CLIENT" -e WP_CSECRET="$WP_CSECRET" "$IMAGE" \
  sh -ec 'export NIX_CONFIG="experimental-features = nix-command flakes"
          nix shell nixpkgs#age nixpkgs#sops nixpkgs#ssh-to-age nixpkgs#openssh -c sh -ec "$INNER"'
# Nix reads only tracked files.
git -C "$ROOT" add .sops.yaml secrets/woodpecker.yaml

echo "== install woodpecker"
if [ "$REGEN" = 1 ]; then lab install --force woodpecker; else lab up woodpecker; fi
lab smoke woodpecker
cat <<EOM

Done. On the Mac, add to /etc/hosts (needs sudo; Woodpecker's login redirects between names):
  $GITEA  gitea gitea.lab.home.arpa
  192.168.64.11  woodpecker woodpecker.lab.home.arpa
Gitea:      http://gitea.lab.home.arpa:3000   user $USER_NAME, password in $PWFILE
Woodpecker: http://woodpecker.lab.home.arpa:8000
Commit .sops.yaml and secrets/woodpecker.yaml, then: git push -u gitea main
Back up $SECRETS (host key, sops admin key, Gitea password): it is gitignored.
EOM
