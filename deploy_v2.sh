#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Запустите от root"
  exit
fi

echo "--- 1. Подготовка системы ---"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl socat cron tar iptables iptables-persistent netfilter-persistent

echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

echo "--- 2. SYSCTL BOOST ---"
sed -i '/net.core/d;/net.ipv4/d' /etc/sysctl.conf

cat <<EOF >> /etc/sysctl.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.core.rmem_max=26214400
net.core.wmem_max=26214400
net.core.netdev_max_backlog=16384
EOF

sysctl -p

echo "--- 3. Домен ---"
PUBLIC_IP=$(curl -s4 icanhazip.com)
DOMAIN="${PUBLIC_IP//./-}.sslip.io"
echo "DOMAIN: $DOMAIN"

echo "--- 4. Port hopping ---"
iptables -t nat -F PREROUTING
iptables -t nat -A PREROUTING -p udp --dport 20000:50000 -j DNAT --to :443
netfilter-persistent save

echo "--- 5. ACME ---"
mkdir -p /etc/hysteria

if [ ! -f ~/.acme.sh/acme.sh ]; then
  curl https://get.acme.sh | sh
fi

~/.acme.sh/acme.sh --register-account -m admin@$DOMAIN || true

# ===== СТАВИМ STAGING (чтобы не падало) =====
~/.acme.sh/acme.sh --set-default-ca --server https://acme-staging-v02.api.letsencrypt.org/directory
~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force --staging

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
--fullchain-file /etc/hysteria/server.crt \
--key-file /etc/hysteria/server.key

echo "✅ staging SSL установлен"

echo "--- 6. Установка Hysteria2 ---"
wget -O /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/download/app%2Fv2.7.1/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

PASSWORD=$(openssl rand -hex 16)
OBFS=$(openssl rand -hex 16)

echo "--- 7. Конфиг ---"
cat <<EOF > /etc/hysteria/config.yaml
listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $PASSWORD

obfs:
  type: salamander
  salamander:
    password: $OBFS

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true

ignoreClientBandwidth: true
EOF

echo "--- 8. Сервис ---"
cat <<EOF > /etc/systemd/system/hysteria-server.service
[Unit]
Description=Hysteria2
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
LimitNOFILE=65536
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

echo "--- 9. АВТО-ОБНОВЛЕНИЕ SSL (FIX LIMIT) ---"

cat <<EOF > /root/fixssl.sh
#!/bin/bash

DOMAIN="$DOMAIN"

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

~/.acme.sh/acme.sh --issue -d "\$DOMAIN" --standalone -k ec-256 --force

if [ \$? -eq 0 ]; then
    ~/.acme.sh/acme.sh --install-cert -d "\$DOMAIN" --ecc \
    --fullchain-file /etc/hysteria/server.crt \
    --key-file /etc/hysteria/server.key

    systemctl restart hysteria-server

    echo "SSL ОБНОВЛЕН НА PRODUCTION" >> /root/ssl.log

    crontab -l | grep -v fixssl.sh | crontab -
fi
EOF

chmod +x /root/fixssl.sh

# каждые 6 часов пробуем получить нормальный сертификат
(crontab -l 2>/dev/null; echo "0 */6 * * * /root/fixssl.sh") | crontab -

echo ""
echo "======================================"
echo "🚀 ГОТОВО"
echo "======================================"
echo "hysteria2://$PASSWORD@$DOMAIN:443/?sni=$DOMAIN&obfs=salamander&obfs-password=$OBFS&insecure=0"
echo "======================================"