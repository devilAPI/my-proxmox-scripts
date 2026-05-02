#!/usr/bin/env bash
# ============================================================
#  Tor Bridge LXC — Proxmox Helper Script
#  Inspired by community Proxmox Helper Scripts (tteck style)
#  OS: Debian 13 "Trixie" (unprivileged LXC)
#  Transport: obfs4 via obfs4proxy
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
HOLD="⣿"

header_info() {
  clear
  cat <<"EOF"

  ████████╗ ██████╗ ██████╗     ██████╗ ██████╗ ██╗██████╗  ██████╗ ███████╗
     ██╔══╝██╔═══██╗██╔══██╗    ██╔══██╗██╔══██╗██║██╔══██╗██╔════╝ ██╔════╝
     ██║   ██║   ██║██████╔╝    ██████╔╝██████╔╝██║██║  ██║██║  ███╗█████╗
     ██║   ██║   ██║██╔══██╗    ██╔══██╗██╔══██╗██║██║  ██║██║   ██║██╔══╝
     ██║   ╚██████╔╝██║  ██║    ██████╔╝██║  ██║██║██████╔╝╚██████╔╝███████╗
     ╚═╝    ╚═════╝ ╚═╝  ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚═╝╚═════╝  ╚═════╝ ╚══════╝

            LXC  •  Debian 13 Trixie  •  obfs4  •  Proxmox VE
EOF
  echo
}

msg_info()  { echo -ne " ${INFO} ${YW}$1...${CL}"; }
msg_ok()    { echo -e  "${BFR} ${CM} ${GN}$1${CL}"; }
msg_error() { echo -e  "${BFR} ${CROSS} ${RD}$1${CL}"; }

# ── Guards ─────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  msg_error "Run this script as root on the Proxmox host."
  exit 1
fi

if ! command -v pveversion &>/dev/null; then
  msg_error "This script must run on a Proxmox VE node."
  exit 1
fi

header_info

# ── Helper: ask with default ────────────────────────────────
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

# VMID
NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo 200)
ask "Container ID (VMID)" "$NEXT_ID" VMID

# Hostname
ask "Hostname" "tor-bridge" CT_HOSTNAME

# Cores
ask "CPU cores" "1" CT_CORES

# RAM
ask "RAM in MB" "512" CT_RAM

# Disk
ask "Disk size (e.g. 4G)" "4G" CT_DISK

# Storage
mapfile -t STORAGES < <(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1}')
if [[ ${#STORAGES[@]} -eq 0 ]]; then
  STORAGES=("local-lvm")
fi
echo
echo -e " ${YW}Available storages:${CL}"
for i in "${!STORAGES[@]}"; do
  echo -e "   ${GN}[$((i+1))]${CL} ${STORAGES[$i]}"
done
ask "Storage (name or number)" "${STORAGES[0]}" CT_STORAGE_INPUT
# resolve number → name
if [[ "$CT_STORAGE_INPUT" =~ ^[0-9]+$ ]]; then
  idx=$((CT_STORAGE_INPUT - 1))
  CT_STORAGE="${STORAGES[$idx]:-${STORAGES[0]}}"
else
  CT_STORAGE="$CT_STORAGE_INPUT"
fi

# Network bridge
ask "Network bridge" "vmbr0" CT_BRIDGE

# Static IP or DHCP
echo
echo -e " ${YW}Network IP assignment:${CL}"
echo -e "   ${GN}[1]${CL} DHCP (default)"
echo -e "   ${GN}[2]${CL} Static"
echo -ne " ${YW}Choice${CL} [1]: "
read -r NET_CHOICE
if [[ "$NET_CHOICE" == "2" ]]; then
  ask_required "IP/CIDR (e.g. 192.168.1.50/24)" CT_IP
  ask_required "Gateway (e.g. 192.168.1.1)" CT_GW
  CT_NET="ip=${CT_IP},gw=${CT_GW}"
else
  CT_NET="ip=dhcp"
fi

# ══════════════════════════════════════════════════════════════
#  SECTION 2 — Tor Bridge Settings
# ══════════════════════════════════════════════════════════════
divider
echo -e " ${GN}▶  Tor Bridge Settings${CL}"
divider

ask "OR Port (externally reachable, not 9001)" "4443" TOR_OR_PORT
ask "obfs4 Port (externally reachable, not 9001)" "54791" TOR_OBFS4_PORT
ask "Nickname (alphanumeric, 1–19 chars)" "KrasserBridge" TOR_NICKNAME
ask "Contact e-mail (optional, press Enter to skip)" "" TOR_EMAIL

# ══════════════════════════════════════════════════════════════
#  SECTION 3 — Bandwidth Cap (tc + torrc)
# ══════════════════════════════════════════════════════════════
divider
echo -e " ${GN}▶  Bandwidth / Speed Limit${CL}"
divider
echo -e " ${YW}These values go into torrc (RelayBandwidth*) AND tc on the LXC's veth.${CL}"
echo -e " ${YW}Leave blank to skip a limit.${CL}"
echo
ask "Max bandwidth rate  (e.g. 10 MB = 10485760, or leave blank)" "" TOR_BW_RATE
ask "Max bandwidth burst (e.g. 20 MB = 20971520, or leave blank)" "" TOR_BW_BURST
echo
echo -e " ${YW}tc (kernel traffic shaper) on the Proxmox host veth:${CL}"
echo -e " ${YW}Enter rates like: 10mbit, 500kbit  — or leave blank to skip.${CL}"
ask "tc ingress limit (traffic INTO bridge)" "" TC_INGRESS
ask "tc egress  limit (traffic OUT of bridge)" "" TC_EGRESS

# ══════════════════════════════════════════════════════════════
#  SECTION 4 — Review & Confirm
# ══════════════════════════════════════════════════════════════
divider
echo -e " ${GN}▶  Summary${CL}"
divider
echo -e "  VMID              : ${GN}$VMID${CL}"
echo -e "  Hostname          : ${GN}$CT_HOSTNAME${CL}"
echo -e "  Cores / RAM       : ${GN}${CT_CORES} vCPU / ${CT_RAM} MB${CL}"
echo -e "  Disk / Storage    : ${GN}${CT_DISK} on ${CT_STORAGE}${CL}"
echo -e "  Bridge / Net      : ${GN}${CT_BRIDGE} — ${CT_NET}${CL}"
echo -e "  OR Port           : ${GN}$TOR_OR_PORT${CL}"
echo -e "  obfs4 Port        : ${GN}$TOR_OBFS4_PORT${CL}"
echo -e "  Nickname          : ${GN}$TOR_NICKNAME${CL}"
echo -e "  Contact           : ${GN}${TOR_EMAIL:-"(none)"}${CL}"
echo -e "  torrc BW Rate     : ${GN}${TOR_BW_RATE:-"(unlimited)"}${CL}"
echo -e "  torrc BW Burst    : ${GN}${TOR_BW_BURST:-"(unlimited)"}${CL}"
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
TEMPLATE_PATH=$(pvesm path "${TEMPLATE_STORE}:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst" 2>/dev/null || true)

msg_info "Checking for Debian 13 Trixie template"
if [[ -f "$TEMPLATE_PATH" ]]; then
  msg_ok "Template already present"
else
  msg_info "Downloading Debian 13 Trixie template"
  pveam update &>/dev/null
  TRIXIE_TPL=$(pveam available --section system 2>/dev/null | grep -i "debian-13" | awk '{print $2}' | head -1)
  if [[ -z "$TRIXIE_TPL" ]]; then
    msg_error "Debian 13 template not found in pveam list. Update your template list and retry."
    exit 1
  fi
  pveam download "${TEMPLATE_STORE}" "$TRIXIE_TPL"
  msg_ok "Template downloaded: $TRIXIE_TPL"
  TEMPLATE_PATH=$(pvesm path "${TEMPLATE_STORE}:vztmpl/${TRIXIE_TPL}" 2>/dev/null)
fi

TEMPLATE_VOL="${TEMPLATE_STORE}:vztmpl/$(basename "$TEMPLATE_PATH")"

# ══════════════════════════════════════════════════════════════
#  SECTION 6 — Create LXC
# ══════════════════════════════════════════════════════════════
msg_info "Creating LXC container ${VMID}"

pct create "$VMID" "$TEMPLATE_VOL" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CT_CORES" \
  --memory "$CT_RAM" \
  --rootfs "${CT_STORAGE}:${CT_DISK//G/}" \
  --net0 "name=eth0,bridge=${CT_BRIDGE},${CT_NET}" \
  --unprivileged 1 \
  --features "keyctl=1,nesting=0" \
  --onboot 1 \
  --start 0 \
  --ostype debian \
  --password "$(openssl rand -base64 18)" \
  --description "Tor Bridge (obfs4) — created by tor-bridge-lxc.sh"

msg_ok "LXC ${VMID} created"

# ══════════════════════════════════════════════════════════════
#  SECTION 7 — Start & Bootstrap
# ══════════════════════════════════════════════════════════════
msg_info "Starting container"
pct start "$VMID"
sleep 5
msg_ok "Container started"

# Wait for network
msg_info "Waiting for network inside container"
for i in $(seq 1 20); do
  if pct exec "$VMID" -- ping -c1 -W2 8.8.8.8 &>/dev/null; then break; fi
  sleep 2
done
msg_ok "Network ready"

# ── Build torrc ────────────────────────────────────────────
TORRC="BridgeRelay 1
ORPort ${TOR_OR_PORT}
ServerTransportPlugin obfs4 exec /usr/bin/obfs4proxy
ServerTransportListenAddr obfs4 0.0.0.0:${TOR_OBFS4_PORT}
ExtORPort auto"

[[ -n "$TOR_EMAIL"    ]] && TORRC+="
ContactInfo ${TOR_EMAIL}"
TORRC+="
Nickname ${TOR_NICKNAME}"
[[ -n "$TOR_BW_RATE"  ]] && TORRC+="
RelayBandwidthRate ${TOR_BW_RATE}"
[[ -n "$TOR_BW_BURST" ]] && TORRC+="
RelayBandwidthBurst ${TOR_BW_BURST}"

# ── Install everything inside container ───────────────────
msg_info "Installing Tor & obfs4proxy (this may take a minute)"

pct exec "$VMID" -- bash -c "
set -euo pipefail

# ── unattended-upgrades ──────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq unattended-upgrades apt-listchanges
systemctl enable --now unattended-upgrades

# ── Tor Project repo ─────────────────────────────────────
apt-get install -y -qq apt-transport-https gnupg curl ca-certificates

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc \
  | gpg --dearmor -o /etc/apt/keyrings/tor.gpg

echo 'deb     [signed-by=/etc/apt/keyrings/tor.gpg] https://deb.torproject.org/torproject.org trixie main
deb-src [signed-by=/etc/apt/keyrings/tor.gpg] https://deb.torproject.org/torproject.org trixie main' \
  > /etc/apt/sources.list.d/tor.list

apt-get update -qq
apt-get install -y -qq tor deb.torproject.org-keyring obfs4proxy

# ── torrc ────────────────────────────────────────────────
cat > /etc/tor/torrc << 'TORRCEOF'
${TORRC}
TORRCEOF

# ── enable & start ───────────────────────────────────────
systemctl enable --now tor.service

echo 'DONE'
" 2>&1 | grep -v "^$" | sed "s/^/  /"

msg_ok "Tor bridge installed and running"

# ══════════════════════════════════════════════════════════════
#  SECTION 8 — tc Traffic Shaping on Host
# ══════════════════════════════════════════════════════════════
if [[ -n "$TC_INGRESS" || -n "$TC_EGRESS" ]]; then
  msg_info "Applying tc bandwidth limits on host veth"

  # The veth device for this CT is named veth${VMID}i0 on Proxmox
  VETH="veth${VMID}i0"

  # Wait for veth to appear
  for i in $(seq 1 10); do
    ip link show "$VETH" &>/dev/null && break
    sleep 1
  done

  if ip link show "$VETH" &>/dev/null; then
    # Egress (host → CT, i.e. ingress from CT's view is egress on veth)
    if [[ -n "$TC_EGRESS" ]]; then
      tc qdisc del dev "$VETH" root 2>/dev/null || true
      tc qdisc add dev "$VETH" root tbf rate "${TC_EGRESS}" burst 32kbit latency 400ms
    fi

    # Ingress (CT → host): requires ifb
    if [[ -n "$TC_INGRESS" ]]; then
      modprobe ifb 2>/dev/null || true
      IFB="ifb${VMID}"
      ip link add name "$IFB" type ifb 2>/dev/null || true
      ip link set dev "$IFB" up
      tc qdisc del dev "$VETH" ingress 2>/dev/null || true
      tc qdisc add dev "$VETH" handle ffff: ingress
      tc filter add dev "$VETH" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev "$IFB"
      tc qdisc del dev "$IFB" root 2>/dev/null || true
      tc qdisc add dev "$IFB" root tbf rate "${TC_INGRESS}" burst 32kbit latency 400ms
    fi

    msg_ok "tc rules applied on ${VETH}"

    # ── persist across reboots via post-start hook ──────
    HOOK_DIR="/var/lib/vz/snippets"
    mkdir -p "$HOOK_DIR"
    HOOK="${HOOK_DIR}/tc-tor-bridge-${VMID}.sh"
    cat > "$HOOK" << HOOKEOF
#!/bin/bash
# tc hook for Tor Bridge LXC ${VMID}
# Auto-generated by tor-bridge-lxc.sh
VMID=${VMID}
VETH="veth\${VMID}i0"

if [[ "\$1" == "$VMID" && "\$2" == "post-start" ]]; then
  sleep 3
  $(
    [[ -n "$TC_EGRESS" ]] && echo "  tc qdisc del dev \"\$VETH\" root 2>/dev/null || true"
    [[ -n "$TC_EGRESS" ]] && echo "  tc qdisc add dev \"\$VETH\" root tbf rate ${TC_EGRESS} burst 32kbit latency 400ms"
    if [[ -n "$TC_INGRESS" ]]; then
      echo "  modprobe ifb 2>/dev/null || true"
      echo "  ip link add name ifb${VMID} type ifb 2>/dev/null || true"
      echo "  ip link set dev ifb${VMID} up"
      echo "  tc qdisc del dev \"\$VETH\" ingress 2>/dev/null || true"
      echo "  tc qdisc add dev \"\$VETH\" handle ffff: ingress"
      echo "  tc filter add dev \"\$VETH\" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb${VMID}"
      echo "  tc qdisc del dev ifb${VMID} root 2>/dev/null || true"
      echo "  tc qdisc add dev ifb${VMID} root tbf rate ${TC_INGRESS} burst 32kbit latency 400ms"
    fi
  )
fi
HOOKEOF
    chmod +x "$HOOK"

    # Register hook with the container
    pct set "$VMID" --hookscript "local:snippets/tc-tor-bridge-${VMID}.sh"
    msg_ok "tc hook registered (persists across reboots)"
  else
    msg_error "Could not find veth ${VETH} — tc rules NOT applied. Reboot may be needed."
  fi
fi

# ══════════════════════════════════════════════════════════════
#  DONE
# ══════════════════════════════════════════════════════════════
divider
echo
echo -e " ${GN}✓  Tor Bridge LXC is up and running!${CL}"
echo
echo -e " ${YW}Next steps:${CL}"
echo -e "   1. Open ports ${GN}${TOR_OR_PORT}/tcp${CL} and ${GN}${TOR_OBFS4_PORT}/tcp${CL} on your router/firewall."
echo -e "   2. Monitor logs inside the CT:"
echo -e "      ${GN}pct exec ${VMID} -- journalctl -f -u tor@default${CL}"
echo -e "   3. After ~20 min check reachability:"
echo -e "      ${GN}https://bridges.torproject.org/scan/${CL}"
echo -e "   4. Get your bridge line (share with censored users):"
echo -e "      ${GN}pct exec ${VMID} -- cat /var/lib/tor/pt_state/obfs4_bridgeline.txt${CL}"
echo
divider
