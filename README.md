# nix-lab

NixOS home lab on a Mac (Apple Silicon, `aarch64-linux`). The VMs run on
[vfkit](https://github.com/crc-org/vfkit) with vmnet-helper. One flake describes
every machine. Scripts in `lab/` create, install and update the VMs.

- Repository: <https://github.com/d3vs3c00ps/nix-lab>
- Notes site (not live yet): <https://d3vs3c00ps.github.io/docs/labs/nixos-homelab/>
- Step by step, with the details and fixes: [RUNBOOK.md](RUNBOOK.md)

| Host | IP | Role |
| --- | --- | --- |
| gitea | 192.168.64.10 | Git server, hosts this repo |
| woodpecker | 192.168.64.11 | CI |
| k8s-01 | 192.168.64.20 | Kubernetes control plane |
| k8s-02, k8s-03 | 192.168.64.21-22 | Kubernetes workers |

Network `192.168.64.0/24`: the Mac and gateway is `.1`, DHCP starts at `.2`.
All five VMs need about 16 GB of RAM.

## Prerequisites

macOS 26 or newer. On older macOS, vmnet-helper needs root.

```bash
brew install vfkit                 # and a docker-compatible runtime (Docker Desktop was used)
brew tap nirs/vmnet-helper && brew trust nirs/vmnet-helper && brew install vmnet-helper
```

Linux builds (nix, nixos-anywhere, nixos-rebuild) run in a `nixos/nix` container
started by `lab/lab.sh`. No Linux build VM is needed.

## Quick start

```bash
./lab/lab.sh up gitea                  # builds the installer ISO, installs and starts gitea
./lab/ci-bootstrap.sh                  # Gitea admin and OAuth app, sops secrets, installs woodpecker
./lab/lab.sh up k8s-01 k8s-02 k8s-03
./lab/k8s-bootstrap.sh                 # joins workers, installs Cilium and CoreDNS
./lab/lab.sh kubeconfig                # secrets/kubeconfig: kubectl from the Mac
git push -u gitea main                 # remote set by ci-bootstrap
./lab/lab.sh smoke                     # ssh, hostname, systemd, DNS, ping between hosts
```

`secrets/` is gitignored (only `secrets/woodpecker.yaml` is tracked). Back it up.
Commit the new `hosts/*/hardware-configuration.nix`, `.sops.yaml` and
`secrets/woodpecker.yaml`. Add the lab names to `/etc/hosts` on the Mac
(RUNBOOK, section 0). New files must be `git add`ed, or the flake does not see
them.

`./lab/lab.sh` also has `deploy`, `start`, `stop`, `ssh`, `destroy` and more.
Run it without arguments for the list.
