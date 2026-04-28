#!/bin/bash
# ============================================================
# setup_isolated_network.sh
# Proxmox: Isoliertes NAT-Netzwerk (vmbr1) + LXC Setup
# Interaktiv – fragt alle Variablen ab
# Als root auf dem Proxmox-Host ausführen
# ============================================================

set -euo pipefail

# ─── Farben ─────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Hilfsfunktionen ────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[FEHLER]${RESET} $*"; exit 1; }
header()  { echo -e "\n${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }
ask()     { echo -e "${BOLD}→ $1${RESET}"; }

confirm() {
    local prompt="${1:-Fortfahren?}"
    while true; do
        read -rp "$(echo -e "${YELLOW}${prompt} [j/n]: ${RESET}")" yn
        case "$yn" in
            [jJyY]) return 0 ;;
            [nN])   return 1 ;;
            *)      echo "Bitte j oder n eingeben." ;;
        esac
    done
}

validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -ra parts <<< "$ip"
        for part in "${parts[@]}"; do
            [[ "$part" -le 255 ]] || return 1
        done
        return 0
    fi
    return 1
}

# Entfernt führende Nullen aus IP-Oktetten (z.B. 10.10.10.03 → 10.10.10.3)
normalize_ip() {
    local ip="$1"
    IFS='.' read -ra parts <<< "$ip"
    local normalized=""
    for part in "${parts[@]}"; do
        part=$((10#$part))   # Oktal-Interpretation verhindern, führende Null entfernen
        normalized="${normalized:+${normalized}.}${part}"
    done
    echo "$normalized"
}

validate_cidr() {
    local cidr="$1"
    local ip="${cidr%%/*}"
    local prefix="${cidr##*/}"
    validate_ip "$ip" && [[ "$prefix" =~ ^[0-9]+$ ]] && [[ "$prefix" -le 32 ]]
}

# ─── Root-Check ─────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    error "Dieses Skript muss als root ausgeführt werden!"
fi

# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Proxmox Isoliertes NAT-Netzwerk Setup      ║${RESET}"
echo -e "${BOLD}║   vmbr1 → Internet (kein LAN-Zugriff)        ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo ""

# ════════════════════════════════════════════════════════════
header "SCHRITT 1: Host-Netzwerk Konfiguration"

# VMBR0
echo ""
ask "Welcher Bridge ist dein bestehender Uplink/Management-Bridge?"
echo -e "  Verfügbare Bridges:"
ip link show type bridge 2>/dev/null | grep -o 'vmbr[0-9]*' | sort -u | while read -r br; do
    ip_addr=$(ip addr show "$br" 2>/dev/null | grep 'inet ' | awk '{print $2}' || true)
    echo -e "    ${CYAN}${br}${RESET}  ${ip_addr}"
done
echo ""
read -rp "  Uplink-Bridge [vmbr0]: " VMBR0
VMBR0="${VMBR0:-vmbr0}"
ip link show "$VMBR0" &>/dev/null || error "Bridge '$VMBR0' nicht gefunden!"
ok "Uplink-Bridge: $VMBR0"

# Host-Netzwerk Modus
echo ""
echo -e "  ${BOLD}Host-Netzwerk:${RESET}"
echo ""
echo -e "  ${CYAN}[1]${RESET} Neuen isolierten Bridge anlegen"
echo -e "  ${CYAN}[2]${RESET} Bestehenden Bridge verwenden (nur iptables-Regeln setzen)"
echo ""
read -rp "  Wahl [1/2]: " HOST_NET_MODE
HOST_NET_MODE="${HOST_NET_MODE:-1}"
[[ "$HOST_NET_MODE" == "1" || "$HOST_NET_MODE" == "2" ]] || error "Ungültige Auswahl"

# VMBR1 Name
echo ""
if [[ "$HOST_NET_MODE" == "1" ]]; then
    ask "Name für den neuen isolierten Bridge:"
    read -rp "  Bridge-Name [vmbr1]: " VMBR1
    VMBR1="${VMBR1:-vmbr1}"
else
    ask "Welchen bestehenden Bridge verwenden?"
    echo -e "  Verfügbare Bridges:"
    ip link show type bridge 2>/dev/null | grep -o 'vmbr[0-9]*' | sort -u | while read -r br; do
        ip_addr=$(ip addr show "$br" 2>/dev/null | grep 'inet ' | awk '{print $2}' || true)
        echo -e "    ${CYAN}${br}${RESET}  ${ip_addr}"
    done
    echo ""
    read -rp "  Bridge-Name: " VMBR1
    ip link show "$VMBR1" &>/dev/null || error "Bridge '$VMBR1' nicht gefunden!"
fi
ok "Isolierter Bridge: $VMBR1"

# VMBR1 IP
echo ""
ask "Gateway-IP für den neuen Bridge (Host-Seite, z.B. 10.10.10.1):"
read -rp "  vmbr1 IP [10.10.10.1]: " VMBR1_IP
VMBR1_IP="${VMBR1_IP:-10.10.10.1}"
validate_ip "$VMBR1_IP" || error "Ungültige IP: $VMBR1_IP"
ok "vmbr1 IP: $VMBR1_IP"

# VMBR1 Subnetz
echo ""
ask "Subnetz für den neuen Bridge (CIDR, z.B. 10.10.10.0/24):"
read -rp "  Subnetz [10.10.10.0/24]: " VMBR1_SUBNET
VMBR1_SUBNET="${VMBR1_SUBNET:-10.10.10.0/24}"
validate_cidr "$VMBR1_SUBNET" || error "Ungültige CIDR-Notation: $VMBR1_SUBNET"
ok "Subnetz: $VMBR1_SUBNET"

# LAN Subnetz
echo ""
ask "Dein privates Heimnetz (wird geblockt, z.B. 192.168.178.0/24):"
echo -e "  ${YELLOW}Tipp: Deine aktuelle Netzwerke:${RESET}"
ip route | grep -v "$VMBR1_SUBNET" | grep -v "10.10.10" | awk '{print "    " $0}' | head -10
echo ""
read -rp "  LAN-Subnetz [192.168.178.0/24]: " LAN_SUBNET
LAN_SUBNET="${LAN_SUBNET:-192.168.178.0/24}"
validate_cidr "$LAN_SUBNET" || error "Ungültige CIDR-Notation: $LAN_SUBNET"
ok "LAN (geblockt): $LAN_SUBNET"

# ════════════════════════════════════════════════════════════
header "SCHRITT 2: Container Modus"

echo ""
echo -e "  ${BOLD}Wie soll der LXC-Container konfiguriert werden?${RESET}"
echo ""
echo -e "  ${CYAN}[1]${RESET} Neuen Container erstellen"
echo -e "  ${CYAN}[2]${RESET} Netzwerk eines bestehenden Containers überschreiben"
echo -e "  ${CYAN}[3]${RESET} Nur Host-Netzwerk einrichten (kein Container)"
echo ""
read -rp "  Wahl [1/2/3]: " CT_MODE
CT_MODE="${CT_MODE:-1}"

case "$CT_MODE" in
    1|2|3) ;;
    *) error "Ungültige Auswahl: $CT_MODE" ;;
esac

# ─── Modus 2: Bestehender Container ─────────────────────────
if [[ "$CT_MODE" == "2" ]]; then
    echo ""
    ask "Bestehende Container:"
    echo ""
    pct list 2>/dev/null || true
    echo ""
    read -rp "  Container-ID zum Überschreiben: " CT_ID
    [[ "$CT_ID" =~ ^[0-9]+$ ]] || error "Ungültige Container-ID"
    pct status "$CT_ID" &>/dev/null || error "Container $CT_ID nicht gefunden!"

    echo ""
    info "Aktuelle Netzwerk-Config von CT $CT_ID:"
    pct config "$CT_ID" | grep "^net" || echo "  (keine net-Konfiguration gefunden)"
    echo ""

    ask "Welches net-Interface soll überschrieben werden? (z.B. net0, net1)"
    read -rp "  Interface [net0]: " CT_NET_IF
    CT_NET_IF="${CT_NET_IF:-net0}"

    ask "Neue IP für den Container in $VMBR1_SUBNET (z.B. 10.10.10.2):"
    read -rp "  Container IP: " CT_IP
    validate_ip "$CT_IP" || error "Ungültige IP: $CT_IP"
    CT_IP=$(normalize_ip "$CT_IP")

    CT_GW="$VMBR1_IP"
    CT_DNS="1.1.1.1"

    echo ""
    ask "DNS-Server [1.1.1.1]:"
    read -rp "  DNS: " CT_DNS
    CT_DNS="${CT_DNS:-1.1.1.1}"
fi

# ─── Modus 1: Neuer Container ────────────────────────────────
if [[ "$CT_MODE" == "1" ]]; then
    echo ""
    header "SCHRITT 3: Neuer Container"

    ask "Container-ID (muss frei sein, z.B. 200):"
    read -rp "  CT-ID: " CT_ID
    [[ "$CT_ID" =~ ^[0-9]+$ ]] || error "Ungültige Container-ID"
    if pct status "$CT_ID" &>/dev/null; then
        error "Container $CT_ID existiert bereits! Andere ID wählen."
    fi
    ok "CT-ID: $CT_ID"

    ask "IP-Adresse des Containers in $VMBR1_SUBNET (z.B. 10.10.10.2):"
    read -rp "  Container IP: " CT_IP
    validate_ip "$CT_IP" || error "Ungültige IP: $CT_IP"
    CT_IP=$(normalize_ip "$CT_IP")
    ok "Container IP: $CT_IP"

    CT_GW="$VMBR1_IP"

    ask "Hostname des Containers:"
    read -rp "  Hostname [isolated-ct]: " CT_HOSTNAME
    CT_HOSTNAME="${CT_HOSTNAME:-isolated-ct}"

    ask "Disk-Größe in GB:"
    read -rp "  Disk [8]: " CT_DISK
    CT_DISK="${CT_DISK:-8}"

    ask "RAM in MB:"
    read -rp "  RAM [512]: " CT_RAM
    CT_RAM="${CT_RAM:-512}"

    ask "CPU-Kerne:"
    read -rp "  Cores [1]: " CT_CORES
    CT_CORES="${CT_CORES:-1}"

    echo ""
    ask "Proxmox Storage-Pool:"
    echo -e "  Verfügbare Storages:"
    pvesm status 2>/dev/null | awk 'NR>1 {printf "    %-20s %s\n", $1, $2}' || true
    echo ""
    read -rp "  Storage [local-lvm]: " STORAGE
    STORAGE="${STORAGE:-local-lvm}"

    ask "Root-Passwort für den Container (wird nicht angezeigt):"
    read -rsp "  Passwort: " ROOT_PW
    echo ""
    read -rsp "  Passwort bestätigen: " ROOT_PW2
    echo ""
    [[ "$ROOT_PW" == "$ROOT_PW2" ]] || error "Passwörter stimmen nicht überein!"
    [[ ${#ROOT_PW} -ge 6 ]] || error "Passwort zu kurz (mind. 6 Zeichen)!"

    ask "DNS-Server [1.1.1.1]:"
    read -rp "  DNS: " CT_DNS
    CT_DNS="${CT_DNS:-1.1.1.1}"
    CT_NET_IF="net0"
fi

# ════════════════════════════════════════════════════════════
header "ZUSAMMENFASSUNG – Bitte prüfen"

echo ""
echo -e "  ${BOLD}Host-Netzwerk:${RESET}"
echo -e "    Uplink-Bridge:     ${CYAN}$VMBR0${RESET}"
echo -e "    Neuer Bridge:      ${CYAN}$VMBR1  (${VMBR1_IP}/$(echo $VMBR1_SUBNET | cut -d/ -f2))${RESET}"
echo -e "    NAT-Subnetz:       ${CYAN}$VMBR1_SUBNET${RESET}"
echo -e "    Geblockt (LAN):    ${CYAN}$LAN_SUBNET${RESET}"
echo ""

if [[ "$CT_MODE" == "1" ]]; then
    echo -e "  ${BOLD}Neuer Container:${RESET}"
    echo -e "    CT-ID:             ${CYAN}$CT_ID${RESET}"
    echo -e "    Hostname:          ${CYAN}$CT_HOSTNAME${RESET}"
    echo -e "    IP:                ${CYAN}${CT_IP}/$(echo $VMBR1_SUBNET | cut -d/ -f2)  (GW: $CT_GW)${RESET}"
    echo -e "    DNS:               ${CYAN}$CT_DNS${RESET}"
    echo -e "    Disk/RAM/Cores:    ${CYAN}${CT_DISK}GB / ${CT_RAM}MB / ${CT_CORES}${RESET}"
    echo -e "    Storage:           ${CYAN}$STORAGE${RESET}"
elif [[ "$CT_MODE" == "2" ]]; then
    echo -e "  ${BOLD}Bestehender Container (Netzwerk überschreiben):${RESET}"
    echo -e "    CT-ID:             ${CYAN}$CT_ID${RESET}"
    echo -e "    Interface:         ${CYAN}$CT_NET_IF${RESET}"
    echo -e "    Neue IP:           ${CYAN}${CT_IP}/$(echo $VMBR1_SUBNET | cut -d/ -f2)  (GW: $CT_GW)${RESET}"
    echo -e "    DNS:               ${CYAN}$CT_DNS${RESET}"
elif [[ "$CT_MODE" == "3" ]]; then
    echo -e "  ${BOLD}Container:${RESET} Wird nicht konfiguriert (nur Host)"
fi

echo ""
confirm "Alles korrekt? Setup jetzt starten?" || { echo "Abgebrochen."; exit 0; }

# ════════════════════════════════════════════════════════════
header "PHASE 1: Host-Netzwerk einrichten"

# vmbr1 schon vorhanden oder Modus "bestehend"?
if [[ "$HOST_NET_MODE" == "2" ]]; then
    info "Verwende bestehenden Bridge $VMBR1 – überspringe /etc/network/interfaces."
    SKIP_IFACES=1
elif ip link show "$VMBR1" &>/dev/null; then
    warn "$VMBR1 existiert bereits. Überspringe /etc/network/interfaces Eintrag."
    warn "Bestehende iptables-Regeln werden trotzdem gesetzt (idempotent)."
    SKIP_IFACES=1
else
    SKIP_IFACES=0
fi

if [[ "$SKIP_IFACES" == "0" ]]; then
    info "Backup von /etc/network/interfaces..."
    cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%Y%m%d_%H%M%S)"

    info "Füge $VMBR1 zu /etc/network/interfaces hinzu..."
    cat >> /etc/network/interfaces << EOF

# Isolierter NAT-Bridge – setup_isolated_network.sh
auto ${VMBR1}
iface ${VMBR1} inet static
    address ${VMBR1_IP}/$(echo $VMBR1_SUBNET | cut -d/ -f2)
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s '${VMBR1_SUBNET}' -o ${VMBR0} -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '${VMBR1_SUBNET}' -o ${VMBR0} -j MASQUERADE
    post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
    post-up   iptables -I FORWARD -i ${VMBR1} -d ${LAN_SUBNET} -j DROP
    post-up   iptables -I FORWARD -o ${VMBR1} -s ${LAN_SUBNET} -j DROP
    post-down iptables -D FORWARD -i ${VMBR1} -d ${LAN_SUBNET} -j DROP
    post-down iptables -D FORWARD -o ${VMBR1} -s ${LAN_SUBNET} -j DROP
EOF
    ok "/etc/network/interfaces aktualisiert."
fi

info "Aktiviere IP-Forwarding in sysctl..."
SYSCTL_CONF="/etc/sysctl.conf"
[[ -f "$SYSCTL_CONF" ]] || touch "$SYSCTL_CONF"
if ! grep -q "net.ipv4.ip_forward" "$SYSCTL_CONF"; then
    echo "net.ipv4.ip_forward=1" >> "$SYSCTL_CONF"
else
    sed -i 's/^#*net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' "$SYSCTL_CONF"
fi
sysctl -p "$SYSCTL_CONF" | grep ip_forward || true
ok "IP-Forwarding aktiv."

info "Lade Netzwerkkonfiguration..."
if command -v ifreload &>/dev/null; then
    ifreload -a
    ok "ifreload erfolgreich."
else
    warn "ifreload nicht gefunden – ggf. Host neustarten!"
fi

# iptables direkt setzen (auch wenn vmbr1 schon existierte)
info "Setze iptables-Regeln..."
echo 1 > /proc/sys/net/ipv4/ip_forward

# NAT (idempotent: erst entfernen, dann hinzufügen)
iptables -t nat -D POSTROUTING -s "$VMBR1_SUBNET" -o "$VMBR0" -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -s "$VMBR1_SUBNET" -o "$VMBR0" -j MASQUERADE

# conntrack zone fix
iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1 2>/dev/null || true
iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1

# FORWARD DROP für LAN
iptables -D FORWARD -i "$VMBR1" -d "$LAN_SUBNET" -j DROP 2>/dev/null || true
iptables -D FORWARD -o "$VMBR1" -s "$LAN_SUBNET" -j DROP 2>/dev/null || true
iptables -I FORWARD -i "$VMBR1" -d "$LAN_SUBNET" -j DROP
iptables -I FORWARD -o "$VMBR1" -s "$LAN_SUBNET" -j DROP

ok "iptables-Regeln gesetzt."

# Verifikation Host
echo ""
info "=== vmbr1 Interface ==="
ip addr show "$VMBR1" 2>/dev/null && ok "$VMBR1 aktiv." || warn "$VMBR1 nicht gefunden – ggf. neustarten!"

info "=== NAT-Regel ==="
iptables -t nat -L POSTROUTING -n | grep "$VMBR1_SUBNET" && ok "MASQUERADE aktiv." || warn "NAT-Regel fehlt!"

info "=== FORWARD DROP ==="
iptables -L FORWARD -n | grep "$LAN_SUBNET" | head -4

# ════════════════════════════════════════════════════════════
if [[ "$CT_MODE" == "3" ]]; then
    echo ""
    ok "Host-Setup abgeschlossen! Container-Setup übersprungen (Modus 3)."
    exit 0
fi

# ════════════════════════════════════════════════════════════
header "PHASE 2: Container einrichten"

NET_CFG="name=eth0,bridge=${VMBR1},ip=${CT_IP}/$(echo $VMBR1_SUBNET | cut -d/ -f2),gw=${CT_GW}"

# ─── Modus 2: Bestehendem Container Netzwerk überschreiben ──
if [[ "$CT_MODE" == "2" ]]; then
    CT_RUNNING=0
    if pct status "$CT_ID" | grep -q "running"; then
        CT_RUNNING=1
    fi

    info "Setze $CT_NET_IF für Container $CT_ID..."
    pct set "$CT_ID" --"$CT_NET_IF" "$NET_CFG"
    ok "Netzwerk-Config gesetzt."

    info "Setze DNS auf $CT_DNS..."
    pct set "$CT_ID" --nameserver "$CT_DNS"

    if [[ "$CT_RUNNING" == "1" ]]; then
        warn "Container läuft gerade. Starte neu damit Netzwerk greift..."
        if confirm "Container $CT_ID jetzt neustarten?"; then
            pct reboot "$CT_ID"
            info "Warte auf Container..."
            sleep 8
        fi
    else
        info "Starte Container $CT_ID..."
        pct start "$CT_ID"
        sleep 5
    fi
fi

# ─── Modus 1: Neuen Container erstellen ─────────────────────
if [[ "$CT_MODE" == "1" ]]; then
    info "Suche Debian-12 Template..."
    TEMPLATE_STORE="local"
    TEMPLATE=$(pveam list "$TEMPLATE_STORE" 2>/dev/null | grep "debian-12" | head -1 | awk '{print $1}')

    if [ -z "$TEMPLATE" ]; then
        info "Kein lokales Debian-12 Template – lade herunter..."
        pveam update
        AVAILABLE=$(pveam available --section system | grep "debian-12-standard" | head -1 | awk '{print $2}')
        [[ -z "$AVAILABLE" ]] && error "Kein debian-12 Template verfügbar. Prüfe Internetverbindung."
        pveam download "$TEMPLATE_STORE" "$AVAILABLE"
        TEMPLATE="${TEMPLATE_STORE}:vztmpl/${AVAILABLE}"
    fi
    ok "Template: $TEMPLATE"

    info "Erstelle Container $CT_ID..."
    pct create "$CT_ID" "$TEMPLATE" \
        --hostname    "$CT_HOSTNAME" \
        --password    "$ROOT_PW" \
        --storage     "$STORAGE" \
        --rootfs      "${STORAGE}:${CT_DISK}" \
        --memory      "$CT_RAM" \
        --cores       "$CT_CORES" \
        --swap        512 \
        --net0        "$NET_CFG" \
        --nameserver  "$CT_DNS" \
        --unprivileged 1 \
        --onboot      1 \
        --features    nesting=0
    ok "Container $CT_ID erstellt."

    info "Starte Container..."
    pct start "$CT_ID"
    sleep 6
fi

# ════════════════════════════════════════════════════════════
header "PHASE 3: Netzwerk-Tests im Container"

echo ""
info "=== Container IP-Config ==="
pct exec "$CT_ID" -- ip addr show eth0 2>/dev/null || warn "eth0 nicht gefunden"

echo ""
info "=== Ping Gateway ($CT_GW) ==="
if pct exec "$CT_ID" -- ping -c 2 -W 2 "$CT_GW" &>/dev/null; then
    ok "Gateway $CT_GW erreichbar ✓"
else
    warn "Gateway nicht erreichbar! Prüfe $VMBR1 auf dem Host."
fi

echo ""
info "=== Ping Internet (1.1.1.1) ==="
if pct exec "$CT_ID" -- ping -c 2 -W 3 "1.1.1.1" &>/dev/null; then
    ok "Internet erreichbar – NAT funktioniert ✓"
else
    warn "Kein Internet! Prüfe iptables MASQUERADE und ip_forward."
fi

echo ""
info "=== Ping LAN (sollte FEHLSCHLAGEN) ==="
LAN_TEST_IP=$(echo "$LAN_SUBNET" | sed 's|\.[0-9]*/.*|.1|')
if pct exec "$CT_ID" -- ping -c 2 -W 2 "$LAN_TEST_IP" &>/dev/null; then
    warn "WARNUNG: LAN $LAN_TEST_IP ist erreichbar! FORWARD-DROP prüfen!"
else
    ok "LAN $LAN_TEST_IP nicht erreichbar – Isolation funktioniert ✓"
fi

# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Setup abgeschlossen!                       ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Bridge:    ${CYAN}${VMBR1}  (${VMBR1_IP})${RESET}"
echo -e "  Subnetz:   ${CYAN}${VMBR1_SUBNET}${RESET}"
echo -e "  CT-ID:     ${CYAN}${CT_ID}${RESET}   IP: ${CYAN}${CT_IP}${RESET}"
echo ""
echo -e "  Shell:  ${YELLOW}pct enter ${CT_ID}${RESET}"
echo -e "  Stopp:  ${YELLOW}pct stop ${CT_ID}${RESET}"
if [[ "$CT_MODE" == "1" ]]; then
    echo ""
    echo -e "  ${RED}WICHTIG: Root-Passwort ändern!${RESET}"
    echo -e "  ${YELLOW}pct exec ${CT_ID} -- passwd root${RESET}"
fi
echo ""
