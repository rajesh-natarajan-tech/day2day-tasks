# BIND9 DNS server for the home lab zone home.lab.com
FROM alpine:3.20

RUN apk add --no-cache bind bind-tools \
    && mkdir -p /var/cache/bind /var/log/named \
    && chown -R named:named /var/cache/bind /var/log/named

COPY config/named.conf          /etc/bind/named.conf
COPY config/db.home.lab.com     /etc/bind/zones/db.home.lab.com
COPY config/db.192.168.56       /etc/bind/zones/db.192.168.56

# Fail the build early if the config or zone files have mistakes
RUN named-checkconf /etc/bind/named.conf \
    && named-checkzone home.lab.com /etc/bind/zones/db.home.lab.com \
    && named-checkzone 56.168.192.in-addr.arpa /etc/bind/zones/db.192.168.56

EXPOSE 53/udp 53/tcp

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD dig @127.0.0.1 ns1.home.lab.com +short | grep -q . || exit 1

# -g: run in foreground, log to stderr  -u: drop privileges to the named user
CMD ["named", "-g", "-u", "named", "-c", "/etc/bind/named.conf"]
