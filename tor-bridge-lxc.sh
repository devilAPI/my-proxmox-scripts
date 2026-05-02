#!/usr/bin/env bash
# ============================================================================
#  Tor Bridge LXC — Proxmox Helper Script (IPv6 / DS-Lite friendly)
#  OS:        Debian 13 "Trixie"  (unprivileged LXC)
#  Transport: obfs4 via obfs4proxy
#  Network:   IPv4 outbound (DHCP) + IPv6 SLAAC (kernel default — NO ip6=auto)
#
#  Why no ip6=auto?
#    Proxmox has a known bug where setting ip6=auto on Debian 13 templates
#    writes 'IPv6AcceptRA = false' into systemd-networkd, breaking SLAAC.
#    By only using ip=dhcp, the kernel's default accept_ra=1 takes over and
#    IPv6 SLAAC works automatically.
# ============================================================================

set -uo pipefail   # NO -e: we want to handle failures explicitly with diagnostics

# ── Colours ────────────────────────────────────────────────
YW='\033[33m'; GN='\033[1;92m'; RD='\033[01;31m'; CL='\033[m'
BFR='\r\033[K'
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"; INFO="${YW}⚡${CL}"

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
msg_warn()  { echo -e  " ${YW}⚠  $1${CL}"; }
msg_fatal() { echo -e  "${BFR} ${CROSS} ${RD}$1${CL}"; exit 1; }

ask() {
  local prompt="$1" default="$2" var_name="$3"
  echo -ne " ${YW}${prompt}${CL} [${GN}${default}${CL}]: "
  read -r input
  printf -v "$var_name" '%s' "${input:-$default}"
}
ask_required() {
  local prompt="$1" var_name="$2" value=""
  while [[ -z "$value" ]]; do
    echo -ne " ${YW}${prompt}${CL}: "
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

# ── Guards ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }
command -v pveversion &>/dev/null || { echo "Must run on a Proxmox VE node."; exit 1; }

# ── Cleanup helper ────────────────────────────────────────────────────────
cleanup_on_fail() {
  local vmid="$1"
  if pct status "$vmid" &>/dev/null; then
    echo
    msg_warn "Cleaning up failed container ${vmid}"
    pct stop "$vmid" --force &>/dev/null || true
    sleep 2
    pct destroy "$vmid" --purge &>/dev/null || true
  fi
}

header_info

# ══════════════════════════════════════════════════════════════
#  HOST SANITY CHECK
# ══════════════════════════════════════════════════════════════
divider
echo -e " ${GN}▶  Host sanity check${CL}"
divider

HOST_IPV6_OK=0
if ping6 -c1 -W2 2606:4700:4700::1111 &>/dev/null; then
  echo -e " ${CM} Host has working IPv6 (cloudflare DNS reachable)"
  HOST_IPV6_OK=1
else
  echo -e " ${CROSS} Host CANNOT reach IPv6 internet"
  echo -e "   ${YW}Check vmbr0/router IPv6 first — bridge will be useless without it.${CL}"
  confirm "  Continue anyway?" || exit 0
fi

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
ask "Disk size in GB (number only)" "4" CT_DISK

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

# ══════════════════════════════════════════════════════════════
#  SECTION 2 — Tor Bridge Settings
# ══════════════════════════════════════════════════════════════
divider
echo -e " ${GN}▶  Tor Bridge Settings${CL}"
divider

ask "OR Port (avoid 9001)"    "4443"  TOR_OR_PORT
ask "obfs4 Port (avoid 9001)" "54791" TOR_OBFS4_PORT
ask "Nickname (alphanumeric)" "KrasserBridge" TOR_NICKNAME
ask "Contact e-mail (optional)" "" TOR_EMAIL

# ══════════════════════════════════════════════════════════════
#  SECTION 3 — Bandwidth
# ══════════════════════════════════════════════════════════════
divider
echo -e " ${GN}▶  Bandwidth / Speed Limit${CL}"
divider
echo -e " ${YW}torrc limit (number = MB/s, blank = unlimited):${CL}"
ask "RelayBandwidthRate  in MB/s" "" TOR_BW_RATE
ask "RelayBandwidthBurst in MB/s" "" TOR_BW_BURST
echo
echo -e " ${YW}Kernel-level cap on host veth (e.g. 10mbit, 500kbit, blank=skip):${CL}"
ask "tc ingress (traffic INTO bridge)"  "" TC_INGRESS
ask "tc egress  (traffic OUT of bridge)" "" TC_EGRESS

# ══════════════════════════════════════════════════════════════
#  SECTION 4 — Summary
# ══════════════════════════════════════════════════════════════
divider
echo -e " ${GN}▶  Summary${CL}"
divider
echo -e "  VMID            : ${GN}$VMID${CL}"
echo -e "  Hostname        : ${GN}$CT_HOSTNAME${CL}"
echo -e "  Cores / RAM     : ${GN}${CT_CORES} vCPU / ${CT_RAM} MB${CL}"
echo -e "  Disk / Storage  : ${GN}${CT_DISK}G on ${CT_STORAGE}${CL}"
echo -e "  Bridge          : ${GN}${CT_BRIDGE}${CL}"
echo -e "  IPv4 / IPv6     : ${GN}DHCP / kernel SLAAC${CL}"
echo -e "  OR / obfs4 port : ${GN}${TOR_OR_PORT} / ${TOR_OBFS4_PORT}${CL}"
echo -e "  Nickname        : ${GN}$TOR_NICKNAME${CL}"
echo -e "  Contact         : ${GN}${TOR_EMAIL:-"(none)"}${CL}"
echo -e "  BW Rate / Burst : ${GN}${TOR_BW_RATE:-"∞"} / ${TOR_BW_BURST:-"∞"} MB/s${CL}"
echo -e "  tc in/eg cap    : ${GN}${TC_INGRESS:-"-"} / ${TC_EGRESS:-"-"}${CL}"
divider
echo
confirm "  Proceed?" || { echo " Aborted."; exit 0; }

# ══════════════════════════════════════════════════════════════
#  SECTION 5 — Template
# ══════════════════════════════════════════════════════════════
TEMPLATE_STORE=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1}' | head -1)
TEMPLATE_STORE="${TEMPLATE_STORE:-local}"

msg_info "Locating Debian 13 Trixie template"
pveam update &>/dev/null
TRIXIE_TPL=$(pveam available --section system 2>/dev/null | grep -i "debian-13" | awk '{print $2}' | head -1)
[[ -z "$TRIXIE_TPL" ]] && msg_fatal "Debian 13 template not found in pveam list"

if [[ -f "/var/lib/vz/template/cache/${TRIXIE_TPL}" ]]; then
  msg_ok "Template present"
else
  msg_info "Downloading template ${TRIXIE_TPL}"
  pveam download "${TEMPLATE_STORE}" "$TRIXIE_TPL" 2>&1 | tail -1
  msg_ok "Template ready"
fi
TEMPLATE_VOL="${TEMPLATE_STORE}:vztmpl/${TRIXIE_TPL}"

# ══════════════════════════════════════════════════════════════
#  SECTION 6 — Create LXC  (ip=dhcp ONLY — kernel handles SLAAC)
# ══════════════════════════════════════════════════════════════
msg_info "Creating LXC ${VMID}"

if ! pct create "$VMID" "$TEMPLATE_VOL" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CT_CORES" \
  --memory "$CT_RAM" \
  --rootfs "${CT_STORAGE}:${CT_DISK}" \
  --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
  --unprivileged 1 \
  --features "keyctl=1,nesting=0" \
  --onboot 1 \
  --start 0 \
  --ostype debian \
  --password "$(openssl rand -base64 18)" \
  --description "Tor Bridge (obfs4/IPv6) — tor-bridge-lxc.sh" 2>&1 | tail -5; then
  msg_fatal "pct create failed"
fi
msg_ok "LXC ${VMID} created"

# ══════════════════════════════════════════════════════════════
#  SECTION 7 — Start & wait for network
# ══════════════════════════════════════════════════════════════
msg_info "Starting container"
pct start "$VMID" || { cleanup_on_fail "$VMID"; msg_fatal "pct start failed"; }
sleep 5
msg_ok "Container started"

# Wait for IPv4 (apt needs it)
msg_info "Waiting for IPv4 (DHCP)"
IPV4_OK=0
for i in $(seq 1 30); do
  if pct exec "$VMID" -- ip -4 addr show eth0 2>/dev/null | grep -q 'inet '; then
    IPV4_OK=1; break
  fi
  sleep 2
done
if [[ $IPV4_OK -eq 1 ]]; then
  msg_ok "IPv4 acquired"
else
  msg_warn "No IPv4 after 60s — apt install will likely fail"
fi

# Wait for IPv6 SLAAC
msg_info "Waiting for IPv6 SLAAC (up to 30s)"
IPV6_OK=0
for i in $(seq 1 15); do
  COUNT=$(pct exec "$VMID" -- ip -6 addr show eth0 scope global 2>/dev/null \
    | grep -c 'inet6 ' || true)
  if [[ $COUNT -gt 0 ]]; then
    IPV6_OK=1; break
  fi
  sleep 2
done
if [[ $IPV6_OK -eq 1 ]]; then
  msg_ok "IPv6 SLAAC done"
else
  msg_warn "No IPv6 yet — will continue and ask manually"
fi

# Diagnose: show all addresses
echo
echo -e " ${YW}Container network state:${CL}"
pct exec "$VMID" -- ip -brief addr show eth0 2>&1 | sed 's/^/   /'
echo
echo -e " ${YW}All IPv6 addresses on eth0:${CL}"
pct exec "$VMID" -- ip -6 addr show eth0 2>&1 | grep -E 'inet6|valid_lft' | sed 's/^/   /'
echo

# ══════════════════════════════════════════════════════════════
#  SECTION 8 — Pick a stable IPv6
# ══════════════════════════════════════════════════════════════
divider
echo -e " ${GN}▶  Select stable IPv6 for the bridge${CL}"
divider

# Get all global IPv6, exclude ULA (fd*) and link-local
mapfile -t IPV6_LIST < <(
  pct exec "$VMID" -- ip -6 addr show eth0 scope global 2>/dev/null \
    | grep -oP '(?<=inet6 )[0-9a-f:]+(?=/)' \
    | grep -v '^fd' \
    | grep -v '^fe80' \
    || true
)

# Prefer EUI-64 (contains ff:fe — derived from MAC, never rotates)
IPV6_PICK=""
for addr in "${IPV6_LIST[@]}"; do
  if [[ "$addr" == *"ff:fe"* ]]; then
    IPV6_PICK="$addr"
    break
  fi
done
# Fallback: first non-ULA global
[[ -z "$IPV6_PICK" && ${#IPV6_LIST[@]} -gt 0 ]] && IPV6_PICK="${IPV6_LIST[0]}"

if [[ ${#IPV6_LIST[@]} -gt 0 ]]; then
  echo -e " ${YW}Detected global IPv6 addresses:${CL}"
  for i in "${!IPV6_LIST[@]}"; do
    marker=""
    [[ "${IPV6_LIST[$i]}" == "$IPV6_PICK" ]] && marker=" ${GN}← will be used${CL}"
    [[ "${IPV6_LIST[$i]}" == *"ff:fe"* ]] && marker="${marker} ${GN}(EUI-64, stable)${CL}"
    echo -e "   ${GN}[$((i+1))]${CL} ${IPV6_LIST[$i]}${marker}"
  done
  echo
  ask "Pick number, paste address, or press Enter to accept" "$IPV6_PICK" IPV6_INPUT
  if [[ "$IPV6_INPUT" =~ ^[0-9]+$ ]] && [[ "$IPV6_INPUT" -ge 1 ]] && [[ "$IPV6_INPUT" -le ${#IPV6_LIST[@]} ]]; then
    IPV6_ADDR="${IPV6_LIST[$((IPV6_INPUT - 1))]}"
  else
    IPV6_ADDR="$IPV6_INPUT"
  fi
else
  msg_warn "No global IPv6 detected!"
  msg_warn "Diagnose with: pct exec ${VMID} -- ip -6 addr show eth0"
  ask_required "Enter IPv6 address manually (no brackets)" IPV6_ADDR
fi

msg_ok "Bridge IPv6: ${IPV6_ADDR}"

# ══════════════════════════════════════════════════════════════
#  SECTION 9 — Verify outbound before apt
# ══════════════════════════════════════════════════════════════
msg_info "Testing outbound connectivity inside container"
OUTBOUND_OK=0
if pct exec "$VMID" -- bash -c "ping -c1 -W3 deb.debian.org &>/dev/null"; then
  OUTBOUND_OK=1
  msg_ok "Outbound OK (deb.debian.org reachable)"
else
  msg_warn "deb.debian.org not reachable — apt may fail"
  if confirm "  Show diagnostic info and abort?"; then
    pct exec "$VMID" -- bash -c "
      echo '--- routes ---'; ip route; ip -6 route
      echo '--- resolv.conf ---'; cat /etc/resolv.conf 2>/dev/null
      echo '--- nameserver test ---'; getent hosts deb.debian.org
    "
    cleanup_on_fail "$VMID"
    msg_fatal "Aborted due to no outbound connectivity"
  fi
fi

# ══════════════════════════════════════════════════════════════
#  SECTION 10 — Install Tor
# ══════════════════════════════════════════════════════════════
msg_info "Installing Tor & obfs4proxy (this takes ~1 minute)"

if ! pct exec "$VMID" -- bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq apt-transport-https gnupg curl ca-certificates unattended-upgrades apt-listchanges

systemctl enable --now unattended-upgrades 2>/dev/null || true

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
' 2>&1 | tail -20; then
  msg_warn "apt install hit issues — see output above"
fi
msg_ok "Tor & obfs4proxy installed"

# ══════════════════════════════════════════════════════════════
#  SECTION 11 — Write torrc
# ══════════════════════════════════════════════════════════════

# Auto-detect obfs4proxy path (Debian 13 = /bin, older = /usr/bin)
OBFS4_PATH=$(pct exec "$VMID" -- sh -c 'command -v obfs4proxy 2>/dev/null')
[[ -z "$OBFS4_PATH" ]] && OBFS4_PATH="/bin/obfs4proxy"

TORRC=$(cat <<TORRC_END
# Generated by tor-bridge-lxc.sh — IPv6-only Tor bridge
BridgeRelay 1

# OR port — bound to stable IPv6 (no public IPv4 available behind DS-Lite)
ORPort [${IPV6_ADDR}]:${TOR_OR_PORT}

# obfs4 listens on all interfaces (IPv6 wildcard also accepts IPv4 if any)
ServerTransportPlugin obfs4 exec ${OBFS4_PATH}
ServerTransportListenAddr obfs4 [::]:${TOR_OBFS4_PORT}

ExtORPort auto

Nickname ${TOR_NICKNAME}
TORRC_END
)

[[ -n "$TOR_EMAIL"    ]] && TORRC+="
ContactInfo ${TOR_EMAIL}"
[[ -n "$TOR_BW_RATE"  ]] && TORRC+="
RelayBandwidthRate ${TOR_BW_RATE} MB"
[[ -n "$TOR_BW_BURST" ]] && TORRC+="
RelayBandwidthBurst ${TOR_BW_BURST} MB"

TORRC_TMP=$(mktemp)
printf '%s\n' "$TORRC" > "$TORRC_TMP"
pct push "$VMID" "$TORRC_TMP" /etc/tor/torrc --perms 0644
rm -f "$TORRC_TMP"
msg_ok "torrc written to /etc/tor/torrc"

msg_info "Restarting Tor"
pct exec "$VMID" -- systemctl restart tor@default
sleep 4

# Verify Tor is actually running
if pct exec "$VMID" -- systemctl is-active tor@default &>/dev/null; then
  msg_ok "Tor is running"
else
  msg_warn "Tor failed to start — diagnostic:"
  pct exec "$VMID" -- systemctl status tor@default --no-pager 2>&1 | head -20
  pct exec "$VMID" -- tail -30 /var/log/syslog 2>&1 | grep -i tor || true
fi

# ══════════════════════════════════════════════════════════════
#  SECTION 12 — tc Traffic Shaping
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
      echo "# tc hook for Tor Bridge LXC ${VMID}"
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
    msg_ok "tc hookscript registered"
  else
    msg_warn "veth ${VETH} not found — tc skipped"
  fi
fi

# ══════════════════════════════════════════════════════════════
#  DONE
# ══════════════════════════════════════════════════════════════
divider
echo
echo -e " ${GN}✓  Setup complete${CL}"
echo
echo -e " ${YW}IPv6 address for FritzBox:${CL}"
echo -e "   ${GN}${IPV6_ADDR}${CL}"
echo
echo -e " ${YW}FritzBox → Internet → Freigaben → IPv6:${CL}"
echo -e "   • Aktiviere 'Firewall für delegierte IPv6-Präfixe öffnen'"
echo -e "   • Add rules for: TCP ${GN}${TOR_OR_PORT}${CL} and TCP ${GN}${TOR_OBFS4_PORT}${CL}"
echo -e "   • Target host: ${GN}${IPV6_ADDR}${CL}"
echo
echo -e " ${YW}Verify Tor is happy:${CL}"
echo -e "   ${GN}pct exec ${VMID} -- systemctl status tor@default${CL}"
echo -e "   ${GN}pct exec ${VMID} -- ss -tlnp | grep -E '${TOR_OR_PORT}|${TOR_OBFS4_PORT}'${CL}"
echo
echo -e " ${YW}Reachability scan (after FritzBox rules are set):${CL}"
echo -e "   ${GN}https://bridges.torproject.org/scan/scan?address=${IPV6_ADDR}&port=${TOR_OBFS4_PORT}${CL}"
echo
echo -e " ${YW}Bridge line (~5 min after Tor starts):${CL}"
echo -e "   ${GN}pct exec ${VMID} -- cat /var/lib/tor/pt_state/obfs4_bridgeline.txt${CL}"
echo
msg_warn "If your ISP renumbers the IPv6 prefix (rare), update both torrc & FritzBox."
divider
