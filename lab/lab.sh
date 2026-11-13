#!/usr/bin/env bash
# Lab on Apple Virtualization (vfkit), driven from the Mac. Needs: vfkit, docker.
# Usage: lab.sh [--regen-secrets] iso | up [host...] | install [--force] <host>
#        | deploy <host> | start <host> | stop <host> | ip <host> | ssh <host> [cmd] | smoke [host...]
#        | kubeconfig | destroy <host>
# `up` and `install` never touch a host that already has a lab/state/<host> folder;
# `install --force` erases it. --regen-secrets works with iso, up and install only.
# Bash 3.2 compatible (macOS default).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATE=$ROOT/lab/state
SSHDIR=$ROOT/secrets/ssh
# LAB_KEY points at an existing key and skips key generation.
KEY=${LAB_KEY:-$SSHDIR/id_nix_lab}
SECRETS=${LAB_SECRETS:-$ROOT/secrets}  # gitignored, except woodpecker.yaml
# shortcut: tag not pinned to a digest, pin it (docker image inspect) before publishing.
IMAGE=${LAB_NIX_IMAGE:-nixos/nix}
# Guests on vfkit's plain NAT cannot reach each other; vmnet-helper puts them on one
# shared vmnet network (brew tap nirs/vmnet-helper; no root on macOS 26+).
VMNET_RUN=${VMNET_RUN:-/opt/homebrew/opt/vmnet-helper/libexec/vmnet-run}
HOSTS="gitea woodpecker k8s-01 k8s-02 k8s-03"

# host -> "mac-suffix ip cpus memMiB diskGiB"; suffix and IP match modules/lab-hosts.nix.
spec() {
  case $1 in
    gitea)      echo "10 192.168.64.10 2 2048 20" ;;
    woodpecker) echo "11 192.168.64.11 2 2048 30" ;;
    k8s-01)     echo "20 192.168.64.20 2 4096 20" ;;
    k8s-02)     echo "21 192.168.64.21 2 4096 20" ;;
    k8s-03)     echo "22 192.168.64.22 2 4096 20" ;;
    *) echo "unknown host: $1" >&2; exit 1 ;;
  esac
}
field() { spec "$1" | cut -d' ' -f"$2"; }
mac() { echo "52:54:00:00:00:$(field "$1" 1)"; }
# dhcpd_leases drops leading zeros in each MAC byte. The file is missing until the
# first VM leases an address.
lease_ip() {
  local m; m=$(mac "$1" | sed 's/:0\([0-9a-f]\)/:\1/g')
  awk -v m="$m" '/ip_address=/{split($0,a,"=");ip=a[2]} /hw_address=/{split($0,b,",");if(b[2]==m)last=ip} END{print last}' /var/db/dhcpd_leases 2>/dev/null || true
}
# Host keys and options come from the generated config (lab only: VMs are throwaway).
sshh() { local h=$1; shift; ssh -F "$SSHDIR/config" "root@$h" "$@"; }
pidfile() { echo "$STATE/$1/vfkit.pid"; }
running() { [ -f "$(pidfile "$1")" ] && kill -0 "$(cat "$(pidfile "$1")")" 2>/dev/null; }
wait_ssh() { # ip
  for _ in $(seq 1 60); do sshh "$1" true 2>/dev/null && return 0; sleep 3; done
  echo "timeout: no ssh on $1" >&2; return 1
}
# nixd <script> [extra docker args]: run a script in a Linux container that shares the nix store.
nixd() {
  local script=$1; shift
  docker run --rm -v nix-lab-store:/nix -v "$ROOT":/src -v "$KEY":/key:ro "$@" -w /src "$IMAGE" \
    sh -ec 'install -m600 /key /root/id; git config --global --add safe.directory "*"
            export NIX_CONFIG="experimental-features = nix-command flakes"; '"$script"
}

# Creates the lab SSH key on first use, or again with --regen-secrets, and writes the
# ssh config. Then: ssh -F secrets/ssh/config <host>. A new key means hosts must be reinstalled.
ensure_secrets() {
  mkdir -p "$SSHDIR"; chmod 700 "$SSHDIR"
  if [ -z "${LAB_KEY:-}" ] && { [ "$REGEN" = 1 ] || [ ! -f "$KEY" ]; }; then
    rm -f "$KEY" "$KEY.pub"
    ssh-keygen -q -t ed25519 -N "" -C "nix-lab" -f "$KEY"
    echo "new lab key: installed hosts do not trust it, reinstall them (lab.sh install --force)" >&2
  fi
  [ -f "$KEY.pub" ] || ssh-keygen -y -f "$KEY" >"$KEY.pub"
  # Nix reads only tracked files, so the public key lives in keys/ and the ISO and
  # hosts trust it from there.
  cmp -s "$KEY.pub" "$ROOT/keys/id_nix_lab.pub" || cp "$KEY.pub" "$ROOT/keys/id_nix_lab.pub"
  { for h in $HOSTS; do
      printf 'Host %s\n  HostName %s\n  User root\n' "$h" "$(field "$h" 2)"
    done
    printf 'Host *\n  IdentityFile %s\n  IdentitiesOnly yes\n  StrictHostKeyChecking no\n' "$KEY"
    printf '  UserKnownHostsFile /dev/null\n  LogLevel ERROR\n  ConnectTimeout 3\n'
  } >"$SSHDIR/config"
}

cmd_iso() {
  nixd 'nix build .#nixosConfigurations.installer.config.system.build.isoImage -o /tmp/img
        cp /tmp/img/iso/*.iso /src/lab/lab.iso'
}

# start <host> [iso]: boot from disk, or from the lab ISO when the 2nd argument is "iso".
cmd_start() {
  local h=$1 boot=${2:-disk} d=$STATE/$1
  mkdir -p "$d"
  running "$h" && { echo "$h already running"; return 0; }
  [ -f "$d/disk.raw" ] || truncate -s "$(field "$h" 5)G" "$d/disk.raw"
  local iso=()
  [ "$boot" = iso ] && iso=(--device "usb-mass-storage,path=$ROOT/lab/lab.iso,readonly")
  nohup "$VMNET_RUN" -- vfkit --cpus "$(field "$h" 3)" --memory "$(field "$h" 4)" \
    --bootloader "efi,variable-store=$d/efi,create" \
    ${iso[@]+"${iso[@]}"} \
    --device "virtio-blk,path=$d/disk.raw" \
    --device "virtio-net,fd=4,mac=$(mac "$h")" \
    --device "virtio-serial,logFilePath=$d/console.log" >"$d/vfkit.log" 2>&1 &
  echo $! >"$(pidfile "$h")"
  sleep 1
  running "$h" || { echo "vfkit exited at once:" >&2; cat "$d/vfkit.log" >&2; exit 1; }
}

# stop <host> [ip]: ask the guest to power off so the disk is clean, then wait.
# ip defaults to the static address; the installer ISO uses a DHCP address instead.
cmd_stop() {
  local h=$1 p
  running "$h" || { rm -f "$(pidfile "$h")"; return 0; }
  p=$(cat "$(pidfile "$h")")
  sshh "${2:-$(field "$h" 2)}" poweroff 2>/dev/null || true
  for _ in $(seq 1 15); do kill -0 "$p" 2>/dev/null || break; sleep 2; done
  if kill -0 "$p" 2>/dev/null; then
    kill "$p" || true
    for _ in 1 2 3 4 5; do kill -0 "$p" 2>/dev/null || break; sleep 2; done
  fi
  rm -f "$(pidfile "$h")"
}

cmd_install() { # erases the host's virtual disk, never a real one
  local force=0
  [ "${1:-}" = --force ] && { force=1; shift; }
  local h=$1 ip
  if [ -d "$STATE/$h" ] && [ "$force" = 0 ]; then
    echo "$h already has a VM. Use: lab.sh install --force $h (erases it)" >&2; exit 1
  fi
  cmd_iso
  cmd_stop "$h"; rm -rf "${STATE:?}/$h"
  cmd_start "$h" iso
  echo "waiting for the installer lease..."
  for _ in $(seq 1 60); do ip=$(lease_ip "$h"); [ -n "$ip" ] && break; sleep 2; done
  [ -n "${ip:-}" ] || { echo "no DHCP lease for $h" >&2; exit 1; }
  wait_ssh "$ip"
  local extra="" mnt=()
  # Pre-generated host key (sops decrypts with it at first boot), only if you made one.
  if [ -d "$SECRETS/$h" ]; then extra="--extra-files /secrets --chown /etc/ssh 0:0"; mnt=(-v "$SECRETS/$h":/secrets:ro); fi
  git -C "$ROOT" add -N "hosts/$h" 2>/dev/null || true
  nixd 'nix run --inputs-from . nixos-anywhere -- --flake ".#'"$h"'" \
        --target-host "root@'"$ip"'" -i /root/id --no-reboot '"$extra"' \
        --ssh-option StrictHostKeyChecking=no --ssh-option UserKnownHostsFile=/dev/null \
        --generate-hardware-config nixos-generate-config "./hosts/'"$h"'/hardware-configuration.nix"' \
    ${mnt[@]+"${mnt[@]}"}
  cmd_stop "$h" "$ip"
  cmd_start "$h"           # without the ISO: boots the installed system
  wait_ssh "$(field "$h" 2)"
  echo "$h is up at $(field "$h" 2). Commit hosts/$h/hardware-configuration.nix."
}

# deploy <host>: apply the current flake to a running host, no reinstall (data is kept).
cmd_deploy() {
  local h=$1; field "$h" 1 >/dev/null
  nixd 'export NIX_SSHOPTS="-i /root/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        nix shell --inputs-from . nixpkgs#openssh nixpkgs#nixos-rebuild -c \
          nixos-rebuild switch --flake ".#'"$h"'" --target-host "root@'"$(field "$h" 2)"'"'
}

cmd_up() {
  local h
  # shellcheck disable=SC2048 # host names have no spaces; splitting is wanted
  for h in ${*:-$HOSTS}; do
    if [ -d "$STATE/$h" ]; then echo "skip $h (has a VM; install --force $h to redo it)"; continue; fi
    cmd_install "$h"
  done
}

cmd_ssh() { local h=$1; shift; sshh "$(field "$h" 2)" "$@"; }

# kubeconfig: write secrets/kubeconfig for kubectl on the Mac (token of the mac-admin
# ServiceAccount, created by k8s-bootstrap.sh). Connects by IP and checks the API
# certificate against the master's name, so no /etc/hosts entry is needed.
cmd_kubeconfig() {
  local kc=$ROOT/secrets/kubeconfig ca tok ip; ip=$(field k8s-01 2)
  ca=$(mktemp)
  sshh "$ip" cat /var/lib/kubernetes/secrets/ca.pem >"$ca"
  tok=$(sshh "$ip" 'kubectl -n kube-system get secret mac-admin-token -o jsonpath={.data.token}' | base64 -d)
  [ -n "$tok" ] || { rm -f "$ca"; echo "no mac-admin token: run lab/k8s-bootstrap.sh first" >&2; exit 1; }
  rm -f "$kc"
  KUBECONFIG=$kc kubectl config set-cluster lab --server="https://$ip:6443" \
    --tls-server-name=k8s-01.lab.home.arpa --certificate-authority="$ca" --embed-certs=true >/dev/null
  KUBECONFIG=$kc kubectl config set-credentials mac-admin --token="$tok" >/dev/null
  KUBECONFIG=$kc kubectl config set-context lab --cluster=lab --user=mac-admin >/dev/null
  KUBECONFIG=$kc kubectl config use-context lab >/dev/null
  rm -f "$ca"; chmod 600 "$kc"
  echo "wrote $kc. Use: export KUBECONFIG=$kc"
}

# Each check prints ok/FAIL; the exit code is the number of failures.
cmd_smoke() {
  local fail=0 h ip other
  chk() { local name=$1; shift; if "$@" >/dev/null 2>&1; then echo "ok   $name"; else echo "FAIL $name"; fail=$((fail+1)); fi; }
  # shellcheck disable=SC2048 # host names have no spaces; splitting is wanted
  for h in ${*:-$HOSTS}; do
    ip=$(field "$h" 2)
    chk "$h: ssh"         sshh "$ip" true
    chk "$h: hostname"    test "$(sshh "$ip" hostname)" = "$h"
    chk "$h: systemd ok"  sshh "$ip" 'systemctl is-system-running --wait | grep -qx running'
    chk "$h: dns"         sshh "$ip" 'getent hosts cache.nixos.org'
    for other in $HOSTS; do
      [ "$other" = "$h" ] || ! running "$other" || chk "$h -> $other: ping" sshh "$ip" "ping -c1 -W2 $(field "$other" 2)"
    done
  done
  echo "$fail failed"; return "$fail"
}

cmd_destroy() {
  read -r -p "Type the host name to delete its VM and disk: " a
  [ "$a" = "$1" ] || { echo "aborted"; exit 1; }
  cmd_stop "$1"; rm -rf "${STATE:?}/$1"
}

REGEN=0
[ "${1:-}" = --regen-secrets ] && { REGEN=1; shift; }
c=${1:-}; shift || true
if [ "$REGEN" = 1 ]; then
  case $c in iso|up|install) ;; *) echo "--regen-secrets works with iso, up and install only" >&2; exit 1 ;; esac
fi
case $c in iso|up|install|start|stop|ssh|destroy|smoke|deploy|kubeconfig) ensure_secrets ;; esac
case $c in
  iso) cmd_iso ;;
  install|start|stop|ssh|destroy|up|smoke|deploy|kubeconfig) cmd_"$c" "$@" ;;
  ip) field "$1" 2 ;;
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac
