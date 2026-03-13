#!/bin/bash
# =============================================================================
# Скрипт настройки Альт Сервера (Модуль 1: Сетевая инфраструктура)
# КОД 09.02.06-1-2026
# =============================================================================

set -e  # Прерывать выполнение при ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для вывода
print_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_header()  { echo -e "\n${BLUE}════════════════════════════════════════════════════${NC}"; }

# =============================================================================
# ⚙️ КОНФИГУРАЦИЯ
# =============================================================================

# 🎯 Выберите режим: "BR" (Branch) или "HQ" (Headquarters)
MODE="BR"
DOMAIN="au-team.irpo"
HOSTNAME_BASE="srv"

if [[ "$MODE" == "BR" ]]; then
    HOSTNAME="br-${HOSTNAME_BASE}"
    EXTERNAL_IF="enp7s1"
    EXTERNAL_IP="172.16.2.2/28"
    INTERNAL_IF="enp7s2"
    INTERNAL_IP="192.168.0.2/24"
    INTERNAL_NET="192.168.0.0/24"
    DEFAULT_GW="172.16.2.1"
else
    HOSTNAME="hq-${HOSTNAME_BASE}"
    EXTERNAL_IF="enp7s1"
    EXTERNAL_IP="192.168.100.2/27"
    INTERNAL_IF="enp7s2"
    INTERNAL_IP=""
    INTERNAL_NET="192.168.100.0/27"
    DEFAULT_GW="192.168.100.1"
fi

SSH_PORT="22"
SSH_SECURE_PORT="2026"
ROOT_PASS='P@$$w0rd'

# =============================================================================
# 🛡️ ПРОВЕРКИ
# =============================================================================

if [[ $EUID -ne 0 ]]; then
   print_error "Этот скрипт должен запускаться от root (sudo)"
   exit 1
fi

print_header
print_info "🔧 НАСТРОЙКА АЛЬТ СЕРВЕРА — Модуль 1"
print_info "📋 Код: 09.02.06-1-2026"
print_header

print_info "Режим: ${MODE} (${HOSTNAME})"
print_info "Домен: ${DOMAIN}"
print_info ""
print_info "🌐 Сетевая конфигурация:"
print_info "  • Внешний интерфейс: ${EXTERNAL_IF} → ${EXTERNAL_IP}"
[[ -n "$INTERNAL_IP" ]] && print_info "  • Внутренний интерфейс: ${INTERNAL_IF} → ${INTERNAL_IP}"
print_info "  • Локальная сеть: ${INTERNAL_NET}"
print_info "  • Шлюз по умолчанию: ${DEFAULT_GW}"
print_info ""
print_info "🔐 Учётные данные:"
print_info "  • root пароль: ${ROOT_PASS}"
print_info "  • SSH порты: ${SSH_PORT}, ${SSH_SECURE_PORT}"
print_header

read -p "▶️  Продолжить настройку? [y/N]: " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_warn "Настройка отменена пользователем"
    exit 0
fi

# =============================================================================
# 🔧 ОСНОВНАЯ НАСТРОЙКА
# =============================================================================

# 1️⃣ Установка имени сервера
print_info "📛 Установка имени сервера: ${HOSTNAME}.${DOMAIN}..."
hostnamectl set-hostname "${HOSTNAME}.${DOMAIN}" 2>/dev/null || hostnamectl set-hostname "$HOSTNAME"

print_info "📝 Обновление /etc/hosts..."
cat > /etc/hosts << EOF
127.0.0.1   localhost localhost.localdomain
127.0.1.1   ${HOSTNAME}.${DOMAIN} ${HOSTNAME}
::1         localhost localhost.localdomain ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters

# Сеть офиса
${INTERNAL_NET%.*}.1    gateway.${DOMAIN} gateway
${INTERNAL_NET%.*}.255  broadcast.${DOMAIN} broadcast
EOF

sleep 1
CURRENT_HOST=$(hostname)
if [[ "$CURRENT_HOST" == "$HOSTNAME"* ]]; then
    print_info "✅ Имя сервера установлено: $(hostname -f 2>/dev/null || hostname)"
else
    print_warn "⚠️ Имя сервера применится после перезагрузки"
fi

# 2️⃣ Настройка интерфейсов
configure_interface() {
    local iface="$1"
    local ip_addr="$2"
    local is_default_gw="${3:-no}"
    
    [[ -z "$ip_addr" ]] && return 0
    
    print_info "⚙️  Настройка интерфейса ${iface} → ${ip_addr}..."
    
    mkdir -p /etc/net/ifaces/"${iface}"
    
    cat > /etc/net/ifaces/"${iface}"/options << EOF
BOOTPROTO=static
TYPE=eth
DISABLED=no
NM_CONTROLLED=no
CONFIG_IPV4=YES
CONFIG_IPV6=NO
EOF
    
    echo "$ip_addr" > /etc/net/ifaces/"${iface}"/ipv4address
    
    if [[ "$is_default_gw" == "yes" && -n "$DEFAULT_GW" ]]; then
        echo "default via ${DEFAULT_GW}" > /etc/net/ifaces/"${iface}"/route
    fi
    
    print_info "✅ Конфигурация ${iface} сохранена"
}

configure_interface "$EXTERNAL_IF" "$EXTERNAL_IP" "yes"
[[ -n "$INTERNAL_IP" ]] && configure_interface "$INTERNAL_IF" "$INTERNAL_IP" "no"

print_info "🔄 Перезапуск сетевой службы..."
systemctl restart network 2>/dev/null || net restart 2>/dev/null || true

sleep 2
print_info "🔍 Проверка IP-адресов..."
ip -4 addr show | grep -E "inet .*(${EXTERNAL_IF}|${INTERNAL_IF})" || print_warn "⚠️ Интерфейсы могут требовать перезагрузки"

# 3️⃣ Включение IP-форвардинга
print_info "🔀 Включение IP-форвардинга..."

for conf_file in /etc/sysctl.conf /etc/net/sysctl.conf; do
    if [[ -f "$conf_file" ]]; then
        grep -q "^net.ipv4.ip_forward" "$conf_file" 2>/dev/null && \
            sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' "$conf_file" || \
            echo "net.ipv4.ip_forward = 1" >> "$conf_file"
    fi
done

sysctl -p /etc/sysctl.conf 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true

if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" == "1" ]]; then
    print_info "✅ IP-форвардинг включён"
else
    print_warn "⚠️ Не удалось включить форвардинг"
fi

# 4️⃣ Настройка NAT
print_info "🛡️  Настройка NAT (MASQUERADE)..."

iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true

if [[ "$MODE" == "BR" ]]; then
    iptables -t nat -A POSTROUTING -o "$EXTERNAL_IF" -s "$INTERNAL_NET" -j MASQUERADE
    print_info "✅ NAT: ${INTERNAL_NET} → ${EXTERNAL_IF}"
    
    iptables -A FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j ACCEPT
    iptables -A FORWARD -i "$EXTERNAL_IF" -o "$INTERNAL_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT
else
    iptables -t nat -A POSTROUTING -o "$EXTERNAL_IF" -s "192.168.100.0/24" -j MASQUERADE
    print_info "✅ NAT: 192.168.100.0/24 → ${EXTERNAL_IF}"
fi

print_info "💾 Сохранение правил iptables..."
mkdir -p /etc/sysconfig
iptables-save > /etc/sysconfig/iptables

if [[ ! -f /etc/rc.local ]]; then
    cat > /etc/rc.local << 'RCLOCAL'
#!/bin/bash
[ -f /etc/sysconfig/iptables ] && iptables-restore < /etc/sysconfig/iptables
exit 0
RCLOCAL
    chmod +x /etc/rc.local
elif ! grep -q "iptables-restore" /etc/rc.local; then
    sed -i '/^exit 0/d' /etc/rc.local 2>/dev/null || true
    echo "iptables-restore < /etc/sysconfig/iptables" >> /etc/rc.local
    echo "exit 0" >> /etc/rc.local
    chmod +x /etc/rc.local
fi

print_info "✅ Правила iptables сохранены"

# 5️⃣ Настройка безопасности
print_info "🔐 Базовая настройка безопасности..."

for port in "$SSH_PORT" "$SSH_SECURE_PORT"; do
    iptables -A INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
done

iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null || true
iptables-save > /etc/sysconfig/iptables

# 6️⃣ DHCP сервер (опционально)
if [[ "$MODE" == "BR" && "$INTERNAL_IP" == *"192.168.0.1"* ]]; then
    print_info "📡 Установка DHCP-сервера..."
    
    apt-get update -qq 2>/dev/null || true
    apt-get install -y dhcp-server 2>/dev/null || print_warn "⚠️ Не удалось установить dhcp-server"
    
    if [[ -f /etc/dhcp/dhcpd.conf ]]; then
        cat > /etc/dhcp/dhcpd.conf << DHCP
authoritative;

default-lease-time 600;
max-lease-time 7200;

option domain-name "${DOMAIN}";
option domain-name-servers 8.8.8.8, 77.88.8.8;

subnet ${INTERNAL_NET} netmask 255.255.255.0 {
    range 192.168.0.100 192.168.0.200;
    option routers ${INTERNAL_NET%.*}.1;
    option subnet-mask 255.255.255.0;
    option broadcast-address ${INTERNAL_NET%.*}.255;
}
DHCP
        print_info "✅ Конфигурация DHCP сохранена"
    fi
fi

# =============================================================================
# 📊 ФИНАЛЬНЫЙ ОТЧЁТ
# =============================================================================

print_header
print_info "${GREEN}✅ НАСТРОЙКА ЗАВЕРШЕНА!${NC}"
print_header

echo -e "${BLUE}📋 Итоговая конфигурация:${NC}"
echo "  • Имя сервера:      $(hostname -f 2>/dev/null || hostname)"
echo "  • Режим:            ${MODE}"
echo "  • Внешний интерфейс: ${EXTERNAL_IF} → ${EXTERNAL_IP}"
[[ -n "$INTERNAL_IP" ]] && echo "  • Внутренний интерфейс: ${INTERNAL_IF} → ${INTERNAL_IP}"
echo "  • Локальная сеть:   ${INTERNAL_NET}"
echo "  • Шлюз:             ${DEFAULT_GW}"
echo "  • NAT:              включён"
echo "  • SSH порты:        ${SSH_PORT}, ${SSH_SECURE_PORT}"
echo ""

echo -e "${BLUE}🔍 Текущие интерфейсы:${NC}"
ip -br -4 addr show | grep -v "lo" || echo "  (нет IPv4 адресов)"
echo ""

echo -e "${BLUE}🛡️  Правила NAT:${NC}"
iptables -t nat -L POSTROUTING -n -v --line-numbers 2>/dev/null | head -10 || echo "  (нет правил)"
echo ""

echo -e "${BLUE}🔄 Статус форвардинга:${NC}"
echo "  net.ipv4.ip_forward = $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 'unknown')"
echo ""

print_header
echo -e "${YELLOW}📝 Инструкции для клиента:${NC}"
echo ""
echo "1. На клиенте в сети ${INTERNAL_NET} настройте:"
echo "   • IP-адрес:     ${INTERNAL_NET%.*}.100/24"
echo "   • Шлюз:         ${INTERNAL_NET%.*}.1"
echo "   • DNS:          8.8.8.8"
echo ""
echo "2. Проверьте соединение:"
echo "   ping -c 4 ${DEFAULT_GW}"
echo "   ping -c 4 8.8.8.8"
echo ""

print_warn "Для полного применения имени сервера выполните:  reboot"
print_header

exit 0
