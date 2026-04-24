#!/bin/bash
set -u

# ============================================================================
# module2_test.sh
# Проверка стенда Модуль 2.
# Основано на module2_auto_setup.sh: Linux-проверки через qm guest exec,
# проверки EcoRouter HQ-RTR / BR-RTR через qm terminal + expect.
# ============================================================================

VM_ISP=11701
VM_HQ_RTR=11702
VM_HQ_SRV=11703
VM_HQ_CLI=11704
VM_BR_RTR=11705
VM_BR_SRV=11706

PRIMARY_ROUTER_LOGIN="admin"
PRIMARY_ROUTER_PASSWORD="admin"
FALLBACK_ROUTER_LOGIN="net_admin"
FALLBACK_ROUTER_PASSWORD="P@ssw0rd"

CONFIG_DIR="/root/module2_check"
mkdir -p "$CONFIG_DIR"

PASS=0
FAIL=0
WARN=0

if [ -t 1 ]; then
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
else
    C_RESET=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
    C_BOLD=''
fi

print_header() {
    echo
    echo -e "${C_CYAN}════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD} $1${C_RESET}"
    echo -e "${C_CYAN}════════════════════════════════════════════════════════${C_RESET}"
}

print_check() {
    local msg="$1"
    local status="$2"

    if [ "$status" = "PASS" ]; then
        echo -e "  ${C_GREEN}✓${C_RESET} $msg"
        PASS=$((PASS + 1))
    elif [ "$status" = "FAIL" ]; then
        echo -e "  ${C_RED}✗${C_RESET} $msg"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${C_YELLOW}⚠${C_RESET} $msg"
        WARN=$((WARN + 1))
    fi
}

print_info() { echo -e "${C_BLUE}[INFO]${C_RESET} $1"; }
print_step() { echo -e "${C_YELLOW}[ШАГ]${C_RESET} $1"; }
print_ok() { echo -e "${C_GREEN}[✓]${C_RESET} $1"; }
print_fail() { echo -e "${C_RED}[✗]${C_RESET} $1"; }

need_tools() {
    print_header "ПОДГОТОВКА"
    for cmd in qm expect awk sed grep timeout; do
        if command -v "$cmd" >/dev/null 2>&1; then
            :
        else
            print_fail "Не найдена команда: $cmd"
            exit 1
        fi
    done
    print_check "qm / expect / awk / sed / grep / timeout доступны" "PASS"
}

check_vm_guest_exec() {
    local vmid="$1"
    qm guest exec "$vmid" -- echo OK >/dev/null 2>&1
}

guest_exec() {
    local vmid="$1"
    local cmd="$2"
    local result

    result=$(qm guest exec "$vmid" -- bash -lc "$cmd" 2>/dev/null || true)

    echo "$result" | grep -o '"out-data"[[:space:]]*:[[:space:]]*"[^"]*"' | \
        sed 's/"out-data"[[:space:]]*:[[:space:]]*"//' | \
        sed 's/"$//' | \
        sed 's/\\n/\n/g' | \
        sed 's/\\t/\t/g' | \
        sed 's/\\\//\//g' | \
        sed 's/\\r//g'
}

ensure_router_ready() {
    local vmid="$1"
    local status

    print_step "Проверка статуса VM $vmid..."
    status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    print_info "Статус: ${status:-unknown}"

    if [ "${status:-}" != "running" ]; then
        print_fail "ВМ $vmid не запущена"
        return 1
    fi

    print_step "Проверка serial0..."
    if ! qm config "$vmid" 2>/dev/null | grep -q '^serial0:'; then
        print_info "serial0 отсутствует, добавляю..."
        qm stop "$vmid" >/dev/null 2>&1 || true
        qm set "$vmid" -serial0 socket >/dev/null 2>&1
        qm start "$vmid" >/dev/null 2>&1
        sleep 25
    fi

    print_ok "ВМ $vmid готова"
    return 0
}

make_export_expect() {
    local vmid="$1"
    local expscript="$2"

    cat > "$expscript" <<'EOF_EXP'
#!/usr/bin/expect -f
set timeout 20
match_max 200000
log_user 1

set primary_login "__PRIMARY_LOGIN__"
set primary_password "__PRIMARY_PASSWORD__"
set fallback_login "__FALLBACK_LOGIN__"
set fallback_password "__FALLBACK_PASSWORD__"
set vmid "__VMID__"

proc wait_prompt {} {
    set loops 0
    while {$loops < 120} {
        expect {
            -re {--More--.*} {
                send " "
                exp_continue
            }
            -re {login:\s*$} {
                return "login"
            }
            -re {Password:\s*$} {
                return "password"
            }
            -re {>\s*$} {
                return "user"
            }
            -re {#\s*$} {
                return "priv"
            }
            timeout {
                send "\r"
                incr loops
                exp_continue
            }
            eof {
                return "eof"
            }
        }
    }
    return "timeout"
}

proc do_login {login password} {
    send "\r"
    set state [wait_prompt]

    if {$state eq "login"} {
        send -- "$login\r"
        set state [wait_prompt]
    }

    if {$state eq "password"} {
        send -- "$password\r"
        set state [wait_prompt]
    }

    if {$state eq "user"} {
        send "enable\r"
        set state [wait_prompt]
    }

    return $state
}

spawn qm terminal $vmid
sleep 2

set state [do_login $primary_login $primary_password]
if {$state ne "priv"} {
    send "\r"
    sleep 1
    set state [do_login $fallback_login $fallback_password]
}

if {$state ne "priv"} {
    exit 41
}

send "show running-config\r"

while {1} {
    expect {
        -re {--More--.*} {
            send " "
            exp_continue
        }
        -re {#\s*$} {
            break
        }
        timeout {
            send "\r"
            exp_continue
        }
        eof {
            break
        }
    }
}

send "exit\r"
expect eof
EOF_EXP

    sed -i "s/__PRIMARY_LOGIN__/$(printf '%s' "$PRIMARY_ROUTER_LOGIN" | sed 's/[\/&]/\\&/g')/g" "$expscript"
    sed -i "s/__PRIMARY_PASSWORD__/$(printf '%s' "$PRIMARY_ROUTER_PASSWORD" | sed 's/[\/&]/\\&/g')/g" "$expscript"
    sed -i "s/__FALLBACK_LOGIN__/$(printf '%s' "$FALLBACK_ROUTER_LOGIN" | sed 's/[\/&]/\\&/g')/g" "$expscript"
    sed -i "s/__FALLBACK_PASSWORD__/$(printf '%s' "$FALLBACK_ROUTER_PASSWORD" | sed 's/[\/&]/\\&/g')/g" "$expscript"
    sed -i "s/__VMID__/$vmid/g" "$expscript"

    chmod +x "$expscript"
}

clean_export_file() {
    local rawfile="$1"
    local cleanfile="$2"

    cp "$rawfile" "$cleanfile"
    sed -i 's/\r//g' "$cleanfile"
    sed -E -i 's/\x1b\[[0-9;?]*[[:alpha:]]//g' "$cleanfile"
    sed -i '/^spawn qm terminal/d' "$cleanfile"
    sed -i '/^starting serial terminal/d' "$cleanfile"
    sed -i '/press Ctrl+O/d' "$cleanfile"
    sed -i '/^User Access Verification$/d' "$cleanfile"
    sed -i '/^EcoRouterOS version /d' "$cleanfile"
    sed -i '/^<<< EcoRouter /d' "$cleanfile"
    sed -i '/^.* login: .*$/d' "$cleanfile"
    sed -i '/^Password:$/d' "$cleanfile"
    sed -i '/^.*>enable$/d' "$cleanfile"
    sed -i '/^.*#show running-config$/d' "$cleanfile"
    sed -i '/^.*#exit$/d' "$cleanfile"
    sed -i '/^--More--.*$/d' "$cleanfile"
    sed -i '/^.*#$/d' "$cleanfile"

    awk 'NF{blank=0; print; next} !blank{print; blank=1}' "$cleanfile" > "${cleanfile}.tmp"
    mv "${cleanfile}.tmp" "$cleanfile"
}

export_running_config() {
    local vmid="$1"
    local name="$2"
    local rawfile="$CONFIG_DIR/${name}_raw.txt"
    local cleanfile="$CONFIG_DIR/${name}_running_config.txt"
    local expscript="/tmp/exp_export_${vmid}.exp"

    print_header "ПОЛУЧЕНИЕ КОНФИГУРАЦИИ $name (VM $vmid)"
    ensure_router_ready "$vmid" || return 1

    print_step "Создание expect-скрипта export..."
    make_export_expect "$vmid" "$expscript"

    print_step "Запуск export..."
    timeout 180 /usr/bin/expect "$expscript" > "$rawfile" 2>&1
    local rc=$?
    rm -f "$expscript"
    print_info "Код возврата expect: $rc"

    print_step "Очистка вывода..."
    clean_export_file "$rawfile" "$cleanfile"

    local size lines
    size=$(wc -c < "$cleanfile" 2>/dev/null || echo 0)
    lines=$(wc -l < "$cleanfile" 2>/dev/null || echo 0)
    print_info "Размер: $size байт | Строк: $lines"

    if grep -q '^hostname ' "$cleanfile"; then
        print_ok "Конфигурация сохранена: $cleanfile"
        return 0
    fi

    print_fail "Нормальный running-config не получен"
    head -40 "$cleanfile" 2>/dev/null || true
    return 1
}

check_regex() {
    local file="$1"
    local regex="$2"
    local desc="$3"

    if grep -Eqi "$regex" "$file" 2>/dev/null; then
        print_check "$desc" "PASS"
    else
        print_check "$desc" "FAIL"
    fi
}

check_isp() {
    print_header "ISP (VM $VM_ISP)"

    if ! check_vm_guest_exec "$VM_ISP"; then
        print_check "QM Guest Exec доступен" "FAIL"
        return 1
    fi
    print_check "QM Guest Exec доступен" "PASS"

    local result
    result=$(guest_exec "$VM_ISP" "hostname")
    [ -n "$result" ] && print_check "hostname получен ($result)" "PASS" || print_check "hostname получен" "FAIL"

    result=$(guest_exec "$VM_ISP" "grep -E '^local stratum 5' /etc/chrony.conf 2>/dev/null")
    [ -n "$result" ] && print_check "chrony: local stratum 5" "PASS" || print_check "chrony: local stratum 5" "FAIL"

    result=$(guest_exec "$VM_ISP" "systemctl is-active nginx 2>/dev/null")
    [[ "$result" == *active* ]] && print_check "nginx active" "PASS" || print_check "nginx active ($result)" "FAIL"

    result=$(guest_exec "$VM_ISP" "grep -E '^WEB:' /etc/nginx/.htpasswd 2>/dev/null")
    [ -n "$result" ] && print_check "basic auth пользователь WEB" "PASS" || print_check "basic auth пользователь WEB" "FAIL"

    result=$(guest_exec "$VM_ISP" "grep -E 'server_name[[:space:]]+web\\.au-team\\.irpo' /etc/nginx/sites-available.d/default.conf 2>/dev/null")
    [ -n "$result" ] && print_check "reverse proxy: web.au-team.irpo" "PASS" || print_check "reverse proxy: web.au-team.irpo" "FAIL"

    result=$(guest_exec "$VM_ISP" "grep -E 'proxy_pass[[:space:]]+http://172\\.16\\.1\\.2:8080' /etc/nginx/sites-available.d/default.conf 2>/dev/null")
    [ -n "$result" ] && print_check "proxy_pass -> 172.16.1.2:8080" "PASS" || print_check "proxy_pass -> 172.16.1.2:8080" "FAIL"

    result=$(guest_exec "$VM_ISP" "grep -E 'server_name[[:space:]]+docker\\.au-team\\.irpo' /etc/nginx/sites-available.d/default.conf 2>/dev/null")
    [ -n "$result" ] && print_check "reverse proxy: docker.au-team.irpo" "PASS" || print_check "reverse proxy: docker.au-team.irpo" "FAIL"

    result=$(guest_exec "$VM_ISP" "grep -E 'proxy_pass[[:space:]]+http://172\\.16\\.2\\.2:8080' /etc/nginx/sites-available.d/default.conf 2>/dev/null")
    [ -n "$result" ] && print_check "proxy_pass -> 172.16.2.2:8080" "PASS" || print_check "proxy_pass -> 172.16.2.2:8080" "FAIL"
}

check_hq_srv() {
    print_header "HQ-SRV (VM $VM_HQ_SRV)"

    if ! check_vm_guest_exec "$VM_HQ_SRV"; then
        print_check "QM Guest Exec доступен" "FAIL"
        return 1
    fi
    print_check "QM Guest Exec доступен" "PASS"

    local result

    result=$(guest_exec "$VM_HQ_SRV" "cat /proc/mdstat 2>/dev/null | grep -E '^md0' || true")
    [ -n "$result" ] && print_check "RAID md0 присутствует" "PASS" || print_check "RAID md0 присутствует" "FAIL"

    result=$(guest_exec "$VM_HQ_SRV" "mount | grep ' on /raid ' || true")
    [ -n "$result" ] && print_check "/raid смонтирован" "PASS" || print_check "/raid смонтирован" "FAIL"

    result=$(guest_exec "$VM_HQ_SRV" "grep -E '/raid[[:space:]]+ext4' /etc/fstab 2>/dev/null")
    [ -n "$result" ] && print_check "/raid в fstab" "PASS" || print_check "/raid в fstab" "FAIL"

    result=$(guest_exec "$VM_HQ_SRV" "grep -E '^/raid/nfs ' /etc/exports 2>/dev/null")
    [ -n "$result" ] && print_check "NFS export /raid/nfs" "PASS" || print_check "NFS export /raid/nfs" "FAIL"

    result=$(guest_exec "$VM_HQ_SRV" "systemctl is-active nfs-server 2>/dev/null")
    [[ "$result" == *active* ]] && print_check "nfs-server active" "PASS" || print_check "nfs-server active ($result)" "FAIL"

    result=$(guest_exec "$VM_HQ_SRV" "grep -E '^server[[:space:]]+172\\.16\\.1\\.1[[:space:]]+iburst' /etc/chrony.conf 2>/dev/null")
    [ -n "$result" ] && print_check "chrony -> 172.16.1.1" "PASS" || print_check "chrony -> 172.16.1.1" "FAIL"

    result=$(guest_exec "$VM_HQ_SRV" "systemctl is-active mariadb 2>/dev/null")
    [[ "$result" == *active* ]] && print_check "mariadb active" "PASS" || print_check "mariadb active ($result)" "FAIL"

    result=$(guest_exec "$VM_HQ_SRV" "mariadb -u root -e \"SHOW DATABASES LIKE 'webdb';\" 2>/dev/null | grep webdb || true")
    [ -n "$result" ] && print_check "БД webdb создана" "PASS" || print_check "БД webdb создана" "FAIL"

    result=$(guest_exec "$VM_HQ_SRV" "mariadb -u root -e \"SELECT User FROM mysql.user WHERE User='webc';\" 2>/dev/null | grep webc || true")
    [ -n "$result" ] && print_check "пользователь БД webc создан" "PASS" || print_check "пользователь БД webc создан" "FAIL"

    result=$(guest_exec "$VM_HQ_SRV" "ss -tulpn 2>/dev/null | grep ':80 ' || true")
    [ -n "$result" ] && print_check "web слушает 80/tcp" "PASS" || print_check "web слушает 80/tcp" "FAIL"

    result=$(guest_exec "$VM_HQ_SRV" "grep -E '^Port 2026' /etc/openssh/sshd_config 2>/dev/null")
    [ -n "$result" ] && print_check "SSH port 2026" "PASS" || print_check "SSH port 2026" "FAIL"
}

check_br_srv() {
    print_header "BR-SRV (VM $VM_BR_SRV)"

    if ! check_vm_guest_exec "$VM_BR_SRV"; then
        print_check "QM Guest Exec доступен" "FAIL"
        return 1
    fi
    print_check "QM Guest Exec доступен" "PASS"

    local result

    result=$(guest_exec "$VM_BR_SRV" "systemctl is-active samba 2>/dev/null")
    [[ "$result" == *active* ]] && print_check "samba active" "PASS" || print_check "samba active ($result)" "FAIL"

    result=$(guest_exec "$VM_BR_SRV" "samba-tool domain info 127.0.0.1 2>/dev/null | grep -E 'Realm|Domain' || true")
    [ -n "$result" ] && print_check "домен Samba DC создан" "PASS" || print_check "домен Samba DC создан" "FAIL"

    result=$(guest_exec "$VM_BR_SRV" "samba-tool group list 2>/dev/null | grep '^hq$' || true")
    [ -n "$result" ] && print_check "группа hq создана" "PASS" || print_check "группа hq создана" "FAIL"

    result=$(guest_exec "$VM_BR_SRV" "samba-tool user list 2>/dev/null | grep '^hquser5$' || true")
    [ -n "$result" ] && print_check "пользователи hquser1-5 созданы" "PASS" || print_check "пользователи hquser1-5 созданы" "FAIL"

    result=$(guest_exec "$VM_BR_SRV" "grep -E '^server[[:space:]]+172\\.16\\.2\\.1[[:space:]]+iburst' /etc/chrony.conf 2>/dev/null")
    [ -n "$result" ] && print_check "chrony -> 172.16.2.1" "PASS" || print_check "chrony -> 172.16.2.1" "FAIL"

    result=$(guest_exec "$VM_BR_SRV" "test -f /etc/ansible/hosts && echo ok || true")
    [ "$result" = "ok" ] && print_check "ansible inventory создан" "PASS" || print_check "ansible inventory создан" "FAIL"

    result=$(guest_exec "$VM_BR_SRV" "grep -E '^\[routers\]' /etc/ansible/hosts 2>/dev/null")
    [ -n "$result" ] && print_check "inventory содержит routers" "PASS" || print_check "inventory содержит routers" "FAIL"

    result=$(guest_exec "$VM_BR_SRV" "systemctl is-active docker.service 2>/dev/null")
    [[ "$result" == *active* ]] && print_check "docker active" "PASS" || print_check "docker active ($result)" "FAIL"

    result=$(guest_exec "$VM_BR_SRV" "docker ps --format '{{.Names}}' 2>/dev/null | tr '\n' ' ' || true")
    [[ "$result" == *tespapp* && "$result" == *db* ]] && print_check "контейнеры tespapp и db запущены" "PASS" || print_check "контейнеры tespapp и db запущены ($result)" "FAIL"

    result=$(guest_exec "$VM_BR_SRV" "grep -E '^Port 2026' /etc/openssh/sshd_config 2>/dev/null")
    [ -n "$result" ] && print_check "SSH port 2026" "PASS" || print_check "SSH port 2026" "FAIL"
}

check_hq_cli() {
    print_header "HQ-CLI (VM $VM_HQ_CLI)"

    if ! check_vm_guest_exec "$VM_HQ_CLI"; then
        print_check "QM Guest Exec доступен" "FAIL"
        return 1
    fi
    print_check "QM Guest Exec доступен" "PASS"

    local result

    result=$(guest_exec "$VM_HQ_CLI" "grep -E '^server[[:space:]]+172\\.16\\.1\\.1[[:space:]]+iburst' /etc/chrony.conf 2>/dev/null")
    [ -n "$result" ] && print_check "chrony -> 172.16.1.1" "PASS" || print_check "chrony -> 172.16.1.1" "FAIL"

    result=$(guest_exec "$VM_HQ_CLI" "grep -E '^192\\.168\\.100\\.2:/raid/nfs[[:space:]]+/mnt/nfs[[:space:]]+nfs' /etc/fstab 2>/dev/null")
    [ -n "$result" ] && print_check "NFS automount в fstab" "PASS" || print_check "NFS automount в fstab" "FAIL"

    result=$(guest_exec "$VM_HQ_CLI" "grep 'web.au-team.irpo' /etc/hosts 2>/dev/null")
    [ -n "$result" ] && print_check "hosts: web.au-team.irpo" "PASS" || print_check "hosts: web.au-team.irpo" "FAIL"

    result=$(guest_exec "$VM_HQ_CLI" "grep 'docker.au-team.irpo' /etc/hosts 2>/dev/null")
    [ -n "$result" ] && print_check "hosts: docker.au-team.irpo" "PASS" || print_check "hosts: docker.au-team.irpo" "FAIL"

    result=$(guest_exec "$VM_HQ_CLI" "realm list 2>/dev/null | grep -i 'au-team.irpo' || true")
    [ -n "$result" ] && print_check "домен au-team.irpo присоединён" "PASS" || print_check "домен au-team.irpo присоединён" "WARN"

    result=$(guest_exec "$VM_HQ_CLI" "(rpm -q yandex-browser-stable 2>/dev/null || command -v yandex-browser-stable || command -v browser) | head -1 || true")
    [ -n "$result" ] && print_check "Yandex Browser установлен" "PASS" || print_check "Yandex Browser установлен" "WARN"
}

check_proxy_access() {
    print_header "ПРОВЕРКА ДОСТУПА К СЕРВИСАМ"

    if ! check_vm_guest_exec "$VM_HQ_CLI"; then
        print_check "QM Guest Exec на HQ-CLI для curl-проверок" "FAIL"
        return 1
    fi
    print_check "QM Guest Exec на HQ-CLI для curl-проверок" "PASS"

    local result

    result=$(guest_exec "$VM_HQ_CLI" "curl -s -o /dev/null -I http://docker.au-team.irpo 2>/dev/null | head -n1 || true")
    [[ "$result" == *"200"* || "$result" == *"301"* || "$result" == *"302"* ]] && print_check "docker.au-team.irpo отвечает через proxy" "PASS" || print_check "docker.au-team.irpo отвечает через proxy ($result)" "WARN"

    result=$(guest_exec "$VM_HQ_CLI" "curl -s -o /dev/null -I -u WEB:P@ssw0rd http://web.au-team.irpo 2>/dev/null | head -n1 || true")
    [[ "$result" == *"200"* || "$result" == *"301"* || "$result" == *"302"* ]] && print_check "web.au-team.irpo отвечает через proxy + auth" "PASS" || print_check "web.au-team.irpo отвечает через proxy + auth ($result)" "WARN"
}

check_hq_router_file() {
    local file="$1"

    print_header "HQ-RTR (VM $VM_HQ_RTR)"
    check_regex "$file" '^hostname[[:space:]]+hq-rtr[[:space:]]*$' 'hostname = hq-rtr'
    check_regex "$file" '^interface[[:space:]]+isp[[:space:]]*$' 'interface isp'
    check_regex "$file" '^[[:space:]]*ip[[:space:]]+address[[:space:]]+172\.16\.1\.2/28[[:space:]]*$' 'isp: 172.16.1.2/28'
    check_regex "$file" '^ntp[[:space:]]+timezone[[:space:]]+utc\+9[[:space:]]*$' 'ntp timezone utc+9'
    check_regex "$file" '^ntp[[:space:]]+server[[:space:]]+172\.16\.1\.1[[:space:]]*$' 'ntp server 172.16.1.1'
    check_regex "$file" '^security[[:space:]]+none[[:space:]]*$' 'security none'
    check_regex "$file" '^ip[[:space:]]+nat[[:space:]]+source[[:space:]]+static[[:space:]]+tcp[[:space:]]+192\.168\.100\.2[[:space:]]+80[[:space:]]+172\.16\.1\.2[[:space:]]+8080[[:space:]]*$' 'static NAT 80 -> 8080'
    check_regex "$file" '^ip[[:space:]]+nat[[:space:]]+source[[:space:]]+static[[:space:]]+tcp[[:space:]]+192\.168\.100\.2[[:space:]]+2026[[:space:]]+172\.16\.1\.2[[:space:]]+2026[[:space:]]*$' 'static NAT 2026 -> 2026'
}

check_br_router_file() {
    local file="$1"

    print_header "BR-RTR (VM $VM_BR_RTR)"
    check_regex "$file" '^hostname[[:space:]]+br-rtr[[:space:]]*$' 'hostname = br-rtr'
    check_regex "$file" '^interface[[:space:]]+isp[[:space:]]*$' 'interface isp'
    check_regex "$file" '^[[:space:]]*ip[[:space:]]+address[[:space:]]+172\.16\.2\.2/28[[:space:]]*$' 'isp: 172.16.2.2/28'
    check_regex "$file" '^ntp[[:space:]]+timezone[[:space:]]+utc\+9[[:space:]]*$' 'ntp timezone utc+9'
    check_regex "$file" '^ntp[[:space:]]+server[[:space:]]+172\.16\.2\.1[[:space:]]*$' 'ntp server 172.16.2.1'
    check_regex "$file" '^security[[:space:]]+none[[:space:]]*$' 'security none'
    check_regex "$file" '^ip[[:space:]]+nat[[:space:]]+source[[:space:]]+static[[:space:]]+tcp[[:space:]]+192\.168\.0\.2[[:space:]]+8080[[:space:]]+172\.16\.2\.2[[:space:]]+8080[[:space:]]*$' 'static NAT 8080 -> 8080'
    check_regex "$file" '^ip[[:space:]]+nat[[:space:]]+source[[:space:]]+static[[:space:]]+tcp[[:space:]]+192\.168\.0\.2[[:space:]]+2026[[:space:]]+172\.16\.2\.2[[:space:]]+2026[[:space:]]*$' 'static NAT 2026 -> 2026'
}

check_hq_router() {
    local file="$CONFIG_DIR/hq-rtr_running_config.txt"
    export_running_config "$VM_HQ_RTR" "hq-rtr" || {
        FAIL=$((FAIL + 1))
        return 1
    }
    check_hq_router_file "$file"
}

check_br_router() {
    local file="$CONFIG_DIR/br-rtr_running_config.txt"
    export_running_config "$VM_BR_RTR" "br-rtr" || {
        FAIL=$((FAIL + 1))
        return 1
    }
    check_br_router_file "$file"
}

run_linux_checks() {
    check_isp
    check_hq_srv
    check_br_srv
    check_hq_cli
    check_proxy_access
}

run_router_checks() {
    check_hq_router
    check_br_router
}

usage() {
    cat <<EOF_USAGE
Использование:
  ./module2_test.sh
  ./module2_test.sh full
  ./module2_test.sh linux
  ./module2_test.sh routers

По умолчанию:
  ./module2_test.sh full
EOF_USAGE
}

print_summary() {
    print_header "ИТОГИ ПРОВЕРКИ"

    local total=$((PASS + FAIL + WARN))
    local rate=0

    if [ "$total" -gt 0 ]; then
        rate=$((PASS * 100 / total))
    fi

    echo -e "  Всего проверок: ${C_BOLD}$total${C_RESET}"
    echo -e "  ${C_GREEN}✓ Успешно: $PASS${C_RESET}"
    echo -e "  ${C_RED}✗ Ошибки: $FAIL${C_RESET}"
    echo -e "  ${C_YELLOW}⚠ Предупреждения: $WARN${C_RESET}"
    echo -e "  Успешность: ${C_BOLD}${rate}%${C_RESET}"
    echo
    echo "  Конфиги роутеров: $CONFIG_DIR"

    if [ "$FAIL" -eq 0 ]; then
        echo -e "${C_GREEN}${C_BOLD}ВСЕ ПРОВЕРКИ МОДУЛЯ 2 ПРОЙДЕНЫ${C_RESET}"
        exit 0
    else
        echo -e "${C_RED}${C_BOLD}ОБНАРУЖЕНЫ ОШИБКИ КОНФИГУРАЦИИ${C_RESET}"
        exit 1
    fi
}

main() {
    local mode="${1:-full}"

    clear 2>/dev/null || true
    echo
    echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_CYAN}║${C_RESET}${C_BOLD}                 ПРОВЕРКА МОДУЛЯ 2                          ${C_RESET}${C_CYAN}║${C_RESET}"
    echo -e "${C_CYAN}║${C_RESET}${C_BOLD}           VM 10101, 10102, 10103, 10104, 10105, 10106      ${C_RESET}${C_CYAN}║${C_RESET}"
    echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    echo

    need_tools

    case "$mode" in
        full)
            run_linux_checks
            run_router_checks
            ;;
        linux)
            run_linux_checks
            ;;
        routers)
            run_router_checks
            ;;
        *)
            usage
            exit 1
            ;;
    esac

    print_summary
}

main "$@"
