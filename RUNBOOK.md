# nix-lab runbook

How to rebuild the whole lab from nothing. The lab runs on one Mac, with VMs on
vfkit. Scripts in `lab/` do the work. Verified on vfkit: all five hosts install,
the smoke test passes, Woodpecker server and agent run with sops secrets and
reach Gitea, three Kubernetes nodes are Ready, all pods run, pod DNS works.
Anything marked "not re-tested on vfkit" has not been run on this setup yet.

## The model in one paragraph

This repository is the lab. Every machine is an output in `flake.nix`. `lab/lab.sh`
starts a VM on a generic **lab installer ISO** (a live NixOS in RAM, with SSH and
your key). **nixos-anywhere** partitions the disk (disko) and installs the host
from the flake. After that, `lab.sh deploy` updates a host with
`nixos-rebuild switch`. Nothing is configured by hand on a machine. All Linux
tools run in a `nixos/nix` container on the Mac, with a named volume
`nix-lab-store` as the Nix store. There is no build VM.

## Machines

| Host | IP | MAC | vCPU / RAM / disk | Role |
| --- | --- | --- | --- | --- |
| gitea | 192.168.64.10 | 52:54:00:00:00:10 | 2 / 2 GB / 20 GB | Git server |
| woodpecker | 192.168.64.11 | 52:54:00:00:00:11 | 2 / 2 GB / 30 GB | CI, pre-generated host key |
| k8s-01 | 192.168.64.20 | 52:54:00:00:00:20 | 2 / 4 GB / 20 GB | Kubernetes control plane |
| k8s-02 | 192.168.64.21 | 52:54:00:00:00:21 | 2 / 4 GB / 20 GB | Kubernetes worker |
| k8s-03 | 192.168.64.22 | 52:54:00:00:00:22 | 2 / 4 GB / 20 GB | Kubernetes worker |

All five need about 16 GB of RAM.
Network: one vmnet network, `192.168.64.0/24`. The Mac and gateway is `.1`. DHCP
leases start at `.2`. The servers have static IPs and fixed MACs. The disk is
`/dev/vda` (virtio). `modules/server.nix` matches the NIC by type in
systemd-networkd, so there is no interface name option.

**The IP plan is in three places that must agree:** `spec()` in `lab/lab.sh`,
`modules/lab-hosts.nix`, and `lab.server.address` in `hosts/*/default.nix`.

### Why vmnet-helper

With vfkit's plain `virtio-net,nat`, each VM is isolated: guests could not reach
each other (ARP failed). `lab.sh` starts each VM as
`vmnet-run -- vfkit ... --device virtio-net,fd=4,mac=<mac>`. All VMs then share
one vmnet network.

## Repository layout

```text
flake.nix               hosts list; mkHost adds disko + common modules to each host
flake.lock              pinned nixpkgs, disko, sops-nix, nixos-anywhere
.sops.yaml              who can decrypt which secrets file (public age keys)
secrets/woodpecker.yaml sops-encrypted, safe to commit
secrets/ssh/            generated SSH key and config (gitignored)
.woodpecker.yaml        CI pipeline
keys/id_nix_lab.pub     the only key in the repo (public)
lab/                    lab.sh, ci-bootstrap.sh, k8s-bootstrap.sh; lab.iso and state/ are gitignored
k8s/                    Helm values for Cilium and CoreDNS
modules/common.nix      every installed host: flakes, gc, key-only SSH, base tools
modules/lab-hosts.nix   IP plan -> /etc/hosts
modules/server.nix      headless servers: static IP, public DNS, root SSH by key
modules/disk-vm.nix     disko layout: GPT, 512M ESP, ext4 root on /dev/vda
hosts/<name>/           one folder per machine
```

## 0. On the Mac

Prerequisites (Apple Silicon, macOS 26 or newer):

```bash
brew install vfkit                 # plus a docker-compatible runtime (Docker Desktop was used)
brew tap nirs/vmnet-helper && brew install vmnet-helper
```

vmnet-helper needs no root on macOS 26 or newer. Older macOS needs root.

### SSH key

On first use, `lab.sh` creates an ed25519 key in `secrets/ssh/id_nix_lab` (plus
`.pub` and a generated `secrets/ssh/config`). All are gitignored. It copies the
public key to the tracked `keys/id_nix_lab.pub`, because Nix reads only tracked
files. A **new key means the ISO and every host must be rebuilt and reinstalled**:
installed hosts do not trust it. `LAB_KEY=/path` uses an existing key instead.

```bash
ssh -F secrets/ssh/config <host>     # root; no host-key prompts (lab only)
./lab/lab.sh ssh <host> [cmd]        # same, shorter
```

### Lab names

**Required** for the Woodpecker login, which redirects the browser between the two
names. Add to `/etc/hosts` on the Mac:

```text
192.168.64.10  gitea gitea.lab.home.arpa
192.168.64.11  woodpecker woodpecker.lab.home.arpa
```

### Secrets to back up, outside the repo

The `secrets/` folder is gitignored, except `secrets/woodpecker.yaml`
(encrypted). **Git does not save it, so back it up.** `LAB_SECRETS` overrides the
folder (default `<repo>/secrets`). It holds:

| File | Lost means |
| --- | --- |
| `ssh/id_nix_lab`, `ssh/id_nix_lab.pub`, `ssh/config` | New key and a reinstall of all hosts |
| `woodpecker/etc/ssh/ssh_host_ed25519_key` (+ `.pub`) | A reinstalled woodpecker gets a new identity; re-encrypt its secrets |
| `sops-age/keys.txt` | You can no longer edit any secret (sops admin key) |
| `gitea/admin-password` | You must reset the Gitea admin password |

Copy it to a password manager or an encrypted disk.

## 1. Lab installer ISO

One ISO installs every server. `lab.sh install` builds it in the container when
needed (cached). To build it alone:

```bash
./lab/lab.sh iso                  # writes lab/lab.iso (gitignored)
```

It contains: NixOS minimal installer, aarch64, flakes on, sshd on, root login
**by key only** with `keys/id_nix_lab.pub`, no ZFS. `--regen-secrets` (with `iso`,
`up` or `install` only) regenerates the generated secrets.

## 2. Install servers

```bash
./lab/lab.sh up gitea                 # install and start; several: up k8s-01 k8s-02 k8s-03
./lab/lab.sh install [--force] <host> # one host
```

- `up` and `install` **never touch a host that already has a `lab/state/<host>`
  folder**. `install --force` **erases** it and the VM disk.
- VM state (disk, EFI variable store, `console.log`, `vfkit.log`, pid) is in
  `lab/state/<host>/`, gitignored.

What `install` does:

1. Builds the ISO in the container.
2. Boots the VM on the ISO with a blank sparse disk. The ISO is attached
   read-only: two vfkit processes cannot open the same writable disk or ISO.
3. Finds the VM's DHCP lease in `/var/db/dhcpd_leases`, by MAC.
4. Runs nixos-anywhere (pinned by the flake input, `nix run --inputs-from .
   nixos-anywhere`) with `--no-reboot`. If `$LAB_SECRETS/<host>` exists, it is
   copied to the new root with `--extra-files` (`chown /etc/ssh 0:0`). This is how
   woodpecker gets its host key.
5. Powers the VM off, restarts it from the disk, waits for SSH on the static IP.

It regenerates `hosts/<host>/hardware-configuration.nix` on the Mac. **Commit it**:
a reinstall gives new disk UUIDs.

A new host needs, before the install:

- `hosts/<name>/default.nix` importing `./hardware-configuration.nix`,
  `../../modules/server.nix`, `../../modules/disk-vm.nix`, and setting
  `networking.hostName`, `lab.server.address`, `system.stateVersion`;
- an empty `hosts/<name>/hardware-configuration.nix` (`{ }`);
- a line `<name> = mkHost "<name>";` in `flake.nix`;
- an entry in `spec()` in `lab/lab.sh` and in `modules/lab-hosts.nix`;
- `git add` (the flake sees only tracked files).

Other commands:

```bash
./lab/lab.sh start|stop|ip|ssh|destroy <host>
```

`stop` powers the guest off over SSH and waits, then falls back to kill (the kill
fallback is not re-tested on vfkit).

## 3. Gitea

Gitea runs on `http://gitea.lab.home.arpa:3000/` (or `http://192.168.64.10:3000/`),
with SQLite in `/var/lib/gitea`. Registration is off.

The admin account `lab_admin` is created by `lab/ci-bootstrap.sh` (section 8),
with a random password in `secrets/gitea/admin-password`. To do it by hand:

```bash
./lab/lab.sh ssh gitea
sudo -u gitea gitea --config /var/lib/gitea/custom/conf/app.ini \
  admin user create --admin --username lab_admin \
  --email lab_admin@lab.home.arpa --random-password
```

`sudo -u gitea` matters: Gitea refuses to run as root.

### Push this repository

`ci-bootstrap.sh` also adds `secrets/ssh/id_nix_lab.pub` as an SSH key of
`lab_admin` (Gitea API), creates the empty repository `lab_admin/nix-lab`, sets
the git remote `gitea` (`gitea@192.168.64.10:lab_admin/nix-lab.git`) and runs
`git config core.sshCommand "ssh -F <repo>/secrets/ssh/config"`. Then:

```bash
git push -u gitea main
```

Checked on vfkit: the key logs in, and pushing and deleting a test branch works. A push of
`main` was not run. From now on Gitea is the source of truth. Keep secrets out of the
repository.

## 4. Daily workflow

```bash
git add -A                 # new files must be added, or the flake ignores them
git commit -m "feat(gitea): ..."
git push gitea main        # Woodpecker runs 'nix flake check' and builds the five lab hosts
./lab/lab.sh deploy gitea  # apply to a running host
```

## 5. Update a server

```bash
./lab/lab.sh deploy <host>
```

It runs `nixos-rebuild switch` in the container against the running host. Data is
kept. The server needs no compiler and no copy of the repository.

## 6. Roll back

```bash
./lab/lab.sh ssh <host> nixos-rebuild switch --rollback
./lab/lab.sh ssh <host> nixos-rebuild list-generations   # or pick one in the boot menu
```

## 7. Update nixpkgs

Needs Nix, so run it in the container (not re-tested on vfkit):

```bash
docker run --rm -v "$PWD":/w -w /w nixos/nix \
  nix --extra-experimental-features 'nix-command flakes' flake update
```

Commit `flake.lock`, then `deploy` each host. `system.stateVersion` never changes
with an update.

## 8. Woodpecker

Woodpecker server and one agent on the same VM. The agent uses the **local**
backend: pipeline steps are shell commands on that host, so they call `nix`
directly. Login goes through Gitea (OAuth). `.woodpecker.yaml` runs
`nix flake check` and builds the five lab hosts.

Secrets (OAuth client, agent secret) are in `secrets/woodpecker.yaml`, encrypted
with **sops-nix**. The host decrypts them at boot with its SSH host key, into
`/run/secrets` (RAM). That key is generated **before** the install, so the secrets
can be encrypted for a machine that does not exist yet.

```bash
./lab/lab.sh up gitea
./lab/ci-bootstrap.sh [--regen]
```

`ci-bootstrap.sh` does all of this:

1. Creates the Gitea admin `lab_admin` (random password into
   `secrets/gitea/admin-password`) with the gitea CLI over SSH.
2. Creates the Woodpecker OAuth2 app through the Gitea API (redirect
   `http://woodpecker.lab.home.arpa:8000/authorize`).
3. Generates the woodpecker host key and the sops admin age key.
4. Writes `.sops.yaml` and `secrets/woodpecker.yaml` in a container, encrypted for
   the admin key and the host key, and checks that the host key decrypts it. It
   runs `git add` but does not commit.
5. Installs woodpecker with the host key (`--extra-files`), then runs the smoke
   test.

It refuses to run if `secrets/woodpecker.yaml` exists, unless `--regen`. Then
commit `.sops.yaml` and `secrets/woodpecker.yaml`, and add the lab names to
`/etc/hosts` (section 0).

To change a secret later: `sops secrets/woodpecker.yaml` (admin key in
`secrets/sops-age/keys.txt`), commit, then `./lab/lab.sh deploy woodpecker`.

### Login and pipeline

Verified on vfkit: server and agent are active with decrypted secrets, woodpecker
reaches Gitea (HTTP 200), and the Mac reaches `woodpecker:8000` (204). **A real
login and pipeline run is not re-tested on vfkit.** The steps:

1. Open `http://woodpecker.lab.home.arpa:8000/`, **Login**, then **Authorize
   Application** in Gitea. `WOODPECKER_ADMIN` makes that account admin.
2. **Add repository** (`+`), enable `lab_admin/nix-lab`. Woodpecker creates the
   webhook in Gitea; Gitea accepts it because of `security.ALLOWED_HOST_LIST` in `hosts/gitea/default.nix`.
3. Push any commit. The status appears on the commit in Gitea and in the
   Woodpecker UI.

### Known quirks

- The agent runs in a systemd sandbox with no home. Pipeline steps set
  `HOME="$CI_WORKSPACE/.ci-home"` for Nix's cache.
- The agent ID is kept in `/var/lib/woodpecker-agent-local/agent.conf`
  (`WOODPECKER_AGENT_CONFIG_FILE`); without it, each restart registers a new agent.
- The hardware clock is UTC, the default.

## 9. Smoke test

```bash
./lab/lab.sh smoke [host...]
```

Per host: SSH, hostname, `systemctl is-system-running`, DNS, and ping to every
other running host. The exit code is the number of failures.

## 10. Kubernetes

`services.kubernetes` (Kubernetes 1.36) with **Cilium** as the network plugin
instead of the module's default, flannel. Everything node-side is in
`modules/k8s.nix`; each host only sets `lab.k8s.role` (`master` or `node`).
Cilium itself is installed with Helm, from `k8s/cilium-values.yaml`.

| Host | Role |
| --- | --- |
| k8s-01 | Control plane: API server, etcd, scheduler, controller manager, cfssl (certificates). Also runs a kubelet, tainted so normal pods avoid it |
| k8s-02, k8s-03 | Workers |

### 10.1 Install and bootstrap

```bash
./lab/lab.sh up k8s-01 k8s-02 k8s-03
./lab/k8s-bootstrap.sh
```

Right after the install, `kubelet` and `kube-proxy` on k8s-02 and k8s-03 stay in
**activating**: they wait for certificates, which they get only after the join.
`k8s-bootstrap.sh` is idempotent. It runs remote commands with `set -e` and:

1. Joins the workers. The master's cfssl service signs their certificates once they
   present its API token. The token is piped from k8s-01 to
   `nixos-kubernetes-node-join` on each worker and never printed.
2. Runs `helm upgrade --install` for Cilium 1.20.2 and CoreDNS 1.48.2 on k8s-01
   (`kubectl`, `helm` and `cilium` are installed there, `KUBECONFIG` points to the
   cluster-admin kubeconfig). The NixOS DNS addon is disabled (see 10.8).
3. Waits for all nodes Ready. Until Cilium runs they are `NotReady`: expected.
4. Runs a busybox pod on k8s-02 that resolves `kubernetes.default.svc.cluster.local`.

Verified on vfkit: 3 nodes Ready, all 10 pods Running, pod DNS (cluster and
external) works.

### 10.2 Check the pod network

`Ready` is not proof; step 4 above is the minimal test. CoreDNS (Helm) listens on
53, like the `kube-dns` Service. With the old NixOS addon it was 10053, and a pod
IP tested on 53 answered "connection refused".

### 10.3 Cilium connectivity test

Checked on vfkit (Cilium 1.20.2, 3 nodes, no kube-proxy): `cilium connectivity test` on
k8s-01 passes: **all 82 tests (708 actions) successful, 48 skipped by design**. Hubble flow
validation was off, because the CLI cannot reach Hubble Relay without a port-forward. The run
time was not measured. Run a subset with `--test name1,name2`. How the suite got there, from the
earlier runs that found the problems:

| Setup | Result | Cause of the failures |
| --- | --- | --- |
| kube-proxy, certmgr loop | 35 of 82 failed | API server and kube-proxy restarted every 30 min (10.6) |
| kube-proxy, loop fixed | 78 of 82 | FQDN/L7 proxy tests: NixOS reverse-path filter (10.9) |
| no kube-proxy, CoreDNS on 10053 | DNS policies broken | Cilium sees the pod port 10053, policies say 53 (10.8) |
| no kube-proxy, CoreDNS 53, rpfilter off | all 9 previously failing tests pass | |
| same, full suite | **all 82 pass** (708 actions), 48 skipped by design | |

The test leaves its three namespaces behind. Delete them after each run. A failed
run can also leave policies such as `client-egress-only-dns`, which make the next run hang:

```bash
kubectl delete ns cilium-test-1 cilium-test-ccnp1 cilium-test-ccnp2 --ignore-not-found
```

### 10.4 Why the module needed changes for Cilium

| Problem | Fix in `modules/k8s.nix` |
| --- | --- |
| NixOS links `/etc/cni/net.d` to the read-only store; Cilium writes its config there | `kubelet.cni.configDir = "/var/lib/cni/net.d"`; Helm `cni.confPath` the same |
| The kubelet empties `/opt/cni/bin` at each start, deleting `cilium-cni` | Helm `cni.binPath = /var/lib/cni/bin`; a line appended to the kubelet's `preStart` links it back |
| API server rejects privileged pods: `DaemonSet "cilium" is invalid: ... privileged: Forbidden: disallowed by cluster policy` | `apiserver.allowPrivileged = true` |
| Cilium's default pod range `10.0.0.0/8` overlaps the service range `10.0.0.0/24` | Helm `ipam.mode: kubernetes`: pods use each node's `10.1.x.0/24` |
| Cilium replaces kube-proxy | `proxy.enable = false`; Helm `kubeProxyReplacement: true` with `k8sServiceHost`/`k8sServicePort` (see 10.7) |
| The module opens only flannel's ports | Firewall: 6443, 8888 (master); 10250, 4240, 4244, 8472/udp (all) |
| NixOS reverse-path filter drops the answers to Cilium's proxies (DNS proxy, Envoy) | `networking.firewall.checkReversePath = false` (see 10.9) |
| NixOS CoreDNS addon listens on 10053; without kube-proxy, DNS policies on 53 never match | Addon off, CoreDNS from Helm on 53 (see 10.8) |
| `/etc/resolv.conf` is the `127.0.0.53` stub (networkd turns on systemd-resolved); CoreDNS pods inherit it and exit with `Loop detected` | `kubelet.extraConfig.resolvConf = "/run/systemd/resolve/resolv.conf"` (see Troubleshooting) |
| certmgr reissues every client certificate every 30 min (`spec DNS name has changed`) and restarts the API server, kube-proxy and kubelet each time — about a minute without API server | `services.certmgr.specs.<cert>.request` rebuilt without identity names such as `system:node:k8s-01` in `hosts` (see 10.6) |

If the Helm install already failed once, `helm upgrade` with the same arguments
completes it after the fix.

### 10.5 kubectl from the Mac

The admin kubeconfig points to certificate files and a private key on k8s-01.
Instead of copying them, the Mac gets its **own identity**: a ServiceAccount
`mac-admin` bound to `cluster-admin`, with a token. Delete the token and it is
dead; the cluster's keys are never copied. `k8s-bootstrap.sh` creates the
ServiceAccount. It needs `kubectl` on the Mac.

```bash
./lab/lab.sh kubeconfig                  # writes secrets/kubeconfig (gitignored)
export KUBECONFIG="$PWD/secrets/kubeconfig"
kubectl get nodes
```

The file connects to `192.168.64.20` and checks the API server certificate against
the name `k8s-01.lab.home.arpa` (`tls-server-name`), so the Mac needs no extra
`/etc/hosts` line. Run `kubeconfig` again to refresh it.

Revoke: `./lab/lab.sh ssh k8s-01 kubectl -n kube-system delete secret mac-admin-token`.

### 10.6 Check certmgr is quiet

The module puts each certificate's CN into its host list. For client
certificates the CN is an identity (`system:node:k8s-01`), which cfssl drops;
certmgr 3 then sees the names differ at every check and reissues. Symptoms:
`kubectl` fails for about a minute every 30 minutes with
`dial tcp 192.168.64.20:6443: connect: connection refused`, and the certmgr log
shows `needs refresh: spec DNS name has changed` again and again.

After the fix, force a check and count the refreshes:

```bash
./lab/lab.sh ssh k8s-01
t=$(date +%H:%M:%S); systemctl restart certmgr; sleep 25
journalctl -u certmgr --since $t -o cat | grep -c "needs refresh"     # 0
```

Real expiry renewals (72 h before the end) still happen; only the loop is gone.

### 10.7 Cilium replaces kube-proxy

Current state: **no kube-proxy**. Cilium's eBPF handles ClusterIP, NodePort and
host ports. On a fresh install this needs no extra step: `modules/k8s.nix` has
`proxy.enable = false` and the Helm values have `kubeProxyReplacement: true`.

Migrating a cluster that already runs kube-proxy, in this order:

1. Helm values: `kubeProxyReplacement: true`, plus `k8sServiceHost` and
   `k8sServicePort` pointing at the API server. Without kube-proxy, the
   `kubernetes` Service IP only works once Cilium runs, so Cilium cannot use it
   to reach the API server. Deploy k8s-01 (the values file), then:

   ```bash
   helm upgrade cilium cilium/cilium -n kube-system --version 1.20.2 -f /etc/cilium/values.yaml
   kubectl -n kube-system rollout restart ds/cilium deploy/cilium-operator
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep KubeProxyReplacement
   # KubeProxyReplacement: True
   ```

   kube-proxy still runs at this point; both coexist, and services keep working.

2. On each node: stop kube-proxy and remove its iptables rules. Stopping alone
   leaves them in place:

   ```bash
   kp=$(systemctl show kube-proxy -p ExecStart | grep -oE "/nix/store/[^ ;]+/bin/kube-proxy" | head -1)
   systemctl stop kube-proxy
   $kp --cleanup
   iptables-save | grep -c KUBE        # 83 -> 8
   ```

   The 8 left are the kubelet's own chains (`KUBE-FIREWALL`,
   `KUBE-KUBELET-CANARY`, `KUBE-IPTABLES-HINT`). No `KUBE-SERVICES` or
   `KUBE-SVC-*` may remain.

3. Deploy the node with `proxy.enable = false`.

Check from a pod: DNS through `10.0.0.254`, a ClusterIP TCP port, the
`kubernetes` Service (`10.0.0.1:443`), and an external site.

### 10.8 CoreDNS from Helm

The NixOS DNS addon runs CoreDNS on port 10053 in the pod (hard-coded in the
module). With kube-proxy, a policy saw the Service port 53. Without it, Cilium
translates the Service address in the socket **before** the policy check, sees
10053, and a DNS rule on port 53 never matches:

```text
xx drop (Policy denied) ... 10.1.2.76:38555 -> 10.1.2.70:10053 udp
```

So `services.kubernetes.addons.dns.enable = false`, `kubelet.clusterDns` stays
`10.0.0.254`, and the CoreDNS chart serves that address on 53 with the same name
(`kube-dns`) and label (`k8s-app: kube-dns`). Values: `k8s/coredns-values.yaml`.
The chart only adds TCP 53 when `use_tcp: true` is set **inside the zone entry**.

Switching a running cluster: the addon manager does **not** delete the old
objects when the addon is disabled. Delete them, then install (about 40 s
without DNS):

```bash
kubectl -n kube-system delete deploy/coredns svc/kube-dns cm/coredns sa/coredns
kubectl delete clusterrole/system:coredns clusterrolebinding/system:coredns
helm install coredns coredns/coredns -n kube-system --version 1.48.2 -f /etc/coredns/values.yaml
```

### 10.9 NixOS reverse-path filter and Cilium proxies

Symptom: any policy that sends traffic through a Cilium proxy fails, while plain
traffic works. FQDN policies (DNS proxy) and L7 policies (Envoy):

```text
dns-proxy: Timeout waiting for response to forwarded proxied DNS lookup
curl: (28) SSL connection timeout
```

Cause: the NixOS firewall's reverse-path filter, in the `mangle` table with
`-m rpfilter --loose --validmark`. Answers to Cilium's transparent proxies carry
mark `0x200`, which routes to table 2004, where everything is local; checked
with that mark, an outside source looks spoofed and is dropped. Counters showed
it on the workers:

```bash
iptables -t mangle -L nixos-fw-rpfilter -v -n -x    # DROP: 2072 packets on k8s-02
```

Fix in `modules/k8s.nix`: `networking.firewall.checkReversePath = false`.
Cilium sets `rp_filter` on its own interfaces.

Before finding this, turning off the DNS proxy's transparent mode
(`dnsProxy.enableTransparentMode: false`) made FQDN policies work, but Envoy
policies still failed. That was a workaround for one symptom, now removed.

## 11. Troubleshooting

- **VMs cannot reach each other (ARP fails).** Plain vfkit `nat` isolates guests.
  Use vmnet-helper, as `lab.sh` does.
- **CoreDNS pods exit with `Loop detected`.** networkd turns on systemd-resolved,
  so `/etc/resolv.conf` is the `127.0.0.53` stub and the pods inherit it. Fixed by
  `kubelet.extraConfig.resolvConf = "/run/systemd/resolve/resolv.conf"` in
  `modules/k8s.nix`. After changing it:
  `kubectl -n kube-system rollout restart deploy/coredns deploy/hubble-relay`.
- **`storage device attachment is invalid`.** Two vfkit processes cannot open the
  same writable disk or ISO. The ISO is attached read-only. Look for a second
  VM process on the same `lab/state/<host>`.
- **SSH refuses a host after a key change.** Installed hosts trust only the key
  they were built with. A new key means reinstalling (`install --force`).
- **`up` or `install` does nothing for a host.** Its `lab/state/<host>` folder
  exists. Use `start`, or `install --force` to erase it.
- **A new file is ignored by the build.** `git add` it. The flake sees only
  tracked files.
