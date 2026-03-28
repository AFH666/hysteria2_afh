#!/bin/bash

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт от имени root"
  exit
fi

echo "--- 1. Подготовка системы и оптимизация ядра ---"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl socat cron tar iptables iptables-persistent netfilter-persistent openssl

# Лечим системный DNS (для работы самого сервера)
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# === SYSCTL ОПТИМИЗАЦИЯ (UDP/QUIC BOOST) ===
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
sed -i '/net.core.wmem_max/d' /etc/sysctl.conf
sed -i '/net.ipv4.udp_mem/d' /etc/sysctl.conf

cat <<EOF >> /etc/sysctl.conf
# BBR и Forwarding
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1

# Агрессивные буферы памяти для UDP (Hysteria Boost)
net.core.rmem_max=26214400
net.core.wmem_max=26214400
net.core.rmem_default=26214400
net.core.wmem_default=26214400
net.ipv4.udp_mem=8192 32768 16777216
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384

# Очереди и соединения
net.core.somaxconn=8192
net.core.netdev_max_backlog=16384
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_notsent_lowat=16384
EOF

sysctl -p
echo "✅ Настройки ядра применены (High Performance Mode)"

echo "--- 2. Магия с доменом ---"
PUBLIC_IP=$(curl -s4 icanhazip.com)
if [[ -z "$PUBLIC_IP" ]]; then
    echo "Ошибка: Не удалось определить IP."
    exit 1
fi
DOMAIN="${PUBLIC_IP}.sslip.io"
echo "Домен: $DOMAIN"

echo "--- 3. Port Hopping (Маскировка портов) ---"
START_PORT=20000
END_PORT=50000
MAIN_PORT=443

iptables -t nat -F PREROUTING
iptables -t nat -A PREROUTING -p udp --dport $START_PORT:$END_PORT -j DNAT --to-destination :$MAIN_PORT
netfilter-persistent save

echo "✅ Port Hopping: $START_PORT-$END_PORT -> $MAIN_PORT"

echo "--- 4. SSL Сертификат ---"
systemctl stop nginx 2>/dev/null
systemctl stop apache2 2>/dev/null
systemctl stop hysteria-server 2>/dev/null

mkdir -p /etc/hysteria

if [ ! -f ~/.acme.sh/acme.sh ]; then
    curl https://get.acme.sh | sh
fi

CERT_OK=0

# --- Попытка 1: Let's Encrypt ---
echo "🔐 Пробуем Let's Encrypt..."
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --register-account -m "admin@$DOMAIN"
~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force 2>/tmp/acme_le.log

if [ $? -eq 0 ]; then
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file /etc/hysteria/server.crt \
        --key-file       /etc/hysteria/server.key
    CERT_OK=1
    echo "✅ Сертификат: Let's Encrypt"
else
    echo "⚠️  Let's Encrypt недоступен (rate limit?), пробуем ZeroSSL..."

    # --- Попытка 2: ZeroSSL ---
    ~/.acme.sh/acme.sh --set-default-ca --server zerossl
    ~/.acme.sh/acme.sh --register-account -m "admin@$DOMAIN"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force 2>/tmp/acme_zssl.log

    if [ $? -eq 0 ]; then
        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
            --fullchain-file /etc/hysteria/server.crt \
            --key-file       /etc/hysteria/server.key
        CERT_OK=1
        echo "✅ Сертификат: ZeroSSL"
    else
        echo "⚠️  ZeroSSL тоже недоступен. Генерируем самоподписанный сертификат..."

        # --- Фолбэк: самоподписанный сертификат ---
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
            -keyout /etc/hysteria/server.key \
            -out    /etc/hysteria/server.crt \
            -days   3650 -nodes \
            -subj   "/CN=$DOMAIN" \
            -addext "subjectAltName=DNS:$DOMAIN,IP:$PUBLIC_IP"
        CERT_OK=2
        echo "✅ Сертификат: самоподписанный (insecure=1 будет в ссылке)"
    fi
fi

chmod 644 /etc/hysteria/server.crt
chmod 644 /etc/hysteria/server.key

echo "--- 5. Установка ядра Hysteria 2 ---"
rm -f /usr/local/bin/hysteria
wget -O /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/download/app%2Fv2.7.1/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

PASSWORD=$(openssl rand -hex 16)
OBFS_PASSWORD=$(openssl rand -hex 16)

echo "--- 6. Конфигурация (Anti-Ad + Secure DNS) ---"
cat <<EOF > /etc/hysteria/config.yaml
listen: :$MAIN_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

# === БЛОКИРОВЩИК РЕКЛАМЫ (AdGuard DNS over HTTPS) ===
resolver:
  type: https
  https:
    addr: 94.140.14.14:443
    sni: dns.adguard-dns.com
    insecure: false
    timeout: 10s
# ====================================================

auth:
  type: password
  password: $PASSWORD

obfs:
  type: salamander
  salamander:
    password: $OBFS_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true

ignoreClientBandwidth: true
EOF

echo "--- 7. Создание службы (BLACK HOLE LOGGING) ---"
cat <<EOF > /etc/systemd/system/hysteria-server.service
[Unit]
Description=Hysteria 2 Server (No Logs)
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
WorkingDirectory=/etc/hysteria
Restart=always
User=root
LimitNOFILE=65536

# === ПОЛНОЕ УНИЧТОЖЕНИЕ ЛОГОВ СЛУЖБЫ ===
StandardOutput=null
StandardError=null
# =======================================

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

# Определяем insecure флаг для ссылки
if [ "$CERT_OK" -eq 2 ]; then
    INSECURE="1"
else
    INSECURE="0"
fi

# Проверка статуса
if systemctl is-active --quiet hysteria-server; then
    echo ""
    echo "========================================================"
    echo "🛡️  HYSTERIA 2 АКТИВИРОВАНА"
    echo "========================================================"
    echo "IP сервера:   $PUBLIC_IP"
    echo "Домен:        $DOMAIN"
    if [ "$CERT_OK" -eq 1 ]; then
        echo "Сертификат:   Доверенный (Let's Encrypt / ZeroSSL)"
    else
        echo "Сертификат:   Самоподписанный (insecure=1)"
    fi
    echo "Логирование:  ОТКЛЮЧЕНО (Black Hole Mode)"
    echo "Реклама:      БЛОКИРУЕТСЯ (AdGuard DNS)"
    echo "UDP Буферы:   ОПТИМИЗИРОВАНЫ"
    echo "========================================================"
    echo ""
    echo "⬇️  ТВОЯ ССЫЛКА ⬇️"
    echo ""
    echo "hysteria2://$PASSWORD@$DOMAIN:$MAIN_PORT/?sni=$DOMAIN&obfs=salamander&obfs-password=$OBFS_PASSWORD&insecure=$INSECURE&mport=$START_PORT-$END_PORT#Hysteria2-Optimum"
    echo ""
    echo "========================================================"

    echo ""
    echo "🧹 Зачистка следов установки..."

    # === WIPE LOGS SECTION ===
    history -c
    history -w

    echo > /var/log/syslog
    echo > /var/log/auth.log
    echo > /var/log/btmp
    echo > /var/log/wtmp
    echo > /var/log/kern.log
    echo > /var/log/messages 2>/dev/null
    echo > /var/log/dmesg

    rm -f ~/.bash_history
    rm -f /root/.bash_history

    journalctl --rotate >/dev/null 2>&1
    journalctl --vacuum-time=1s >/dev/null 2>&1

    echo "✅ Система очищена. Bash history удалена."
    echo "⚠️  Скопируйте ссылку выше, она больше нигде не сохранится."
else
    echo "❌ Сервис не запустился. Проверьте конфиг вручную:"
    echo "/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml"
fi
