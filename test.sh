#!/bin/bash
# =============================================================================
# Скрипт проверки Модуля 1: Настройка сетевой инфраструктуры
# КОД 09.02.06-1-2026
# Версия: 1.1 (обновлённая)
# =============================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# ⚙️ КОНФИГУРАЦИЯ
# =============================================================================

# Домен
DOMAIN="au-team.irpo"

# Учетные данные
ROOT_PASS='P@$$w0rd'
SSHUSER_PASS='P@ssw0rd'
NETADMIN_PASS='P@ssw0rd'

# Порты
PORT_ROOT=22
PORT_SECURE=2026

# 🔥 Хосты с реальными IP-адресами (согласовано с конфигурацией)
declare -A HOSTS=(
    ["ISP"]="172.16.1.1"           # Шлюз для офисов (enp7s2)
    ["HQ-RTR"]="172.16.1.2"        # Основной интерфейс HQ-RTR (ISP side)
    ["BR-RTR"]="172.16.2.2"        # Основной интерфейс BR-RTR (ISP side)
    ["HQ-SRV"]="192.168.100.2"     # Сервер HQ (VLAN 100, /27)
    ["BR-SRV"]="192.168.0.2"       # Сервер BR (BR-Net, /28)
    ["HQ-CLI"]="192.168.200.2"     # Клиент HQ (VLAN 200, DHCP)
)

# Типы устройств
declare -A DEV_TYPE=(
    ["ISP"]="linux"
    ["HQ-RTR"]="ecorouter"
    ["BR-RTR"]="ecorouter"
    ["HQ-SRV"]="linux"
    ["BR-SRV"]="linux"
    ["HQ-CLI"]="linux"
)

# Сети для проверки (маски подсетей)
declare -A SUBNETS=(
    ["ISP_enp7s2"]="172.16.1.0/28"
    ["ISP_enp7s3"]="172.16.2.0/28"
    ["HQ-RTR_vl100"]="192.168.100.0/27"
    ["HQ-RTR_vl200"]="192.168.200.0/24"
    ["HQ-RTR_vl999"]="192.168.99.0/29"
    ["HQ-RTR_isp"]="172.16.1.0/28"
    ["BR-RTR_int1"]="192.168.0.0/28"
    ["BR-RTR_isp"]="172.16.2.0/28"
    ["TUNNEL"]="10.10.10.0/30"
)

# Счетчики
TOTAL=0
PASSED=0
FAILED=0

# Лог файл
LOG_FILE="check_module1_$(date +%Y%m%d_%H%M%S).log"
JSON_FILE="results_module1_$(date +%Y%m%d_%H%M%S).json"

# =============================================================================
# 📦 ФУНКЦИИ
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

print_result() {
    local task="$1"
    local check="$2"
    local status="$3"
    local details="$4"
    
    ((TOTAL++))
    log "TASK:$task CHECK:$check STATUS:$status DETAILS:$details"
    
    if [[ "$status" == "PASS" ]]; then
        ((PASSED++))
        echo -e "${GREEN}[✓]${NC} Задание $task: $check"
    else
        ((FAILED++))
        echo -e "${RED}[✗]${NC} Задание $task: $check"
    fi
    [[ -n "$details" ]] && echo -e "    ${BLUE}ℹ️${NC} $details"
}

# SSH подключение к Linux-устройству
ssh_linux() {
    local host="$1"
    local user="${2:-root}"
    local pass="${3:-$ROOT_PASS}"
    local port="${4:-$PORT_ROOT}"
    local cmd="$5"
    
    sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p "$port" "${user}@${host}" "$cmd" 2>/dev/null
}

# SSH подключение к EcoRouter
ssh_eco() {
    local host="$1"
    local cmd="$2"
    sshpass -p "$ROOT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 "root@${host}" "$cmd" 2>/dev/null
}

# Выполнение команды с учётом типа устройства
exec_cmd() {
    local vm="$1"
    local cmd="$2"
    local dtype="${DEV_TYPE[$vm]}"
    local host="${HOSTS[$vm]}"
    
    if [[ "$dtype" == "ecorouter" ]]; then
        ssh_eco "$host" "$cmd"
    else
        ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "$cmd"
    fi
}

# =============================================================================
# ✅ ПРОВЕРКИ
# =============================================================================

# Задание 1.1: Hostname (FQDN)
check_hostname() {
    local vm="$1"
    local host="${HOSTS[$vm]}"
    local dtype="${DEV_TYPE[$vm]}"
    local expected="${vm,,}.$DOMAIN"
    
    echo -e "\n${YELLOW}>>> Проверка hostname: $vm${NC}"
    
    if [[ "$dtype" == "ecorouter" ]]; then
        [[ "$vm" == "ISP" ]] && { print_result "1.1" "Hostname $vm" "PASS" "ISP - имя без домена"; return; }
        
        local out=$(ssh_eco "$host" "show hostname 2>/dev/null")
        if [[ "$out" == *"$expected"* ]]; then
            print_result "1.1" "Hostname $vm" "PASS" "$out"
        else
            print_result "1.1" "Hostname $vm" "FAIL" "Ожидается: $expected"
        fi
    else
        local out=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "hostname -f 2>/dev/null")
        if [[ "$out" == *"$expected"* ]]; then
            print_result "1.1" "Hostname $vm" "PASS" "$out"
        else
            print_result "1.1" "Hostname $vm" "FAIL" "Ожидается: $expected, получено: $out"
        fi
    fi
}

# Задание 1.2: IPv4 конфигурация и маски подсетей
check_ipv4_subnets() {
    local vm="$1"
    local host="${HOSTS[$vm]}"
    local dtype="${DEV_TYPE[$vm]}"
    
    echo -e "\n${YELLOW}>>> Проверка IPv4 подсетей: $vm${NC}"
    
    if [[ "$dtype" == "ecorouter" ]]; then
        local out=$(ssh_eco "$host" "show ip interface brief 2>/dev/null")
        [[ -n "$out" ]] && print_result "1.2" "IPv4 on $vm" "PASS" "Интерфейсы настроены" \
            || print_result "1.2" "IPv4 on $vm" "FAIL" "Нет IP-адресов"
    else
        local out=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "ip -br addr show 2>/dev/null | grep -v lo")
        if [[ -n "$out" ]]; then
            print_result "1.2" "IPv4 on $vm" "PASS" "Адреса настроены"
            
            # Проверка масок для HQ-RTR
            if [[ "$vm" == "HQ-RTR" ]]; then
                [[ "$out" == *"192.168.100."*"/27"* ]] && \
                    print_result "1.2" "VLAN 100 mask /27" "PASS" "HQ-SRV сеть (32 адреса)" \
                    || print_result "1.2" "VLAN 100 mask /27" "FAIL" "Неверная маска"
                
                [[ "$out" == *"192.168.200."*"/24"* ]] && \
                    print_result "1.2" "VLAN 200 mask /24" "PASS" "HQ-CLI сеть (256 адресов)" \
                    || print_result "1.2" "VLAN 200 mask /24" "FAIL" "Неверная маска"
                
                [[ "$out" == *"192.168.99."*"/29"* ]] && \
                    print_result "1.2" "VLAN 999 mask /29" "PASS" "Management сеть (8 адресов)" \
                    || print_result "1.2" "VLAN 999 mask /29" "FAIL" "Неверная маска"
            fi
            
            # Проверка для BR-SRV (BR-Net /28)
            if [[ "$vm" == "BR-SRV" ]]; then
                [[ "$out" == *"192.168.0."*"/28"* ]] && \
                    print_result "1.2" "BR-SRV mask /28" "PASS" "BR-Net сеть (16 адресов)" \
                    || print_result "1.2" "BR-SRV mask /28" "FAIL" "Неверная маска"
            fi
        else
            print_result "1.2" "IPv4 on $vm" "FAIL" "IP-адреса не найдены"
        fi
    fi
}

# Задание 2: ISP настройка
check_isp_config() {
    local vm="ISP"
    local host="${HOSTS[$vm]}"
    
    echo -e "\n${YELLOW}>>> Проверка ISP конфигурации${NC}"
    
    # Интерфейсы
    local out=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "ip addr show 2>/dev/null")
    if [[ "$out" == *"172.16.1.1/28"* ]] && [[ "$out" == *"172.16.2.1/28"* ]]; then
        print_result "2.1" "ISP interfaces /28" "PASS" "172.16.1.0/28 и 172.16.2.0/28"
    else
        print_result "2.1" "ISP interfaces /28" "FAIL" "Интерфейсы не настроены верно"
    fi
    
    # IP forwarding
    local fwd=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "sysctl net.ipv4.ip_forward 2>/dev/null")
    [[ "$fwd" == *"= 1"* ]] && print_result "2.2" "IP forwarding" "PASS" "Включён" \
        || print_result "2.2" "IP forwarding" "FAIL" "Выключен"
    
    # NAT (MASQUERADE)
    local nat=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "iptables -t nat -L POSTROUTING -n -v 2>/dev/null")
    if [[ "$nat" == *"172.16.1.0/28"*"MASQUERADE"* ]] && [[ "$nat" == *"172.16.2.0/28"*"MASQUERADE"* ]]; then
        print_result "2.3" "NAT MASQUERADE" "PASS" "Обе сети транслируются"
    else
        print_result "2.3" "NAT MASQUERADE" "FAIL" "NAT не настроен корректно"
    fi
    
    # Сохранение правил
    [[ -f "/etc/sysconfig/iptables" ]] && print_result "2.4" "iptables saved" "PASS" "Правила сохранены" \
        || print_result "2.4" "iptables saved" "FAIL" "Файл не найден"
}

# Задание 3: Пользователи
check_users() {
    local vm="$1"
    local host="${HOSTS[$vm]}"
    
    echo -e "\n${YELLOW}>>> Проверка пользователей: $vm${NC}"
    
    if [[ "$vm" == *"SRV"* ]]; then
        # Проверка sshuser UID 2026
        local uid=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "id -u sshuser 2>/dev/null")
        [[ "$uid" == "2026" ]] && print_result "3.1" "sshuser UID 2026" "PASS" "UID=$uid" \
            || print_result "3.1" "sshuser UID 2026" "FAIL" "UID=$uid (ожидалось 2026)"
        
        # Проверка sudo NOPASSWD
        local sudo_cfg=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "grep 'sshuser.*NOPASSWD' /etc/sudoers /etc/sudoers.d/* 2>/dev/null")
        [[ -n "$sudo_cfg" ]] && print_result "3.2" "sshuser sudo NOPASSWD" "PASS" "Настроено" \
            || print_result "3.2" "sshuser sudo NOPASSWD" "FAIL" "Не настроено"
            
    elif [[ "$vm" == *"RTR"* ]]; then
        local dtype="${DEV_TYPE[$vm]}"
        if [[ "$dtype" == "ecorouter" ]]; then
            local eco_user=$(ssh_eco "$host" "show running-config 2>/dev/null | grep 'username net_admin'")
            [[ "$eco_user" == *"net_admin"* ]] && print_result "3.3" "net_admin on $vm" "PASS" "Пользователь создан" \
                || print_result "3.3" "net_admin on $vm" "FAIL" "Пользователь не найден"
        fi
    fi
}

# Задание 4: VLAN конфигурация на HQ-RTR
check_vlans() {
    local vm="HQ-RTR"
    local host="${HOSTS[$vm]}"
    
    echo -e "\n${YELLOW}>>> Проверка VLAN на $vm${NC}"
    
    local out=$(ssh_eco "$host" "show service-instance 2>/dev/null")
    
    [[ "$out" == *"dot1q 100 exact"* ]] && print_result "4.1" "VLAN 100 service-instance" "PASS" "Настроен" \
        || print_result "4.1" "VLAN 100 service-instance" "FAIL" "Не найден"
    
    [[ "$out" == *"dot1q 200 exact"* ]] && print_result "4.2" "VLAN 200 service-instance" "PASS" "Настроен" \
        || print_result "4.2" "VLAN 200 service-instance" "FAIL" "Не найден"
    
    [[ "$out" == *"dot1q 999 exact"* ]] && print_result "4.3" "VLAN 999 service-instance" "PASS" "Настроен" \
        || print_result "4.3" "VLAN 999 service-instance" "FAIL" "Не найден"
    
    # Router-on-a-stick
    local si_count=$(echo "$out" | grep -c "service-instance.*te1/vl")
    [[ "$si_count" -ge 3 ]] && print_result "4.4" "Router-on-a-stick" "PASS" "$si_count SI на te1" \
        || print_result "4.4" "Router-on-a-stick" "FAIL" "Недостаточно service-instance"
}

# Задание 5: Безопасный SSH
check_ssh_security() {
    local vm="$1"
    local host="${HOSTS[$vm]}"
    
    echo -e "\n${YELLOW}>>> Проверка SSH безопасности: $vm${NC}"
    
    # Подключение на порт 2026
    local conn=$(sshpass -p "$SSHUSER_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        -p "$PORT_SECURE" "sshuser@${host}" "echo OK" 2>/dev/null)
    
    [[ "$conn" == "OK" ]] && print_result "5.1" "SSH port 2026" "PASS" "Подключение успешно" \
        || print_result "5.1" "SSH port 2026" "FAIL" "Не удалось подключиться"
    
    # Проверка конфигурации
    local cfg=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "cat /etc/ssh/sshd_config 2>/dev/null")
    
    [[ "$cfg" == *"Port 2026"* ]] && print_result "5.2" "SSH Port 2026" "PASS" "Настроен" \
        || print_result "5.2" "SSH Port 2026" "FAIL" "Порт не 2026"
    
    [[ "$cfg" == *"AllowUsers sshuser"* ]] && print_result "5.3" "AllowUsers sshuser" "PASS" "Настроено" \
        || print_result "5.3" "AllowUsers sshuser" "FAIL" "Не настроено"
    
    [[ "$cfg" == *"MaxAuthTries 2"* ]] && print_result "5.4" "MaxAuthTries 2" "PASS" "Настроено" \
        || print_result "5.4" "MaxAuthTries 2" "FAIL" "Не настроено"
    
    local banner=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "cat /etc/openssh/banner 2>/dev/null")
    [[ "$banner" == *"Authorized access only"* ]] && print_result "5.5" "Banner" "PASS" "Настроен" \
        || print_result "5.5" "Banner" "FAIL" "Не настроен"
}

# Задание 6: IP туннель (GRE)
check_tunnel() {
    echo -e "\n${YELLOW}>>> Проверка IP туннеля (GRE)${NC}"
    
    # HQ-RTR: tunnel.0 с 10.10.10.1/30, источник 172.16.1.2, назначение 172.16.2.2
    local hq_host="${HOSTS["HQ-RTR"]}"
    local hq_out=$(ssh_eco "$hq_host" "show interface tunnel.0 2>/dev/null")
    
    if [[ "$hq_out" == *"10.10.10.1/30"* ]] && [[ "$hq_out" == *"gre"* ]]; then
        print_result "6.1" "Tunnel HQ-RTR" "PASS" "10.10.10.1/30 GRE"
    else
        print_result "6.1" "Tunnel HQ-RTR" "FAIL" "Туннель не настроен"
    fi
    
    # BR-RTR: tunnel.0 с 10.10.10.2/30
    local br_host="${HOSTS["BR-RTR"]}"
    local br_out=$(ssh_eco "$br_host" "show interface tunnel.0 2>/dev/null")
    
    if [[ "$br_out" == *"10.10.10.2/30"* ]] && [[ "$br_out" == *"gre"* ]]; then
        print_result "6.2" "Tunnel BR-RTR" "PASS" "10.10.10.2/30 GRE"
    else
        print_result "6.2" "Tunnel BR-RTR" "FAIL" "Туннель не настроен"
    fi
}

# Задание 7: OSPF с аутентификацией
check_ospf() {
    echo -e "\n${YELLOW}>>> Проверка OSPF маршрутизации${NC}"
    
    for vm in "HQ-RTR" "BR-RTR"; do
        local host="${HOSTS[$vm]}"
        local cfg=$(ssh_eco "$host" "show running-config 2>/dev/null")
        
        if [[ "$cfg" == *"router ospf 1"* ]]; then
            print_result "7.1" "OSPF process on $vm" "PASS" "Протокол настроен"
            
            # Проверка аутентификации на tunnel.0
            local tunnel_cfg=$(ssh_eco "$host" "show interface tunnel.0 2>/dev/null")
            if [[ "$tunnel_cfg" == *"message-digest"* ]] || [[ "$cfg" == *"ip ospf authentication message-digest"* ]]; then
                print_result "7.2" "OSPF MD5 auth on $vm" "PASS" "Аутентификация включена"
            else
                print_result "7.2" "OSPF MD5 auth on $vm" "FAIL" "Аутентификация не найдена"
            fi
            
            # Проверка network statements
            [[ "$cfg" == *"network 10.10.10.0/30 area 0"* ]] && \
                print_result "7.3" "OSPF tunnel network $vm" "PASS" "В области 0" \
                || print_result "7.3" "OSPF tunnel network $vm" "FAIL" "Не в OSPF"
        else
            print_result "7.1" "OSPF process on $vm" "FAIL" "OSPF не настроен"
        fi
    done
}

# Задание 8: Dynamic NAT/SNAT
check_nat_dynamic() {
    echo -e "\n${YELLOW}>>> Проверка динамического NAT${NC}"
    
    for vm in "HQ-RTR" "BR-RTR"; do
        local host="${HOSTS[$vm]}"
        local cfg=$(ssh_eco "$host" "show running-config 2>/dev/null")
        
        if [[ "$vm" == "HQ-RTR" ]]; then
            # Проверка NAT pools и правил
            if [[ "$cfg" == *"ip nat pool VLAN100"* ]] && \
               [[ "$cfg" == *"ip nat source dynamic inside-to-outside pool VLAN100 overload interface isp"* ]]; then
                print_result "8.1" "NAT HQ-RTR VLAN100" "PASS" "Pool + overload"
            else
                print_result "8.1" "NAT HQ-RTR VLAN100" "FAIL" "Не настроен"
            fi
            
            if [[ "$cfg" == *"ip nat pool VLAN200"* ]] && \
               [[ "$cfg" == *"ip nat source dynamic inside-to-outside pool VLAN200 overload interface isp"* ]]; then
                print_result "8.2" "NAT HQ-RTR VLAN200" "PASS" "Pool + overload"
            else
                print_result "8.2" "NAT HQ-RTR VLAN200" "FAIL" "Не настроен"
            fi
        else
            # BR-RTR
            if [[ "$cfg" == *"ip nat pool BR-Net"* ]] && \
               [[ "$cfg" == *"ip nat source dynamic inside-to-outside pool BR-Net overload interface isp"* ]]; then
                print_result "8.3" "NAT BR-RTR BR-Net" "PASS" "Pool + overload"
            else
                print_result "8.3" "NAT BR-RTR BR-Net" "FAIL" "Не настроен"
            fi
        fi
    done
}

# Задание 9: DHCP сервер на HQ-RTR
check_dhcp() {
    local vm="HQ-RTR"
    local host="${HOSTS[$vm]}"
    
    echo -e "\n${YELLOW}>>> Проверка DHCP сервера (HQ-RTR для VLAN 200)${NC}"
    
    # Проверка IP pool и DHCP активации
    local cfg=$(ssh_eco "$host" "show running-config 2>/dev/null")
    
    if [[ "$cfg" == *"ip pool VLAN200"* ]] && [[ "$cfg" == *"range 192.168.200.2-192.168.200.254"* ]]; then
        print_result "9.1" "DHCP pool VLAN200" "PASS" "Диапазон адресов настроен"
    else
        print_result "9.1" "DHCP pool VLAN200" "FAIL" "Pool не настроен"
    fi
    
    if [[ "$cfg" == *"gateway 192.168.200.1"* ]] && [[ "$cfg" == *"dns 192.168.100.2"* ]]; then
        print_result "9.2" "DHCP options" "PASS" "Gateway и DNS указаны"
    else
        print_result "9.2" "DHCP options" "FAIL" "Опции не настроены"
    fi
    
    if [[ "$cfg" == *"domain-name au-team.irpo"* ]]; then
        print_result "9.3" "DHCP domain-name" "PASS" "DNS суффикс настроен"
    else
        print_result "9.3" "DHCP domain-name" "FAIL" "Суффикс не найден"
    fi
    
    # Проверка привязки DHCP к интерфейсу
    if [[ "$cfg" == *"interface vl200"* ]] && [[ "$cfg" == *"dhcp-server 1"* ]]; then
        print_result "9.4" "DHCP on vl200" "PASS" "Служба привязана к интерфейсу"
    else
        print_result "9.4" "DHCP on vl200" "FAIL" "Привязка не найдена"
    fi
}

# Задание 10: DNS сервер на HQ-SRV
check_dns() {
    local vm="HQ-SRV"
    local host="${HOSTS[$vm]}"
    
    echo -e "\n${YELLOW}>>> Проверка DNS сервера (BIND на HQ-SRV)${NC}"
    
    # Проверка службы
    local svc=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "systemctl is-active bind.service 2>/dev/null")
    [[ "$svc" == *"active"* ]] && print_result "10.1" "BIND service" "PASS" "Служба запущена" \
        || print_result "10.1" "BIND service" "FAIL" "Служба не активна"
    
    # Проверка зон
    local zone_check=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "ls /var/lib/bind/etc/zone/ 2>/dev/null")
    [[ "$zone_check" == *"au-team.irpo"* ]] && print_result "10.2" "Forward zone" "PASS" "au-team.irpo" \
        || print_result "10.2" "Forward zone" "FAIL" "Зона не найдена"
    
    [[ "$zone_check" == *"100.168.192.in-addr.arpa"* ]] && print_result "10.3" "Reverse zone VLAN100" "PASS" "Настроена" \
        || print_result "10.3" "Reverse zone VLAN100" "FAIL" "Не найдена"
    
    [[ "$zone_check" == *"200.168.192.in-addr.arpa"* ]] && print_result "10.4" "Reverse zone VLAN200" "PASS" "Настроена" \
        || print_result "10.4" "Reverse zone VLAN200" "FAIL" "Не найдена"
    
    # Проверка записей A
    local lookup=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "dig +short hq-srv.$DOMAIN @localhost 2>/dev/null")
    [[ "$lookup" == "192.168.100.2" ]] && print_result "10.5" "A-record hq-srv" "PASS" "$lookup" \
        || print_result "10.5" "A-record hq-srv" "FAIL" "Неверная запись"
    
    # Проверка forwarder
    local fwd=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "grep 'forwarders' /var/lib/bind/etc/options.conf 2>/dev/null")
    [[ "$fwd" == *"77.88.8.8"* ]] && print_result "10.6" "DNS forwarder" "PASS" "Yandex DNS" \
        || print_result "10.6" "DNS forwarder" "FAIL" "Не настроен"
}

# Задание 11: Часовой пояс
check_timezone() {
    echo -e "\n${YELLOW}>>> Проверка часового пояса (Asia/Yakutsk)${NC}"
    
    for vm in "${!HOSTS[@]}"; do
        local host="${HOSTS[$vm]}"
        local dtype="${DEV_TYPE[$vm]}"
        
        if [[ "$dtype" == "ecorouter" ]]; then
            local tz=$(ssh_eco "$host" "show clock 2>/dev/null")
            [[ "$tz" == *"UTC+9"* ]] || [[ "$tz" == *"+09"* ]] && \
                print_result "11" "Timezone $vm" "PASS" "$tz" \
                || print_result "11" "Timezone $vm" "FAIL" "Не UTC+9"
        else
            local tz=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "timedatectl | grep 'Time zone' 2>/dev/null")
            [[ "$tz" == *"Asia/Yakutsk"* ]] && \
                print_result "11" "Timezone $vm" "PASS" "$tz" \
                || print_result "11" "Timezone $vm" "FAIL" "Не Asia/Yakutsk"
        fi
    done
}

# =============================================================================
# 🚀 ЗАПУСК ПРОВЕРКИ
# =============================================================================

run_checks() {
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  ПРОВЕРКА МОДУЛЯ 1: Сетевая инфраструктура${NC}"
    echo -e "${BLUE}  КОД 09.02.06-1-2026 | Версия 1.1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    
    log "=== START Module 1 Check v1.1 ==="
    
    # Задание 1: Hostname и IPv4
    for vm in "${!HOSTS[@]}"; do
        check_hostname "$vm"
        check_ipv4_subnets "$vm"
    done
    
    # Задание 2: ISP
    check_isp_config
    
    # Задание 3: Пользователи
    for vm in "HQ-SRV" "BR-SRV" "HQ-RTR" "BR-RTR"; do
        check_users "$vm"
    done
    
    # Задание 4: VLAN
    check_vlans
    
    # Задание 5: SSH Security
    for vm in "HQ-SRV" "BR-SRV"; do
        check_ssh_security "$vm"
    done
    
    # Задание 6: Tunnel
    check_tunnel
    
    # Задание 7: OSPF
    check_ospf
    
    # Задание 8: Dynamic NAT
    check_nat_dynamic
    
    # Задание 9: DHCP
    check_dhcp
    
    # Задание 10: DNS
    check_dns
    
    # Задание 11: Timezone
    check_timezone
    
    print_summary
}

print_summary() {
    echo -e "\n${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  ИТОГОВЫЙ ОТЧЕТ${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "Всего проверок: ${TOTAL}"
    echo -e "${GREEN}✅ Пройдено: ${PASSED}${NC}"
    echo -e "${RED}❌ Не пройдено: ${FAILED}${NC}"
    
    if [[ $TOTAL -gt 0 ]]; then
        local percent=$((PASSED * 100 / TOTAL))
        echo -e "📊 Успешность: ${percent}%"
    fi
    
    # JSON-отчет
    cat > "$JSON_FILE" << EOF
{
  "module": "Module 1 - Network Infrastructure",
  "kod": "09.02.06-1-2026",
  "version": "1.1",
  "timestamp": "$(date -Iseconds)",
  "total_checks": $TOTAL,
  "passed_checks": $PASSED,
  "failed_checks": $FAILED,
  "success_rate": "$((TOTAL > 0 ? PASSED * 100 / TOTAL : 0))%"
}
EOF
    
    echo -e "\n💾 Результаты сохранены:"
    echo "   📄 $LOG_FILE"
    echo "   📊 $JSON_FILE"
    
    log "=== END Module 1 Check v1.1 ==="
}

# =============================================================================
# 🎯 MAIN
# =============================================================================

main() {
    if ! command -v sshpass &>/dev/null; then
        echo -e "${RED}❌ Ошибка: не установлен sshpass${NC}"
        echo "Установите: sudo apt install sshpass  # для Debian/Alt Linux"
        exit 1
    fi
    
    if ! command -v ssh &>/dev/null; then
        echo -e "${RED}❌ Ошибка: не установлен ssh клиент${NC}"
        exit 1
    fi
    
    run_checks
}

main "$@"
