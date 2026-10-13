# fabric — amd64 guests on Apple Silicon, with a real L2 network

Replicable Vagrant + QEMU lab on Apple Silicon that runs **real amd64 guests**
(Ubuntu + RHEL-family), with working **host ↔ VM** and **VM ↔ VM** networking.

Verified on 2026-08-13:

| Check | Result |
| --- | --- |
| Host → `ubuntu1` `192.168.105.111` | 0% loss, ~1–2 ms |
| Host → `rocky1` `192.168.105.121` | 0% loss, ~2–3 ms |
| `ubuntu1` → `rocky1` | 0% loss, ~2–4 ms |
| `rocky1` → `ubuntu1` | 0% loss, ~1–2 ms |
| Vagrant SSH (SLIRP hostfwd) | OK on both |
| Guest → `192.168.105.1` ICMP | Fails (macOS vmnet); **ARP REACHABLE** |

## Why this exists

Most Vagrant boxes and production VMs are **amd64**. On Apple Silicon you need
TCG `qemu-system-x86_64`, not aarch64 boxes that only look convenient.

Older Patroni-style Vagrantfiles often assign **`192.168.1.x`**. On a Mac whose
Wi‑Fi is already `192.168.1.0/24`, that collides with the LAN: SSH “works”
through port forwards while host/lab IPs look wrong and inter-node traffic dies.

## Architecture

```
Host (arm64 macOS)
  ├─ SLIRP net0 per VM → Vagrant SSH via 127.0.0.1:<ssh_port>
  └─ socket_vmnet (bridge100, 192.168.105.0/24)
        gateway .1, DHCP ends at .100
        static lab IPs: ubuntu .111/.112, rocky .121/.122
```

Each QEMU gets a second NIC with `-netdev socket,id=lab0,fd=3`. That fd must be
the unix pipe from `socket_vmnet_client`, not QEMU’s native `stream` connect to
the socket (that path connects then drops RX).

## One-time host setup

```bash
brew install qemu socket_vmnet
vagrant plugin install vagrant-qemu   # need >= 0.6.3

# Persistent daemon (KeepAlive)
sudo mkdir -p /opt/homebrew/var/log/socket_vmnet
sudo cp contrib/lab.socket_vmnet.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/lab.socket_vmnet.plist
# or after edits:
sudo launchctl kickstart -kp system/lab.socket_vmnet
```

**Verify.** `ifconfig bridge100` shows `inet 192.168.105.1`, and
`/opt/homebrew/var/run/socket_vmnet` exists as a unix socket.

## Boxes

```bash
vagrant box add generic/ubuntu2204 --provider libvirt
vagrant box add generic/centos8    --provider libvirt   # RHEL-family stand-in
```

`generic/centos8` is the RHEL-based path until a Rocky 9 libvirt box is cached.

## Bring-up

Prefer the helper so IDE-integrated shells do not leave pipes on fd ≥ 3 before
Vagrant spawns QEMU:

```bash
cd fabric
./bin/vagrant-up ubuntu1 rocky1
./scripts/verify-mesh.sh
```

Or:

```bash
( exec 3<&- 4<&- 5<&- 6<&- 7<&- 8<&- 9<&-
  vagrant up ubuntu1 rocky1 --provider=qemu
)
```

First boot under TCG is slow (often several minutes per node). Memory defaults
to 1536 MB × SMP 2 — raise carefully on a busy host.

## Failure boundaries (verified)

| Symptom | Cause | Repair |
| --- | --- | --- |
| Lab IPs unreachable / weird ARP | Lab subnet = Wi‑Fi (`192.168.1.0/24`) | Use `192.168.105.0/24` (or another unused /24) |
| eth1 TX only, RX=0 | QEMU `stream` to socket_vmnet, or fd 3 is a pipe | `socket_vmnet_client` + close inherited fds; check `lsof -p $QPID -d 3` is `unix` with a peer |
| `vagrant up` hangs / no SSH | TCG boot time | Raise `boot_timeout`; wait; use `IdentitiesOnly=yes` |
| Guest ping `.1` fails | macOS vmnet gateway often ignores ICMP | Check ARP REACHABLE; ping peers / host→guest instead |
| socket_vmnet dies mid-lab | Daemon not KeepAlive / manual kill | Install `lab.socket_vmnet` LaunchDaemon |

## Layout

- `Vagrantfile` — four nodes (ubuntu1/2, rocky1/2), dual NIC, static lab IPs
- `bin/qemu-system-x86_64` — closes fds >2, execs `socket_vmnet_client` → real QEMU
- `bin/vagrant-up` — clean-fd wrapper around `vagrant up`
- `scripts/verify-mesh.sh` — host + inter-node checks for running nodes
- `contrib/lab.socket_vmnet.plist` — persistent daemon
