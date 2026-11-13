# Kubernetes with services.kubernetes, Cilium as CNI instead of flannel.
# Cilium itself is installed with Helm from k8s/cilium-values.yaml; this module
# prepares the nodes for it.
{ config, lib, pkgs, ... }:
let
  cfg = config.lab.k8s;
  master = "k8s-01.lab.home.arpa";
in
{
  options.lab.k8s.role = lib.mkOption {
    type = lib.types.enum [ "master" "node" ];
    description = "master runs the control plane (and an unschedulable kubelet); node runs workloads.";
  };

  config = lib.mkMerge [
    {
      services.kubernetes = {
        roles = [ cfg.role ];
        masterAddress = master;
        apiserverAddress = "https://${master}:6443";
        easyCerts = true;
        flannel.enable = false;
        # Cilium replaces kube-proxy (kubeProxyReplacement in k8s/cilium-values.yaml).
        proxy.enable = false;

        # CoreDNS comes from Helm (k8s/coredns-values.yaml), listening on 53.
        # The addon's port 10053 broke Cilium DNS policies without kube-proxy.
        addons.dns.enable = false;
        kubelet.clusterDns = [ "10.0.0.254" ];

        # Pods get addresses from each node's range (10.1.x.0/24), which Cilium
        # uses with ipam.mode=kubernetes. Services stay in 10.0.0.0/24.
        clusterCidr = "10.1.0.0/16";

        # NixOS links /etc/cni/net.d to the store (read-only). Cilium writes its
        # config there, so point it at a writable directory instead.
        kubelet.cni.configDir = "/var/lib/cni/net.d";

        # networkd runs systemd-resolved, so /etc/resolv.conf is the 127.0.0.53 stub.
        # CoreDNS inherits it and forwards to itself ("Loop detected"). Give pods the
        # real upstream servers instead.
        kubelet.extraConfig.resolvConf = "/run/systemd/resolve/resolv.conf";
      };

      # The module requests every certificate with hosts = [ CN ] ++ hosts. For
      # client certs the CN is an identity like "system:node:k8s-01", not a DNS
      # name; cfssl leaves it out, certmgr 3 sees the names differ and reissues
      # every 30 min, restarting the API server each time. Drop those names.
      services.certmgr.specs =
        let
          isIdentity = h: h != null && lib.hasInfix ":" h;
          hostsOf = cert: [ cert.CN ] ++ cert.hosts;
        in
        # request is a plain attrs option: mkForce works on the whole object, not
        # inside it. Rebuilt as the module's pki.nix does, with hosts filtered.
        lib.mapAttrs
          (_: cert: {
            request = lib.mkForce {
              hosts = lib.filter (h: !isIdentity h) (hostsOf cert);
              inherit (cert) CN;
              key = { algo = "rsa"; size = 2048; };
              names = [ cert.fields ];
            };
          })
          (lib.filterAttrs (_: cert: lib.any isIdentity (hostsOf cert)) config.services.kubernetes.pki.certs);

      systemd.tmpfiles.rules = [
        "d /var/lib/cni/net.d 0755 root root -"
        "d /var/lib/cni/bin 0755 root root -"
      ];

      # The kubelet empties /opt/cni/bin at each start. Cilium installs its
      # binary into /var/lib/cni/bin (cni.binPath); link it back every time.
      systemd.services.kubelet.preStart = lib.mkAfter ''
        ln -sfn /var/lib/cni/bin/cilium-cni /opt/cni/bin/cilium-cni
      '';

      networking.firewall = {
        allowedTCPPorts = [
          10250 # kubelet API
          4240 # cilium health
          4244 # hubble
        ];
        allowedUDPPorts = [ 8472 ]; # cilium VXLAN
        # NixOS's filter (mangle, rpfilter --validmark) drops the answers Cilium
        # sends back to its transparent proxies: they carry mark 0x200, which
        # routes to an all-local table, so their source looks spoofed. That broke
        # FQDN policies and every L7 (Envoy) policy. Cilium manages rp_filter on
        # its own interfaces.
        checkReversePath = false;
      };
    }

    (lib.mkIf (cfg.role == "master") {
      services.kubernetes.controllerManager.allocateNodeCIDRs = true;
      # Cilium's agent runs privileged (eBPF, BPF filesystem). The module's
      # default (false) makes the API server reject its DaemonSet.
      services.kubernetes.apiserver.allowPrivileged = true;

      networking.firewall.allowedTCPPorts = [
        6443 # API server
        8888 # cfssl: nodes fetch their certificates here
      ];

      environment.systemPackages = with pkgs; [ kubectl kubernetes-helm cilium-cli ];
      environment.etc."cilium/values.yaml".source = ../k8s/cilium-values.yaml;
      environment.etc."coredns/values.yaml".source = ../k8s/coredns-values.yaml;
      environment.variables.KUBECONFIG = "/etc/kubernetes/cluster-admin.kubeconfig";
    })
  ];
}
