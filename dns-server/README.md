# home.lab.com DNS server

BIND9 on Alpine, serving the `home.lab.com` zone and reverse zone for `192.168.56.0/24`.
Other names are forwarded to 1.1.1.1 / 8.8.8.8.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds the image and validates config/zones at build time |
| `config/named.conf` | BIND options, ACLs, forwarders, zone definitions |
| `config/db.home.lab.com` | Forward zone (A / CNAME records) |
| `config/db.192.168.56` | Reverse zone (PTR records) |
| `docker-compose.yml` | Runs the container on port 53 |

## Run

```bash
docker compose up -d --build
# or
docker build -t home-lab-dns .
docker run -d --name home-lab-dns -p 53:53/udp -p 53:53/tcp --restart unless-stopped home-lab-dns
```

## Test

```bash
dig @192.168.56.10 master.home.lab.com +short
dig @192.168.56.10 -x 192.168.56.101 +short
dig @192.168.56.10 google.com +short
```

## Adding a host

1. Add an `A` record to `config/db.home.lab.com` and a `PTR` record to `config/db.192.168.56`.
2. Bump the `serial` in both SOA records.
3. Rebuild: `docker compose up -d --build`.

> On hosts running `systemd-resolved`, port 53 may already be in use. Disable its stub
> listener (`DNSStubListener=no` in `/etc/systemd/resolved.conf`) before starting the container.
