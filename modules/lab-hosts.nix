# The lab IP plan, in one place. macOS vmnet NAT network 192.168.64.0/24 (vfkit):
# the Mac and gateway is .1 and DHCP leases start at .2, so static servers use
# .10 and up. Keep it in step with spec() in lab/lab.sh.
# home.arpa is the domain reserved for home networks (RFC 8375).
{
  networking.hosts = {
    "192.168.64.10" = [ "gitea" "gitea.lab.home.arpa" ];
    "192.168.64.11" = [ "woodpecker" "woodpecker.lab.home.arpa" ];
    "192.168.64.20" = [ "k8s-01" "k8s-01.lab.home.arpa" ];
    "192.168.64.21" = [ "k8s-02" "k8s-02.lab.home.arpa" ];
    "192.168.64.22" = [ "k8s-03" "k8s-03.lab.home.arpa" ];
  };
}
