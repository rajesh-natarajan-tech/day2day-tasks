; Forward zone for home.lab.com
; Increase the serial (YYYYMMDDNN) every time you edit this file
$TTL 3600
@       IN  SOA ns1.home.lab.com. admin.home.lab.com. (
                2026101701  ; serial
                3600        ; refresh
                900         ; retry
                604800      ; expire
                300 )       ; negative cache TTL

@               IN  NS      ns1.home.lab.com.

; DNS server (the host running this container)
ns1             IN  A       192.168.56.2

; Kubernetes nodes
k8s-master      IN  A       192.168.56.10
k8s-worker1     IN  A       192.168.56.11
k8s-worker2     IN  A       192.168.56.12

; Ingress / load balancer IP - apps exposed through the ingress
ingress         IN  A       192.168.56.10
*.apps          IN  CNAME   ingress.home.lab.com.

; Lab services
keycloak        IN  CNAME   ingress.home.lab.com.
