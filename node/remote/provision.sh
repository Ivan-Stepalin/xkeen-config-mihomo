#!/usr/bin/env bash
# Выполняется НА СЕРВЕРЕ. Приводит систему к чистому состоянию под один
# Xray и ничего больше. Идемпотентен: повторный запуск ничего не ломает.
#
# Первая половина — снос. На узле накопился слой из nginx, Let's Encrypt,
# hysteria2, shadowsocks и nftables-правил для перескока портов. Он не просто
# лишний: замер 27.08.2026 показал, что настоящий домен с валидным
# сертификатом душат на первом окне TCP, то есть этот слой активно вредил.
# Сносим его целиком, а не обходим — иначе следующий заход снова начнётся с
# вопроса «что здесь вообще стоит».
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# $1 = 1 переустановить Xray начисто. Снос чужого слоя идёт всегда: он
# идемпотентен и после первого раза почти бесплатен, а объявленное состояние
# узла — «только Xray и ничего больше».
REINSTALL_XRAY="${1:-0}"

echo ">> снос старого слоя"

for u in nginx hysteria-server hysteria shadowsocks-libev nftables; do
  systemctl disable --now "$u" 2>/dev/null || true
done

apt-get purge -y -qq nginx nginx-common nginx-core \
  certbot python3-certbot-nginx shadowsocks-libev nftables >/dev/null 2>&1 || true
apt-get autoremove -y -qq >/dev/null 2>&1 || true

rm -rf /etc/nginx /var/www /etc/letsencrypt /var/log/letsencrypt \
       /etc/hysteria /usr/local/bin/hysteria \
       /etc/systemd/system/hysteria-server.service \
       /etc/systemd/system/hysteria-server@.service \
       /etc/nftables.conf
systemctl daemon-reload

# Xray переустанавливаем начисто, а не правим поверх: старый конфиг содержал
# ws-инбаунд на 127.0.0.1 и подписку, и вычищать это по кускам дороже.
if [ "$REINSTALL_XRAY" = 1 ] && command -v xray >/dev/null; then
  bash -c "$(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge >/dev/null 2>&1 || true
  rm -rf /usr/local/etc/xray /var/log/xray
fi

echo ">> базовые пакеты"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl unzip openssl jq ca-certificates >/dev/null

echo ">> время"
# Reality без точного времени не работает: рукопожатие донора привязано к
# времени, расхождение больше минуты валит соединение.
timedatectl set-timezone Asia/Almaty
timedatectl set-ntp true
systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true

echo ">> сеть"
cat > /etc/sysctl.d/99-node.conf <<'SYS'
# BBR: заметно ровнее держит скорость на длинном плече до РФ, чем cubic.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# Очереди под несколько сотен одновременных потоков от одного клиента.
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_local_port_range = 10000 65000
SYS
sysctl --system >/dev/null
sysctl -n net.ipv4.tcp_congestion_control | grep -qx bbr || { echo "BBR не включился"; exit 1; }

echo ">> автообновления безопасности"
apt-get install -y -qq unattended-upgrades >/dev/null
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

echo ">> xray"
if command -v xray >/dev/null; then
  echo "   уже стоит, пропускаю установку"
else
  bash -c "$(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
fi
command -v xray >/dev/null || { echo "xray не установился"; exit 1; }
install -d -m 0755 /usr/local/etc/xray

echo ">> готово: $(xray version | head -1)"
