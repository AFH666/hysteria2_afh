#!/bin/bash

# === Hysteria 2 — Генератор ключей ===
#
# Использование:
#   bash gen_keys.sh                  — одна пара ключей + ссылка
#   bash gen_keys.sh --count 5        — 5 наборов
#   bash gen_keys.sh --apply          — сгенерировать и применить к config.yaml
#
# Через curl (аргументы передаются В bash, не в curl):
#   bash <(curl -sL https://raw.githubusercontent.com/AFH666/hysteria2_afh/main/gen_keys.sh) --count 5
#   bash <(curl -sL https://raw.githubusercontent.com/AFH666/hysteria2_afh/main/gen_keys.sh) --apply

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

# --- Домен из публичного IP ---
PUBLIC_IP=$(curl -s4 icanhazip.com)
if [[ -z "$PUBLIC_IP" ]]; then
    echo "Ошибка: не удалось определить публичный IP." >&2
    exit 1
fi
DOMAIN="${PUBLIC_IP}.sslip.io"

# --- insecure: самоподписанный если issuer == subject ---
get_insecure_flag() {
    local CERT="/etc/hysteria/server.crt"
    [[ ! -f "$CERT" ]] && echo "0" && return
    local ISSUER SUBJECT
    ISSUER=$(openssl x509 -in "$CERT" -noout -issuer 2>/dev/null)
    SUBJECT=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null)
    [[ "$ISSUER" == "$SUBJECT" ]] && echo "1" || echo "0"
}

INSECURE=$(get_insecure_flag)
MAIN_PORT=443
START_PORT=20000
END_PORT=50000

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Hysteria 2 — Генератор ключей"
echo "  Домен: $DOMAIN  |  insecure=$INSECURE"
echo "══════════════════════════════════════════════════════"

for i in $(seq 1 "$COUNT"); do
    PASSWORD=$(openssl rand -hex 16)
    OBFS_PASSWORD=$(openssl rand -hex 16)

    [[ "$COUNT" -gt 1 ]] && echo "" && echo "--- Набор #$i ---"
    echo ""
    echo "  Пароль:       $PASSWORD"
    echo "  Obfs пароль:  $OBFS_PASSWORD"
    echo ""
    echo "  hysteria2://$PASSWORD@$DOMAIN:$MAIN_PORT/?sni=$DOMAIN&obfs=salamander&obfs-password=$OBFS_PASSWORD&insecure=$INSECURE&mport=$START_PORT-$END_PORT#Hysteria2-Optimum"
    echo ""

    # --apply: применяем только первый набор
    if [[ "$APPLY" -eq 1 && "$i" -eq 1 ]]; then
        if [[ ! -f "$CONFIG_FILE" ]]; then
            echo "  ⚠️  Конфиг не найден: $CONFIG_FILE — применение пропущено."
            continue
        fi

        # Резервная копия
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"
        echo "  📋 Резервная копия создана: ${CONFIG_FILE}.bak.*"

        # Патчим через python3 — надёжнее sed для YAML с отступами
        python3 - <<PYEOF
import re, sys

config_path = "$CONFIG_FILE"
new_password = "$PASSWORD"
new_obfs = "$OBFS_PASSWORD"

with open(config_path, "r") as f:
    content = f.read()

original = content

# --- auth.password ---
# Ищем блок auth: и меняем первый password: внутри него
content = re.sub(
    r'(auth:\s*\n(?:\s+\w+:\s*\S+\s*\n)*?\s+password:\s*)(\S+)',
    lambda m: m.group(1) + new_password,
    content
)

# --- obfs.salamander.password ---
content = re.sub(
    r'(salamander:\s*\n\s+password:\s*)(\S+)',
    lambda m: m.group(1) + new_obfs,
    content
)

if content == original:
    print("  ⚠️  Паттерны не найдены в конфиге — проверьте структуру YAML вручную.")
    sys.exit(1)

with open(config_path, "w") as f:
    f.write(content)

print("  ✅ Конфиг обновлён.")
PYEOF

        if [[ $? -eq 0 ]]; then
            if systemctl is-active --quiet hysteria-server 2>/dev/null; then
                systemctl restart hysteria-server
                sleep 1
                if systemctl is-active --quiet hysteria-server; then
                    echo "  ✅ Сервис hysteria-server перезапущен успешно."
                else
                    echo "  ❌ Сервис не запустился после перезапуска — проверьте journalctl -u hysteria-server"
                fi
            else
                echo "  ℹ️  Сервис hysteria-server не активен — перезапуск пропущен."
            fi
        fi
    fi
done

echo "══════════════════════════════════════════════════════"
echo "  ⚠️  Сохраните ссылку — она нигде не записывается."
echo "══════════════════════════════════════════════════════"
echo ""
