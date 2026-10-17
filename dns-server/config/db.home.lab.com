; Forward zone for home.lab.com
$TTL 3600
@       IN  SOA ns1.home.lab.com. admin.home.lab.com. (
            2026101701  ; serial (YYYYMMDDnn) - bump on every change
            3600        ; refresh
            900         ; retry
            604800      ; expire
            300 )       ; negative cache TTL

@           IN  NS      ns1.home.lab.com.
@           IN  A       192.168.56.10

ns1         IN  A       192.168.56.10
master      IN  A       192.168.56.11
vm1         IN  A       192.168.56.101
vm2         IN  A       192.168.56.102
vm3         IN  A       192.168.56.103

; Services
keycloak    IN  CNAME   master
argocd      IN  CNAME   master
vault       IN  CNAME   master
