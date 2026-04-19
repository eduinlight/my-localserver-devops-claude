# Garage S3 — Node.js example

Minimal round-trip (PUT / GET / LIST / DELETE) against the Garage S3 service running on LXC 100 (192.168.0.5).

## Prereqs

- Node.js ≥ 20
- LAN access to 192.168.0.5
- Internal DNS (192.168.0.21) reachable so `s3.lan` and `*.s3.lan` resolve

## Setup

```sh
cp .env.example .env
# fill in GARAGE_ACCESS_KEY and GARAGE_SECRET_KEY
npm install
node index.mjs
```

## How it connects

Virtual-host style: the AWS SDK issues requests to `<bucket>.s3.lan:3900`, which resolves via the `*.s3.lan` wildcard DNS to 192.168.0.5. Garage is configured with `root_domain = ".s3.lan"` in `[s3_api]` and parses the bucket from the subdomain.

## Rotating / issuing new credentials

On the Proxmox host:

```sh
ssh root@192.168.0.15
pct exec 100 -- bash -c 'docker exec admin-garage-1 /garage key create my-new-key'
pct exec 100 -- bash -c 'docker exec admin-garage-1 /garage bucket allow --read --write --owner nodejs-test --key my-new-key'
pct exec 100 -- bash -c 'docker exec admin-garage-1 /garage key info --show-secret my-new-key'
```
