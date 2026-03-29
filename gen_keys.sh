#!/bin/bash

# === Hysteria 2 — Добавление нового пользователя ===
#
# Запуск:
#   bash gen_keys.sh                     — добавить 1 пользователя
#   bash gen_keys.sh --count 5           — добавить 5 пользователей
#   bash gen_keys.sh --name alice        — добавить пользователя с именем alice
#
# Через curl (аргументы передаются в bash, не в curl):
#   bash <(curl -sL https://raw.githubusercontent.com/AFH666/hysteria2_afh/main/gen_keys.sh)
#   bash <(curl -sL https://raw.githubusercontent.com/AFH666/hysteria2_afh/main/gen_keys.sh) --count 3
#   bash <(curl -sL https://raw.githubusercontent.com/AFH666/hysteria2_afh/main/gen_keys.sh) --name alice

CONFIG_FILE="/etc/hysteria/config.yaml"
COUNT=1
USERNAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count) COUNT="$2"; shift 2 ;;
        --name)  USERNAME="$2"; shift 2 ;;
        *) echo "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

# --- Root check ---
if [[ "$EUID" -ne 0 ]]; then
    echo "Запустите скрипт от root (sudo bash ...)"
    exit 1
fi

# --- Конфиг должен существовать ---
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ Конфиг не найден: $CONFIG_FILE"
    exit 1
fi

# --- Домен из публичного IP ---
PUBLIC_IP=$(curl -s4 icanhazip.com)
if [[ -z "$PUBLIC_IP" ]]; then
    echo "❌ Не удалось определить публичный IP." >&2
    exit 1
fi
DOMAIN="${PUBLIC_IP}.sslip.io"

# --- insecure флаг ---
get_insecure_flag() {
    local CERT="/etc/hysteria/server.crt"
    [[ ! -f "$CERT" ]] && echo "0" && return
    local ISSUER SUBJECT
    ISSUER=$(openssl x509 -in "$CERT" -noout -issuer 2>/dev/null)
    SUBJECT=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null)
    [[ "$ISSUER" == "$SUBJECT" ]] && echo "1" || echo "0"
}

# --- Читаем obfs password из конфига ---
get_obfs_password() {
    python3 - <<'PYEOF'
import re, sys
with open("/etc/hysteria/config.yaml", "r") as f:
    content = f.read()
m = re.search(r'salamander:\s*\n\s+password:\s*(\S+)', content)
print(m.group(1) if m else "")
PYEOF
}

INSECURE=$(get_insecure_flag)
OBFS_PASSWORD=$(get_obfs_password)
MAIN_PORT=443
START_PORT=20000
END_PORT=50000

if [[ -z "$OBFS_PASSWORD" ]]; then
    echo "❌ Не удалось прочитать obfs password из конфига."
    exit 1
fi

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Hysteria 2 — Добавление пользователей"
echo "  Домен: $DOMAIN  |  insecure=$INSECURE"
echo "══════════════════════════════════════════════════════"

# --- Мигрируем auth type: password → userpass если нужно ---
# Hysteria2 userpass формат:
#   auth:
#     type: userpass
#     userpass:
#       alice: password123
#       bob:   password456
#
python3 - <<'PYEOF'
import re, sys

with open("/etc/hysteria/config.yaml", "r") as f:
    content = f.read()

# Проверяем текущий тип auth
if re.search(r'auth:\s*\n\s+type:\s*userpass', content):
    print("USERPASS")
elif re.search(r'auth:\s*\n\s+type:\s*password', content):
    print("PASSWORD")
else:
    print("UNKNOWN")
PYEOF
AUTH_TYPE=$(python3 - <<'PYEOF'
import re
with open("/etc/hysteria/config.yaml", "r") as f:
    content = f.read()
if re.search(r'auth:\s*\n\s+type:\s*userpass', content):
    print("USERPASS")
elif re.search(r'auth:\s*\n\s+type:\s*password', content):
    print("PASSWORD")
else:
    print("UNKNOWN")
PYEOF
)

echo "  Текущий тип auth: $AUTH_TYPE"

# Резервная копия перед любыми изменениями
BACKUP="${CONFIG_FILE}.bak.$(date +%s)"
cp "$CONFIG_FILE" "$BACKUP"
echo "  📋 Резервная копия: $BACKUP"
echo ""

GENERATED_LINKS=()

for i in $(seq 1 "$COUNT"); do
    # Имя пользователя
    if [[ -n "$USERNAME" && "$COUNT" -eq 1 ]]; then
        USER="$USERNAME"
    elif [[ -n "$USERNAME" ]]; then
        USER="${USERNAME}_${i}"
    else
        USER="user_$(openssl rand -hex 4)"
    fi

    PASSWORD=$(openssl rand -hex 16)
    LINK="hysteria2://$PASSWORD@$DOMAIN:$MAIN_PORT/?sni=$DOMAIN&obfs=salamander&obfs-password=$OBFS_PASSWORD&insecure=$INSECURE&mport=$START_PORT-$END_PORT#$USER"

    [[ "$COUNT" -gt 1 ]] && echo "--- Пользователь #$i ---"
    echo "  Имя:          $USER"
    echo "  Пароль:       $PASSWORD"
    echo ""
    echo "  $LINK"
    echo ""

    GENERATED_LINKS+=("$LINK")

    # Добавляем пользователя в конфиг
    python3 - "$AUTH_TYPE" "$USER" "$PASSWORD" <<'PYEOF'
import re, sys

auth_type = sys.argv[1]
username  = sys.argv[2]
password  = sys.argv[3]

with open("/etc/hysteria/config.yaml", "r") as f:
    content = f.read()

if auth_type == "USERPASS":
    # Просто добавляем строку в существующий блок userpass:
    # Ищем конец блока userpass: и вставляем перед следующим top-level ключом
    content = re.sub(
        r'(auth:\s*\n\s+type:\s*userpass\s*\n\s+userpass:\s*\n(?:\s+\S+:\s*\S+\s*\n)*)',
        lambda m: m.group(0) + f'      {username}: {password}\n',
        content
    )

elif auth_type == "PASSWORD":
    # Мигрируем: вытаскиваем старый одиночный пароль, строим блок userpass
    old_pass_match = re.search(r'auth:\s*\n\s+type:\s*password\s*\n\s+password:\s*(\S+)', content)
    old_pass = old_pass_match.group(1) if old_pass_match else "user_default"
    old_user = "user_default"

    new_auth = (
        f"auth:\n"
        f"  type: userpass\n"
        f"  userpass:\n"
        f"    {old_user}: {old_pass}\n"
        f"    {username}: {password}\n"
    )
    content = re.sub(
        r'auth:\s*\n\s+type:\s*password\s*\n\s+password:\s*\S+\s*\n',
        new_auth,
        content
    )

with open("/etc/hysteria/config.yaml", "w") as f:
    f.write(content)

print(f"  ✅ Пользователь '{username}' добавлен в конфиг.")
PYEOF

    # Обновляем AUTH_TYPE после первой миграции
    if [[ "$AUTH_TYPE" == "PASSWORD" ]]; then
        AUTH_TYPE="USERPASS"
    fi
done

# --- Перезапуск сервиса ---
echo "══════════════════════════════════════════════════════"
if systemctl is-active --quiet hysteria-server 2>/dev/null; then
    systemctl restart hysteria-server
    sleep 1
    if systemctl is-active --quiet hysteria-server; then
        echo "  ✅ hysteria-server перезапущен успешно."
    else
        echo "  ❌ Сервис не запустился — откатываем конфиг..."
        cp "$BACKUP" "$CONFIG_FILE"
        systemctl restart hysteria-server
        echo "  ↩️  Конфиг восстановлен из резервной копии."
    fi
else
    echo "  ℹ️  Сервис hysteria-server не активен — перезапуск пропущен."
fi

echo ""
echo "  ⚠️  Сохраните ссылки выше — они нигде не записываются."
echo "══════════════════════════════════════════════════════"
echo ""
