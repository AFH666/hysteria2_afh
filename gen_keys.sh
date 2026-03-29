#!/bin/bash

# === Hysteria 2 — Добавление пользователей ===
#
# Запуск:
#   bash gen_keys.sh                  — добавить 1 пользователя
#   bash gen_keys.sh --count 5        — добавить 5 пользователей
#   bash gen_keys.sh --name alice     — добавить пользователя с именем alice
#
# Через curl:
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

if [[ "$EUID" -ne 0 ]]; then
    echo "Запустите скрипт от root (sudo bash ...)"
    exit 1
fi

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

# --- Читаем obfs password ---
get_obfs_password() {
    python3 -c "
import re
with open('$CONFIG_FILE') as f:
    content = f.read()
m = re.search(r'salamander:\s*\n\s+password:\s*(\S+)', content)
print(m.group(1) if m else '')
"
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

# --- Резервная копия ---
BACKUP="${CONFIG_FILE}.bak.$(date +%s)"
cp "$CONFIG_FILE" "$BACKUP"

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Hysteria 2 — Добавление пользователей"
echo "  Домен: $DOMAIN  |  insecure=$INSECURE"
echo "  📋 Резервная копия: $BACKUP"
echo "══════════════════════════════════════════════════════"
echo ""

# --- Определяем текущий тип auth ---
AUTH_TYPE=$(python3 -c "
import re
with open('$CONFIG_FILE') as f:
    content = f.read()
if re.search(r'type:\s*userpass', content):
    print('USERPASS')
elif re.search(r'type:\s*password', content):
    print('PASSWORD')
else:
    print('UNKNOWN')
")

# --- Если тип password — мигрируем в userpass ---
# Старый одиночный пароль становится user_default
if [[ "$AUTH_TYPE" == "PASSWORD" ]]; then
    python3 -c "
import re
with open('$CONFIG_FILE') as f:
    content = f.read()

m = re.search(r'auth:\s*\n\s+type:\s*password\s*\n\s+password:\s*(\S+)', content)
old_pass = m.group(1) if m else 'changeme'

new_auth = '''auth:
  type: userpass
  userpass:
    user_default: {old}
'''.format(old=old_pass)

content = re.sub(
    r'auth:\s*\n\s+type:\s*password\s*\n\s+password:\s*\S+\s*\n',
    new_auth,
    content
)

with open('$CONFIG_FILE', 'w') as f:
    f.write(content)
"
    echo "  ℹ️  Мигрировано: type: password → type: userpass"
    echo "      Старый пароль сохранён как user_default"
    echo ""
    AUTH_TYPE="USERPASS"
fi

# --- Добавляем пользователей ---
for i in $(seq 1 "$COUNT"); do
    if [[ -n "$USERNAME" && "$COUNT" -eq 1 ]]; then
        USER="$USERNAME"
    elif [[ -n "$USERNAME" ]]; then
        USER="${USERNAME}_${i}"
    else
        USER="user_$(openssl rand -hex 4)"
    fi

    PASSWORD=$(openssl rand -hex 16)

    # Ссылка: hysteria2://username:password@host — формат userpass
    LINK="hysteria2://$USER:$PASSWORD@$DOMAIN:$MAIN_PORT/?sni=$DOMAIN&obfs=salamander&obfs-password=$OBFS_PASSWORD&insecure=$INSECURE&mport=$START_PORT-$END_PORT#$USER"

    [[ "$COUNT" -gt 1 ]] && echo "--- Пользователь #$i ---"
    echo "  Имя:          $USER"
    echo "  Пароль:       $PASSWORD"
    echo ""
    echo "  $LINK"
    echo ""

    # Добавляем строку в блок userpass
    python3 -c "
import re, sys
with open('$CONFIG_FILE') as f:
    content = f.read()

# Добавляем новую строку в конец блока userpass:
# Блок userpass заканчивается перед следующим top-level ключом (не с отступом)
content = re.sub(
    r'(  type: userpass\n  userpass:\n(?:    \S+: \S+\n)*)',
    lambda m: m.group(0) + '    $USER: $PASSWORD\n',
    content
)

with open('$CONFIG_FILE', 'w') as f:
    f.write(content)
print('  ✅ Пользователь добавлен в конфиг.')
"
done

# --- Проверяем итоговый конфиг ---
echo "══════════════════════════════════════════════════════"
echo "  Итоговый блок auth в конфиге:"
echo ""
python3 -c "
with open('$CONFIG_FILE') as f:
    lines = f.readlines()
in_auth = False
for line in lines:
    if line.startswith('auth:'):
        in_auth = True
    elif in_auth and not line.startswith(' ') and not line.startswith('\t'):
        break
    if in_auth:
        print('  ' + line, end='')
"
echo ""

# --- Перезапуск сервиса ---
if systemctl is-active --quiet hysteria-server 2>/dev/null || \
   systemctl is-enabled --quiet hysteria-server 2>/dev/null; then
    systemctl restart hysteria-server
    sleep 1
    if systemctl is-active --quiet hysteria-server; then
        echo "  ✅ hysteria-server перезапущен успешно."
    else
        echo "  ❌ Сервис не запустился. Откатываем конфиг..."
        cp "$BACKUP" "$CONFIG_FILE"
        systemctl restart hysteria-server
        echo "  ↩️  Конфиг восстановлен. Ошибка hysteria:"
        journalctl -u hysteria-server --no-pager -n 15
    fi
else
    echo "  ℹ️  Сервис hysteria-server не активен — перезапуск пропущен."
fi

echo ""
echo "  ⚠️  Сохраните ссылки выше — они нигде не записываются."
echo "══════════════════════════════════════════════════════"
echo ""
