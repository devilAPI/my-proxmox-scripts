#!/usr/bin/env bash
# ============================================================
#  Tor Bridge LXC — Proxmox Helper Script
#  Inspired by community Proxmox Helper Scripts (tteck style)
#  OS: Debian 13 "Trixie" (unprivileged LXC)
#  Transport: obfs4 via obfs4proxy
#  Network:   IPv6 only (DS-Lite / no public IPv4)
# ============================================================

set -euo pipefail

# ── Colours ────────────────────────────────────────────────
YW='\033[33m'
GN='\033[1;92m'
RD='\033[01;31m'
CL='\033[m'
BFR='\r\033[K'
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
INFO="${YW}⚡${CL}"

header_info() {
  clear
  cat <<"EOF"

  ████████╗ ██████╗ ██████╗     ██████╗ ██████╗ ██╗██████╗  ██████╗ ███████╗
     ██╔══╝██╔═══██╗██╔══██╗    ██╔══██╗██╔══██╗██║██╔══██╗██╔════╝ ██╔════╝
     ██║   ██║   ██║██████╔╝    ██████╔╝██████╔╝██║██║  ██║██║  ███╗█████╗
     ██║   ██║   ██║██╔══██╗    ██╔══██╗██╔══██╗██║██║  ██║██║   ██║██╔══╝
     ██║   ╚██████╔╝██║  ██║    ██████╔╝██║  ██║██║██████╔╝╚██████╔╝███████╗
     ╚═╝    ╚═════╝ ╚═╝  ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚═╝╚═════╝  ╚═════╝ ╚══════╝

         LXC  •  Debian 13 Trixie  •  obfs4  •  IPv6  •  Proxmox VE
EOF
  echo
}

msg_info()  { echo -ne " ${INFO} ${YW}$1...${CL}"; }
msg_ok()    { echo -e  "${BFR} ${CM} ${GN}$1${CL}"; }
msg_error() { echo -e  "${BFR} ${CROSS} ${RD}$1${CL}"; exit 1; }
msg_warn()  { echo -e  " ${YW}⚠  $1${CL}"; }

# ── Guards ─────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }
! command -v pveversion &>/dev/null && { echo "Must run on Proxmox VE."; exit 1; }

header_info

# ── Helpers ─────────────────────────────────────────────────
ask() {
  local prompt="$1" default="$2" var_name="$3"
  echo -ne " ${YW}$prompt${CL} [${GN}${default}${CL}]: "
  read -r input
  printf -v "$var_name" '%s' "${input:-$default}"
}

ask_required() {
  local prompt="$1" var_name="$2" value=""
  while [[ -z "$value" ]]; do
    echo -ne " ${YW}$prompt${CL}: "
    read -r value
  done
  printf -v "$var_name" '%s' "$value"
}

confirm() {
  echo -ne " ${YW}$1${CL} [y/N]: "
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

divider() { echo -e " ${YW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"; }

# ══════════════════════════════════════════════════════════════
#  SECTION 1 — LXC Specs
# ══════════════════════════════════════════════════════════════
divider
echo -e " ${GN}▶  LXC Container Settings${CL}"
divider

NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo 200)
ask "Container ID (VMID)" "$NEXT_ID" VMID
ask "Hostname" "tor-bridge" CT_HOSTNAME
ask "CPU cores" "1" CT_CORES
ask "RAM in MB" "512" CT_RAM
ask "Disk size in GB (number only, e.g. 4)" "4" CT_DISK

mapfile -t STORAGES < <(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1}')
[[ ${#STORAGES[@]} -eq 0 ]] && STORAGES=("local-lvm")
echo
echo -e " ${YW}Available storages:${CL}"
for i in "${!STORAGES[@]}"; do
  echo -e "   ${GN}[$((i+1))]${CL} ${STORAGES[$i]}"
done
ask "Storage (name or number)" "${STORAGES[0]}" CT_STORAGE_INPUT
if [[ "$CT_STORAGE_INPUT" =~ ^[0-9]+$ ]]; then
  CT_STORAGE="${STORAGES[$((CT_STORAGE_INPUT - 1))]:-${STORAGES[0]}}"
else
  CT_STORAGE="$CT_STORAGE_INPUT"
fi

ask "Network bridge" "vmbr0" CT_BRIDGE
echo
echo -e " ${YW}IPv4 (needed for apt during install — bridge uses IPv6 for Tor):${CL}"
echo -e "   ${GN}[1]${CL} DHCP (default)"
echo -e "   ${GN}[2]${CL} Static"
echo -ne " ${YW}Choice${CL} [1]: "
read -r NET_CHOICE
if [[ "$NET_CHOICE" == "2" ]]; then
  ask_required "IPv4/CIDR (e.g. 192.168.178.50/24)" CT_IP
  ask_required "Gateway (e.g. 192.168.178.1)" CT_GW
  CT_NET="ip=${CT_IP},gw=${CT_GW},ip6=auto"
else
  CT_NET="ip=dhcp,ip6=auto"
fi

# ══════════════════════════════════════════════════════════════
#  SECTION 2 — Tor Bridge Settings
# ══════════════════════════════════════════════════════════════
divider
echo -e " ${GN}▶  Tor Bridge Settings${CL}"
divider

ask "OR Port (externally reachable, avoid 9001)" "4443" TOR_OR_PORT
ask "obfs4 Port (externally reachable, avoid 9001)" "54791" TOR_OBFS4_PORT
ask "Nickname (alphanumeric, 1-19 chars)" "KrasserBridge" TOR_NICKNAME
ask "Contact e-mail (optional, Enter to skip)" "" TOR_EMAIL

# ══════════════════════════════════════════════════════════════
#  SECTION 3 — Bandwidth
# ══════════════════════════════════════════════════════════════
divider
echo -e " ${GN}▶  Bandwidth / Speed Limit${CL}"
divider
echo -e " ${YW}torrc limits — enter number in MB/s (leave blank = unlimited):${CL}"
ask "RelayBandwidthRate  MB/s (e.g. 10)" "" TOR_BW_RATE
ask "RelayBandwidthBurst MB/s (e.g. 20)" "" TOR_BW_BURST
echo
echo -e " ${YW}tc kernel hard cap on host veth (e.g. 10mbit — leave blank to skip):${CL}"
ask "tc ingress limit (traffic INTO bridge)" "" TC_INGRESS
ask "tc egress  limit (traffic OUT of bridge)" "" TC_EGRESS

# ══════════════════════════════════════════════════════════════
#  SECTION 4 — Summary & Confirm
# ══════════════════════════════════════════════════════════════
divider
echo -e " ${GN}▶  Summary${CL}"
divider
echo -e "  VMID              : ${GN}$VMID${CL}"
echo -e "  Hostname          : ${GN}$CT_HOSTNAME${CL}"
echo -e "  Cores / RAM       : ${GN}${CT_CORES} vCPU / ${CT_RAM} MB${CL}"
echo -e "  Disk / Storage    : ${GN}${CT_DISK}G on ${CT_STORAGE}${CL}"
echo -e "  Bridge / Net      : ${GN}${CT_BRIDGE} — ${CT_NET}${CL}"
echo -e "  OR Port           : ${GN}$TOR_OR_PORT${CL}"
echo -e "  obfs4 Port        : ${GN}$TOR_OBFS4_PORT${CL}"
echo -e "  Nickname          : ${GN}$TOR_NICKNAME${CL}"
echo -e "  Contact           : ${GN}${TOR_EMAIL:-"(none)"}${CL}"
echo -e "  torrc BW Rate     : ${GN}${TOR_BW_RATE:-"(unlimited)"} MB/s${CL}"
echo -e "  torrc BW Burst    : ${GN}${TOR_BW_BURST:-"(unlimited)"} MB/s${CL}"
echo -e "  tc ingress cap    : ${GN}${TC_INGRESS:-"(none)"}${CL}"
echo -e "  tc egress  cap    : ${GN}${TC_EGRESS:-"(none)"}${CL}"
divider
echo
confirm "  Proceed with creating the LXC?" || { echo " Aborted."; exit 0; }

# ══════════════════════════════════════════════════════════════
#  SECTION 5 — Download Debian 13 Template
# ══════════════════════════════════════════════════════════════
TEMPLATE_STORE=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1}' | head -1)
TEMPLATE_STORE="${TEMPLATE_STORE:-local}"

msg_info "Checking for Debian 13 Trixie template"
pveam update &>/dev/null
TRIXIE_TPL=$(pveam available --section system 2>/dev/null | grep -i "debian-13" | awk '{print $2}' | head -1)
[[ -z "$TRIXIE_TPL" ]] && { echo; msg_error "Debian 13 template not found — run 'pveam update' and retry."; }

TEMPLATE_CACHE="/var/lib/vz/template/cache/${TRIXIE_TPL}"
if [[ -f "$TEMPLATE_CACHE" ]]; then
  msg_ok "Template already present"
else
  msg_info "Downloading Debian 13 Trixie template"
  pveam download "${TEMPLATE_STORE}" "$TRIXIE_TPL" 2>&1 | tail -1
  msg_ok "Template downloaded"
fi

TEMPLATE_VOL="${TEMPLATE_STORE}:vztmpl/${TRIXIE_TPL}"

# ══════════════════════════════════════════════════════════════
#  SECTION 6 — Create LXC
# ══════════════════════════════════════════════════════════════
msg_info "Creating LXC container ${VMID}"

pct create "$VMID" "$TEMPLATE_VOL" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CT_CORES" \
  --memory "$CT_RAM" \
  --rootfs "${CT_STORAGE}:${CT_DISK}" \
  --net0 "name=eth0,bridge=${CT_BRIDGE},${CT_NET}" \
  --unprivileged 1 \
  --features "keyctl=1,nesting=0" \
  --onboot 1 \
  --start 0 \
  --ostype debian \
  --password "$(openssl rand -base64 18)" \
  --description "Tor Bridge (obfs4/IPv6) — created by tor-bridge-lxc.sh"

msg_ok "LXC ${VMID} created"

# ══════════════════════════════════════════════════════════════
#  SECTION 7 — Start & detect stable IPv6
# ══════════════════════════════════════════════════════════════
msg_info "Starting container"
pct start "$VMID"
sleep 8
msg_ok "Container started"

msg_info "Waiting for IPv6 SLAAC (EUI-64 stable address)"
IPV6_ADDR=""
for i in $(seq 1 30); do
  # Prefer EUI-64 address (contains ff:fe in interface identifier — stable, MAC-derived)
  IPV6_ADDR=$(pct exec "$VMID" -- ip -6 addr show eth0 scope global 2>/dev/null \
    | grep -oP '(?<=inet6 )[0-9a-f:]+(?=/)' \
    | grep -v '^fd' \
    | grep 'ff:fe' \
    | head -1 || true)
  [[ -n "$IPV6_ADDR" ]] && break
  sleep 2
done

# Fallback: any non-ULA global
if [[ -z "$IPV6_ADDR" ]]; then
  IPV6_ADDR=$(pct exec "$VMID" -- ip -6 addr show eth0 scope global 2>/dev/null \
    | grep -oP '(?<=inet6 )[0-9a-f:]+(?=/)' \
    | grep -v '^fd' \
    | head -1 || true)
fi

echo
if [[ -n "$IPV6_ADDR" ]]; then
  echo -e " ${GN}Detected stable IPv6:${CL} ${YW}${IPV6_ADDR}${CL}"
  echo -e " ${YW}(EUI-64 — derived from MAC, does not rotate with privacy extensions)${CL}"
  echo
  if ! confirm "  Use this address?"; then
    ask_required "Enter IPv6 address manually (no brackets)" IPV6_ADDR
  fi
else
  msg_warn "Could not auto-detect IPv6. Check: pct exec ${VMID} -- ip -6 addr show eth0"
  ask_required "Enter IPv6 address manually (no brackets)" IPV6_ADDR
fi

msg_ok "IPv6 confirmed: ${IPV6_ADDR}"

# Wait for outbound connectivity
msg_info "Waiting for outbound connectivity"
for i in $(seq 1 20); do
  pct exec "$VMID" -- ping6 -c1 -W2 2606:4700:4700::1111 &>/dev/null && break
  pct exec "$VMID" -- ping  -c1 -W2 8.8.8.8             &>/dev/null && break
  sleep 2
done
msg_ok "Network ready"

# ══════════════════════════════════════════════════════════════
#  SECTION 8 — Install Tor & obfs4proxy
# ══════════════════════════════════════════════════════════════
msg_info "Installing Tor & obfs4proxy (this may take a minute)"

pct exec "$VMID" -- bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq unattended-upgrades apt-listchanges
systemctl enable --now unattended-upgrades

apt-get install -y -qq apt-transport-https gnupg curl ca-certificates

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc \
  | gpg --dearmor -o /etc/apt/keyrings/tor.gpg

cat > /etc/apt/sources.list.d/tor.list << EOF
deb     [signed-by=/etc/apt/keyrings/tor.gpg] https://deb.torproject.org/torproject.org trixie main
deb-src [signed-by=/etc/apt/keyrings/tor.gpg] https://deb.torproject.org/torproject.org trixie main
EOF

apt-get update -qq
apt-get install -y -qq tor deb.torproject.org-keyring obfs4proxy
systemctl enable tor.service
' 2>&1 | grep -v "^$" | sed "s/^/  /"

msg_ok "Tor & obfs4proxy installed"

# ══════════════════════════════════════════════════════════════
#  SECTION 9 — Write torrc via pct push
# ══════════════════════════════════════════════════════════════

# Detect obfs4proxy path (Debian 13 = /bin, older = /usr/bin)
OBFS4_PATH=$(pct exec "$VMID" -- sh -c 'command -v obfs4proxy 2>/dev/null || echo /bin/obfs4proxy')

TORRC="BridgeRelay 1

# IPv6-only bridge — bind to stable EUI-64 address
ORPort [${IPV6_ADDR}]:${TOR_OR_PORT}

# obfs4 listens on all interfaces so FritzBox IPv6 forwarding works
ServerTransportPlugin obfs4 exec ${OBFS4_PATH}
ServerTransportListenAddr obfs4 [::]:${TOR_OBFS4_PORT}

ExtORPort auto"

[[ -n "$TOR_EMAIL"    ]] && TORRC+="
ContactInfo ${TOR_EMAIL}"
TORRC+="
Nickname ${TOR_NICKNAME}"
[[ -n "$TOR_BW_RATE"  ]] && TORRC+="
RelayBandwidthRate ${TOR_BW_RATE} MB"
[[ -n "$TOR_BW_BURST" ]] && TORRC+="
RelayBandwidthBurst ${TOR_BW_BURST} MB"

TORRC_TMP=$(mktemp)
printf '%s\n' "$TORRC" > "$TORRC_TMP"
pct push "$VMID" "$TORRC_TMP" /etc/tor/torrc --perms 0640
rm -f "$TORRC_TMP"
msg_ok "torrc written"

pct exec "$VMID" -- systemctl restart tor@default
sleep 3
msg_ok "Tor restarted with IPv6 config"

# ══════════════════════════════════════════════════════════════
#  SECTION 10 — tc Traffic Shaping on Host
# ══════════════════════════════════════════════════════════════
if [[ -n "$TC_INGRESS" || -n "$TC_EGRESS" ]]; then
  msg_info "Applying tc bandwidth limits on host veth"
  VETH="veth${VMID}i0"

  for i in $(seq 1 10); do
    ip link show "$VETH" &>/dev/null && break
    sleep 1
  done

  if ip link show "$VETH" &>/dev/null; then
    if [[ -n "$TC_EGRESS" ]]; then
      tc qdisc del dev "$VETH" root 2>/dev/null || true
      tc qdisc add dev "$VETH" root tbf rate "${TC_EGRESS}" burst 32kbit latency 400ms
    fi

    if [[ -n "$TC_INGRESS" ]]; then
      modprobe ifb 2>/dev/null || true
      IFB="ifb${VMID}"
      ip link add name "$IFB" type ifb 2>/dev/null || true
      ip link set dev "$IFB" up
      tc qdisc del dev "$VETH" ingress 2>/dev/null || true
      tc qdisc add dev "$VETH" handle ffff: ingress
      tc filter add dev "$VETH" parent ffff: protocol ipv6 u32 match u32 0 0 \
        action mirred egress redirect dev "$IFB"
      tc qdisc del dev "$IFB" root 2>/dev/null || true
      tc qdisc add dev "$IFB" root tbf rate "${TC_INGRESS}" burst 32kbit latency 400ms
    fi

    msg_ok "tc rules applied on ${VETH}"

    # Persist via hookscript
    HOOK_DIR="/var/lib/vz/snippets"
    mkdir -p "$HOOK_DIR"
    HOOK="${HOOK_DIR}/tc-tor-bridge-${VMID}.sh"

    {
      echo '#!/bin/bash'
      echo "# tc hook for Tor Bridge LXC ${VMID} — auto-generated by tor-bridge-lxc.sh"
      echo "if [[ \"\$1\" == \"${VMID}\" && \"\$2\" == \"post-start\" ]]; then"
      echo "  sleep 3"
      echo "  VETH=\"veth${VMID}i0\""
      [[ -n "$TC_EGRESS" ]] && echo "  tc qdisc del dev \"\$VETH\" root 2>/dev/null || true"
      [[ -n "$TC_EGRESS" ]] && echo "  tc qdisc add dev \"\$VETH\" root tbf rate ${TC_EGRESS} burst 32kbit latency 400ms"
      if [[ -n "$TC_INGRESS" ]]; then
        echo "  modprobe ifb 2>/dev/null || true"
        echo "  ip link add name ifb${VMID} type ifb 2>/dev/null || true"
        echo "  ip link set dev ifb${VMID} up"
        echo "  tc qdisc del dev \"\$VETH\" ingress 2>/dev/null || true"
        echo "  tc qdisc add dev \"\$VETH\" handle ffff: ingress"
        echo "  tc filter add dev \"\$VETH\" parent ffff: protocol ipv6 u32 match u32 0 0 action mirred egress redirect dev ifb${VMID}"
        echo "  tc qdisc del dev ifb${VMID} root 2>/dev/null || true"
        echo "  tc qdisc add dev ifb${VMID} root tbf rate ${TC_INGRESS} burst 32kbit latency 400ms"
      fi
      echo "fi"
    } > "$HOOK"
    chmod +x "$HOOK"
    pct set "$VMID" --hookscript "local:snippets/tc-tor-bridge-${VMID}.sh"
    msg_ok "tc hookscript registered (survives reboots)"
  else
    msg_warn "veth ${VETH} not found — tc rules skipped."
  fi
fi

# ══════════════════════════════════════════════════════════════
#  DONE
# ══════════════════════════════════════════════════════════════
divider
echo
echo -e " ${GN}✓  Tor Bridge LXC is up!${CL}"
echo
echo -e " ${YW}Stable IPv6:${CL} ${GN}${IPV6_ADDR}${CL}"
echo
echo -e " ${YW}FritzBox — Heimnetz → Netzwerk → IPv6 Firewall / Portfreigabe:${CL}"
echo -e "   TCP ${GN}${TOR_OR_PORT}${CL}   →  ${GN}[${IPV6_ADDR}]:${TOR_OR_PORT}${CL}"
echo -e "   TCP ${GN}${TOR_OBFS4_PORT}${CL} →  ${GN}[${IPV6_ADDR}]:${TOR_OBFS4_PORT}${CL}"
echo
echo -e " ${YW}Useful commands:${CL}"
echo -e "   Logs         : ${GN}pct exec ${VMID} -- cat /var/log/syslog | grep -i tor${CL}"
echo -e "   Reachability : ${GN}https://bridges.torproject.org/scan/scan?address=${IPV6_ADDR}&port=${TOR_OBFS4_PORT}${CL}"
echo -e "   Bridge line  : ${GN}pct exec ${VMID} -- cat /var/lib/tor/pt_state/obfs4_bridgeline.txt${CL}"
echo -e "   torrc        : ${GN}pct exec ${VMID} -- cat /etc/tor/torrc${CL}"
echo
msg_warn "If your ISP renumbers the IPv6 prefix, update torrc ORPort and FritzBox rules."
msg_warn "The EUI-64 suffix (derived from MAC) stays the same across prefix changes."
divider
