# patroni — PostgreSQL 18 + Patroni + etcd on Rocky 8, with pgBackRest over mutual TLS

Three amd64 Rocky 8 guests on the [`../fabric`](../fabric) network:

| Host | Lab IP | Role |
| --- | --- | --- |
| etcd1 | 192.168.105.140 | Single-member etcd (the DCS), and the pgBackRest repository |
| pgn1 | 192.168.105.141 | PostgreSQL 18 + Patroni |
| pgn2 | 192.168.105.142 | PostgreSQL 18 + Patroni |

Co-locating the DCS and the backup repository on `etcd1` is a lab economy, not a recommendation.

The build has two halves, and they are configured differently on purpose — read this before you start:

- **Bootstrap (steps 1–3) is the commands I ran by hand**, shipped here as the exact config files from the write-up. They are not an Ansible playbook yet.
- **pgBackRest wiring (step 5) is Ansible** — playbooks `03`, `04` and `05`.

Full walk-throughs: [Patroni HA on PostgreSQL 18, proven by killing the primary](https://basantbhattarai.com.np/writing/patroni-postgresql-18-rocky8-etcd-failover/) and [pgBackRest against a Patroni cluster](https://basantbhattarai.com.np/writing/pgbackrest-patroni-cluster-backup-pitr/).

## 1. Boot the guests

`socket_vmnet` must already be running (see `../fabric`). TCG boots slowly; `boot_timeout` is 900 s.

```bash
cd patroni
./bin/vagrant-up etcd1 pgn1 pgn2
```

Why Rocky 8 and not `generic/rhel8`: an unregistered RHEL 8 box has no AppStream, so there is no `python3.12` and PGDG's `patroni-etcd` cannot resolve. On a registered RHEL 8 every command below is identical.

## 2. etcd on etcd1

```bash
sudo dnf -y install https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -y --enablerepo=pgdg-rhel8-extras install etcd   # -y matters: without it dnf reports a "Bad GPG signature"
```

Install [`config/etcd.conf.yaml`](config/etcd.conf.yaml) as `/etc/etcd/etcd.conf.yaml` and [`config/etcd-override.conf`](config/etcd-override.conf) as `/etc/systemd/system/etcd.service.d/override.conf`, then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now etcd
sudo firewall-cmd --permanent --add-port=2379/tcp --add-port=2380/tcp && sudo firewall-cmd --reload
etcdctl --endpoints=http://192.168.105.140:2379 endpoint health
```

## 3. PostgreSQL 18 and Patroni on pgn1 and pgn2

```bash
sudo dnf -y install https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql
sudo dnf -y install postgresql18-server postgresql18-contrib patroni-etcd
```

Do not run `initdb`; Patroni bootstraps the data directory. Install [`config/patroni-pgn1.yml`](config/patroni-pgn1.yml) (or `-pgn2`) as `/etc/patroni/patroni.yml`, start `pgn1` first so it wins the bootstrap, then `pgn2`:

```bash
sudo systemctl enable --now patroni
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list
```

## 4. The failover drill

Write a row on the leader, then kill it badly — `SIGKILL`, not `systemctl stop`:

```bash
sudo systemctl kill -s SIGKILL patroni
sudo pkill -9 -f 'postgres -D'
```

Poll `patronictl list` on the survivor until it shows `Leader`, then restart Patroni on the old primary and watch it rejoin through `pg_rewind`.

## 5. pgBackRest, by Ansible

From this directory, on the control node:

```bash
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/ansible-galaxy collection install -r ansible/collections/requirements.yml

cd ansible
../.venv/bin/ansible-playbook playbooks/03_pgbackrest_patroni.yml   # install pgBackRest, declare every member to the repo
../.venv/bin/ansible-playbook playbooks/04_patroni_archive.yml      # archive_command via the DCS; pgbackrest as a replica method
../.venv/bin/ansible-playbook playbooks/05_pgbackrest_tls.yml       # step guest clocks, issue certs, switch to mutual TLS
```

`archive_mode` is postmaster-level, so after `04` Patroni shows **Pending restart**. Do the rolling restart:

```bash
sudo -u postgres patronictl -c /etc/patroni/patroni.yml restart pg18lab --force
```

Then, on `etcd1`:

```bash
sudo -u postgres pgbackrest --stanza=pg18lab stanza-create
sudo -u postgres pgbackrest --stanza=pg18lab check
sudo -u postgres pgbackrest --stanza=pg18lab --type=full backup
```

Rebuild a replica from the repository instead of from the primary:

```bash
sudo -u postgres patronictl -c /etc/patroni/patroni.yml reinit pg18lab pgn1 --force
```

The point-in-time restore of a dropped table, and the timeline-history trap after it, are in the [pgBackRest post](https://basantbhattarai.com.np/writing/pgbackrest-patroni-cluster-backup-pitr/) step by step. The short version: `patronictl pause` does not stop PostgreSQL, so stop it with `pg_ctl -m fast stop` before restoring, and take a fresh full backup before rebuilding any replica afterwards.

The playbooks issue a private lab CA and per-host certificates on the control node under `ansible/artifacts/certs/` (gitignored — generated on your machine, never shipped).
