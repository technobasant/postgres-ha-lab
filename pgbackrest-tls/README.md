# pgbackrest-tls — a dedicated pgBackRest TLS repo host on RHEL 8

Ansible-only app config on `generic/rhel8` (1G / 1 CPU). Fabric is
`socket_vmnet` `192.168.105.0/24` (see [`../fabric`](../fabric)).

## Measured (2026-08-13)

| Check | Result |
| --- | --- |
| Package | **pgBackRest 2.59.0** (PGDG latest stable on EL8) |
| `backup1` TLS listen | `0.0.0.0:8432` via `pgbackrest-server.service` |
| `pg1` → `backup1` `server-ping` | completed successfully |
| mTLS (`openssl s_client` + client cert) | **Verify return code: 0 (ok)** |

## Bring-up

```bash
# socket_vmnet must already be up on 192.168.105.1
cd pgbackrest-tls
./bin/vagrant-up backup1 pg1

python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt   # ansible-core==2.15.13
# RHEL8 guests are Python 3.6 — need ansible-core < 2.16 on the control node.
# Prefer Python 3.12 for the venv (3.14 breaks Ansible conditionals via ast.Str).

cd ansible
../.venv/bin/ansible-playbook playbooks/01_pgbackrest_tls.yml --limit 'backup1:pg1:localhost'
```

## Nodes

| Host | Lab IP | Role |
| --- | --- | --- |
| backup1 | 192.168.105.130 | Dedicated pgBackRest TLS repo server |
| pg1 | 192.168.105.131 | TLS client (handshake proof; Postgres comes in [`../patroni`](../patroni)) |
| pg2 | 192.168.105.132 | reserved |

The playbook issues a private lab CA and per-host certificates on the control node, under
`ansible/artifacts/certs/`. That directory is gitignored: certificates are generated on your
machine, never shipped. Delete it and re-run the playbook to rotate them.
