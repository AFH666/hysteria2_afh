#!/bin/bash

# === Hysteria 2 — Генератор ключей ===
# Использование:
#   bash gen_keys.sh                — одиночная генерация
#   bash gen_keys.sh --count 5      — сгенерировать 5 наборов
#   bash gen_keys.sh --apply        — сгенерировать и применить к config.yaml

CONFIG_FILE="/etc/hysteria/config.yaml"
COUNT=1
APPLY=0

# --- Парсинг аргументов ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --count) COUNT="$2"; shift 2 ;;
        --apply) APPLY=1; shift ;;
        *) echo "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

generate_keys() {
    local PASSWORD
    local OBFS_PASSWORD
    PASSWORD=$(openssl rand -hex 16)
    OBFS_PASSWORD=$(openssl rand -hex 16)
    echo "$PASSWORD $OBFS_PASSWORD"
}

# --- Чтение текущего домена из конфига (если нужен apply) ---
get_domain_from_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo ""
        return
    fi
    # Вытаскиваем SNI из конфига через masquerade.proxy.url (или берём IP)
    grep -oP '(?<=sni: ).*' "$CONFIG_FILE" 2>/dev/null | head -1 || \
        curl -s4 icanhazip.com | awk '{print $1".sslip.io"}'
}

# --- Определяем наличие insecure из конфига ---
get_insecure_flag() {
    if [[ ! -f "$CONFIG_FILE" ]]; then echo "0"; return; fi
    # Если сертификат самоподписанный — проверяем issuer
    CERT="/etc/hysteria/server.crt"
    if [[ -f "$CERT" ]]; then
        ISSUER=$(openssl x509 -in "$CERT" -noout -issuer 2>/dev/null)
        SUBJECT=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null)
        if [[ "$ISSUER" == "$SUBJECT" ]]; then
            echo "1"
        else
            echo "0"
        fi
    else
        echo "0"
    fi
}

# --- Основной вывод ---
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Hysteria 2 — Генератор ключей"
echo "══════════════════════════════════════════════════════"

DOMAIN=$(get_domain_from_config)
if [[ -z "$DOMAIN" ]]; then
    PUBLIC_IP=$(curl -s4 icanhazip.com)
    DOMAIN="${PUBLIC_IP}.sslip.io"
fi
INSECURE=$(get_insecure_flag)
MAIN_PORT=443
START_PORT=20000
END_PORT=50000

for i in $(seq 1 "$COUNT"); do
    read -r PASSWORD OBFS_PASSWORD <<< "$(generate_keys)"

    if [[ "$COUNT" -gt 1 ]]; then
        echo ""
        echo "--- Набор #$i ---"
    fi

    echo ""
    echo "  Пароль:          $PASSWORD"
    echo "  Obfs пароль:     $OBFS_PASSWORD"
    echo ""
    echo "  Hysteria2 ссылка:"
    echo ""
    echo "  hysteria2://$PASSWORD@$DOMAIN:$MAIN_PORT/?sni=$DOMAIN&obfs=salamander&obfs-password=$OBFS_PASSWORD&insecure=$INSECURE&mport=$START_PORT-$END_PORT#Hysteria2-$(openssl rand -hex 4)"
    echo ""

    # --- Применение к конфигу (только для первого ключа при --apply) ---
    if [[ "$APPLY" -eq 1 && "$i" -eq 1 ]]; then
        if [[ ! -f "$CONFIG_FILE" ]]; then
            echo "  ⚠️  Конфиг не найден: $CONFIG_FILE"
            echo "  Применение пропущено."
        else
            # Создаём резервную копию
            cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"

            # Заменяем password в блоке auth
            sed -i "s|^\(\s*password:\s*\).*|\1$PASSWORD|" "$CONFIG_FILE"

            # Заменяем obfs password
            # Блок salamander.password
            python3 - <<PYEOF
import re, sys

with open("$CONFIG_FILE", "r") as f:
    content = f.read()

# Заменяем пароль внутри блока obfs.salamander
content = re.sub(
    r'(obfs:\s*\n\s+type:\s*salamander\s*\n\s+salamander:\s*\n\s+password:\s*)(\S+)',
    r'\g<1>$OBFS_PASSWORD',
    content
)

with open("$CONFIG_FILE", "w") as f:
    f.write(content)
PYEOF

            if systemctl is-active --quiet hysteria-server 2>/dev/null; then
                systemctl restart hysteria-server
                echo "  ✅ Конфиг обновлён, сервис перезапущен."
            else
                echo "  ✅ Конфиг обновлён (сервис не запущен — перезапуск пропущен)."
            fi
        fi
    fi
done

echo "══════════════════════════════════════════════════════"
echo "  ⚠️  Сохраните ссылку — она нигде не записывается."
echo "══════════════════════════════════════════════════════"
echo ""
