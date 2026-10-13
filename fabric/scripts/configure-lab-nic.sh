#!/bin/bash
# Configure the socket_vmnet NIC with a stable lab IP.
# net0 = QEMU user/SLIRP (Vagrant SSH via hostfwd). lab0 = shared L2 (host + peers).
set -euo pipefail

LAB_IP="${1:?lab IP required, e.g. 192.168.105.11}"
LAB_CIDR="${2:-24}"
LAB_GW="${3:-192.168.105.1}"

echo "==> Configuring lab NIC for ${LAB_IP}/${LAB_CIDR}"

# Prefer the virtio NIC that is NOT the SLIRP default (10.0.2.15).
pick_iface() {
  local iface addr
  # shellcheck disable=SC2010  # interface names are simple tokens; this filters virtual NICs.
  for iface in $(ls /sys/class/net | grep -vE '^(lo|docker|veth|br-)'); do
    addr=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
    if [[ "$addr" == "10.0.2.15" ]]; then
      continue
    fi
    # Prefer interfaces that already have a 192.168.105.x DHCP lease, else any non-SLIRP iface
    if [[ "$addr" == 192.168.105.* ]]; then
      echo "$iface"
      return 0
    fi
  done

  # shellcheck disable=SC2010  # interface names are simple tokens; this filters virtual NICs.
  for iface in $(ls /sys/class/net | grep -vE '^(lo|docker|veth|br-)'); do
    addr=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
    if [[ "$addr" != "10.0.2.15" ]]; then
      echo "$iface"
      return 0
    fi
  done
  return 1
}

IFACE="$(pick_iface || true)"
if [[ -z "${IFACE}" ]]; then
  echo "ERROR: could not find lab NIC (expected a non-10.0.2.15 interface)" >&2
  ip -br link
  ip -br addr
  exit 1
fi

echo "Using interface: ${IFACE}"
ip -br link show "$IFACE"
ip -br addr show "$IFACE" || true

if command -v netplan >/dev/null 2>&1; then
  cat > /etc/netplan/99-lab-nic.yaml <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: false
      addresses:
        - ${LAB_IP}/${LAB_CIDR}
      nameservers:
        addresses: [${LAB_GW}, 1.1.1.1]
EOF
  chmod 600 /etc/netplan/99-lab-nic.yaml
  netplan apply
elif [[ -d /etc/sysconfig/network-scripts ]]; then
  cat > "/etc/sysconfig/network-scripts/ifcfg-${IFACE}" <<EOF
TYPE=Ethernet
BOOTPROTO=none
NAME=${IFACE}
DEVICE=${IFACE}
ONBOOT=yes
IPADDR=${LAB_IP}
PREFIX=${LAB_CIDR}
DEFROUTE=no
NM_CONTROLLED=no
EOF
  ifdown "$IFACE" 2>/dev/null || true
  ifup "$IFACE" || ip addr add "${LAB_IP}/${LAB_CIDR}" dev "$IFACE" || true
  ip link set "$IFACE" up
elif [[ -d /etc/NetworkManager/system-connections ]]; then
  # Rocky/RHEL 8+ with NetworkManager keyfiles
  nmcli dev set "$IFACE" managed yes || true
  nmcli con delete "lab-${IFACE}" 2>/dev/null || true
  nmcli con add type ethernet ifname "$IFACE" con-name "lab-${IFACE}" \
    ipv4.method manual ipv4.addresses "${LAB_IP}/${LAB_CIDR}" \
    ipv4.never-default yes ipv6.method ignore connection.autoconnect yes
  nmcli con up "lab-${IFACE}"
else
  ip addr flush dev "$IFACE" || true
  ip addr add "${LAB_IP}/${LAB_CIDR}" dev "$IFACE"
  ip link set "$IFACE" up
fi

sleep 1
echo "==> Lab NIC addresses:"
ip -br addr show "$IFACE"
ip -4 addr show "$IFACE" | grep -q "$LAB_IP"
echo "OK: ${IFACE} has ${LAB_IP}"

# Persist hosts snippets for peers (filled by Vagrant)
mkdir -p /etc/lab
echo "${LAB_IP}" > /etc/lab/ip
echo "${IFACE}" > /etc/lab/iface
