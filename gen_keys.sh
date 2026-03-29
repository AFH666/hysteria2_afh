#!/bin/bash

# === Hysteria 2 — Генератор ключей ===
# Использование:
#   bash gen_keys.sh                — одиночная генерация
#   bash gen_keys.sh --count 5      — сгенерировать 5 наборов
#   bash gen_keys.sh --apply        — сгенерировать и применить к config.yaml

CONFIG_FILE="/etc/hysteria/config.yaml"
COUNT=1
APPLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count) COUNT="$2"; shift 2 ;;
        --apply) APPLY=1; shift ;;
        *) echo "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

generate_keys() {
    local PASSWORD OBFS_PASSWORD
    PASSWORD=$(openssl rand -hex 16)
    OBFS_PASSWORD=$(openssl rand -hex 16)
    echo "$PASSWORD $OBFS_PASSWORD"
}

# --- Домен берём только из IP сервера, как в install-скрипте ---
get_domain() {
    PUBLIC_IP=$(curl -s4 icanhazip.com)
    if [[ -z "$PUBLIC_IP" ]]; then
        echo "Ошибка: не удалось определить публичный IP." >&2
        exit 1
    fi
    echo "${PUBLIC_IP}.sslip.io"
}

# --- insecure: сравниваем issuer и subject сертификата ---
get_insecure_flag() {
    local CERT="/etc/hysteria/server.crt"
    if [[ ! -f "$CERT" ]]; then echo "0"; return; fi
    ISSUER=$(openssl x509 -in "$CERT" -noout -issuer 2>/dev/null)
    SUBJECT=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null)
    if [[ "$ISSUER" == "$SUBJECT" ]]; then echo "1"; else echo "0"; fi
}

DOMAIN=$(get_domain)
INSECURE=$(get_insecure_flag)
MAIN_PORT=443
START_PORT=20000
END_PORT=50000

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Hysteria 2 — Генератор ключей"
echo "  Домен: $DOMAIN"
echo "══════════════════════════════════════════════════════"

for i in $(seq 1 "$COUNT"); do
    read -r PASSWORD OBFS_PASSWORD <<< "$(generate_keys)"

    [[ "$COUNT" -gt 1 ]] && echo "" && echo "--- Набор #$i ---"

    echo ""
    echo "  Пароль:       $PASSWORD"
    echo "  Obfs пароль:  $OBFS_PASSWORD"
    echo ""
    echo "  hysteria2://$PASSWORD@$DOMAIN:$MAIN_PORT/?sni=$DOMAIN&obfs=salamander&obfs-password=$OBFS_PASSWORD&insecure=$INSECURE&mport=$START_PORT-$END_PORT#Hysteria2-Optimum"
    echo ""

    if [[ "$APPLY" -eq 1 && "$i" -eq 1 ]]; then
        if [[ ! -f "$CONFIG_FILE" ]]; then
            echo "  ⚠️  Конфиг не найден: $CONFIG_FILE — применение пропущено."
        else
            cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"

            # Заменяем auth.password
            sed -i "s|^\(\s*password:\s*\).*|\1$PASSWORD|" "$CONFIG_FILE"

            # Заменяем obfs salamander password через python3
            python3 - "$OBFS_PASSWORD" <<'PYEOF'
import re, sys

new_pass = sys.argv[1]
with open("/etc/hysteria/config.yaml", "r") as f:
    content = f.read()

content = re.sub(
    r'(obfs:\s*\n\s+type:\s*salamander\s*\n\s+salamander:\s*\n\s+password:\s*)(\S+)',
    lambda m: m.group(1) + new_pass,
    content
)

with open("/etc/hysteria/config.yaml", "w") as f:
    f.write(content)
PYEOF

            if systemctl is-active --quiet hysteria-server 2>/dev/null; then
                systemctl restart hysteria-server
                echo "  ✅ Конфиг обновлён, сервис перезапущен."
            else
                echo "  ✅ Конфиг обновлён (сервис не активен — перезапуск пропущен)."
            fi
        fi
    fi
done

echo "══════════════════════════════════════════════════════"
echo "  ⚠️  Сохраните ссылку — она нигде не записывается."
echo "══════════════════════════════════════════════════════"
echo ""
