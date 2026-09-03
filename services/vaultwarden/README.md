# Vaultwarden (LXC 109)

Self-hosted Bitwarden-compatible password server — https://github.com/dani-garcia/vaultwarden

| | |
|---|---|
| VMID | 109 |
| IP | 192.168.0.29 |
| Pool | tools |
| Resources | 2 cores / 2 GB / 16 GB |
| Base | clone of LXC template 101 (docker) |
| Compose | `/home/admin/docker-compose.yaml` (mirrored here) |
| Data | named volume `admin_vaultwarden-data` → `/data` |
| URL | https://secrets.lan (Traefik, self-signed cert) |
| Direct | http://192.168.0.29:8080 |

## Access

```sh
ssh root@192.168.0.15
pct exec 109 -- bash -c 'cd /home/admin && docker compose ps'
```

## HTTPS is required

The Bitwarden web vault uses WebCrypto, which browsers only expose on a secure
origin. `secrets.lan` therefore terminates TLS at Traefik with a self-signed cert
(`/home/admin/certs/secrets.lan.{crt,key}` on LXC 114, registered in `config/tls.yml`);
the `web` entrypoint 301-redirects to `websecure`. Import the cert into the browser
/ OS trust store to avoid the interstitial. Vaultwarden itself speaks plain HTTP on
:8080 behind the proxy, and `DOMAIN=https://secrets.lan` tells it what to emit in
links and WebAuthn origins.

## Admin panel

https://secrets.lan/admin — the token is the plaintext value in `secrets.local.md`
(untracked). `/home/admin/.env` holds it as an Argon2id PHC hash (OWASP preset:
`m=19456,t=2,p=1`), which is what Vaultwarden compares against.

Regenerate one:

```sh
pct exec 109 -- bash -c 'echo -n "<new-token>" | argon2 "$(openssl rand -base64 24)" -id -k 19456 -t 2 -p 1 -e'
```

**Quote it with single quotes in `.env`.** Compose interpolates `$` inside double
quotes and unquoted values, which mangles the `$argon2id$...` string into garbage
and locks you out of `/admin`. The container's own `vaultwarden hash` subcommand
needs a TTY and cannot be driven through `pct exec`, hence the `argon2` CLI.

## Signups and invites

`SIGNUPS_ALLOWED=false`, `INVITATIONS_ALLOWED=true`. New users are added by invite
from the admin panel.

**No SMTP is configured, so no invitation email is ever sent** — this is deliberate,
not a fault. Delivering mail straight from a residential IP with no PTR record gets
rejected by essentially every receiver, and the old `mail.lan` host is gone. Invites
work without it:

1. https://secrets.lan/admin → *Users* → invite the address.
2. Tell the person out-of-band to go to https://secrets.lan and **register with that
   exact address**.
3. They set their own master password there. Nothing is emailed at any point.

Registration succeeds despite `SIGNUPS_ALLOWED=false` because the invite writes a row
to the `invitations` table which pre-authorizes that one address. Verified on the live
instance 2026-09-03: an invited address returns `200` from
`POST /identity/accounts/register`, an uninvited one returns `400 "Registration not
allowed or user already exists"`.

The address must match exactly — the invite is keyed on the literal string, so a typo
means the person hits the same 400 a stranger would.

To add SMTP later, set `SMTP_HOST` / `SMTP_PORT` / `SMTP_SECURITY` / `SMTP_FROM` /
`SMTP_USERNAME` / `SMTP_PASSWORD` in `.env` and reference them from the compose
environment. Vaultwarden then mails invites, password hints and 2FA notices.

## Poking the admin API with curl

The admin panel authenticates with a `VW_ADMIN` cookie:

```sh
curl -sk -c cj.txt -X POST https://secrets.lan/admin --data-urlencode "token=<plaintext-token>"
curl -sk -b cj.txt https://secrets.lan/admin/users            # list, JSON
curl -sk -b cj.txt -X POST https://secrets.lan/admin/invite \
  -H 'Content-Type: application/json' -d '{"email":"someone@example.com"}'
curl -sk -b cj.txt -X POST https://secrets.lan/admin/users/<id>/delete -d ''
```

**Send an empty body to routes that take no data.** Rocket treats a JSON body on a
bodyless route as a non-matching route and falls through to `404`, which reads exactly
like a wrong URL. `-d ''` returns `200`; `-d '{}'` returns `404` on the same endpoint.

## Registry mirror

`/etc/docker/daemon.json` points at `mirror.docker.lan`; the Docker Hub blob CDN is
blackholed by the ISP and a direct `docker pull vaultwarden/server` hangs.

## Backup

Everything lives in the `admin_vaultwarden-data` volume (SQLite DB + attachments +
RSA keys). Snapshot it with:

```sh
pct exec 109 -- docker run --rm -v admin_vaultwarden-data:/data -v /root:/backup \
  alpine tar czf /backup/vaultwarden-$(date +%F).tar.gz -C /data .
```
