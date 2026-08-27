"""Блоки конфигурации клиента. Одно место для обоих входов, чтобы ссылки,
блок для роутера и проверочный конфиг не разъезжались между собой.
"""
import urllib.parse


def proxy_block(kind, name, uuid, conf, keys, ip, indent="  "):
    """Блок proxies: для mihomo. kind — "xhttp" или "vision"."""
    fp = conf["FINGERPRINT"]
    if kind == "xhttp":
        body = f"""- name: "{name}"
  type: vless
  server: {ip}
  port: {conf['PORT_XHTTP']}
  uuid: {uuid}
  udp: true
  packet-encoding: xudp
  tls: true
  network: xhttp
  alpn: [h2]
  servername: {conf['SNI_XHTTP']}
  client-fingerprint: {fp}
  reality-opts:
    public-key: {keys['XHTTP_PUBLIC_KEY']}
    short-id: {keys['XHTTP_SHORT_ID']}
  xhttp-opts:
    path: {keys['XHTTP_PATH']}
    mode: stream-one
"""
    elif kind == "vision":
        body = f"""- name: "{name}"
  type: vless
  server: {ip}
  port: {conf['PORT_VISION']}
  uuid: {uuid}
  udp: true
  packet-encoding: xudp
  tls: true
  flow: xtls-rprx-vision
  network: tcp
  servername: {conf['SNI_VISION']}
  client-fingerprint: {fp}
  reality-opts:
    public-key: {keys['VISION_PUBLIC_KEY']}
    short-id: {keys['VISION_SHORT_ID']}
"""
    else:
        raise ValueError(kind)
    return "".join(indent + line if line.strip() else line
                   for line in body.splitlines(keepends=True))


def link(kind, name, uuid, conf, keys, ip):
    """Ссылка vless:// для клиентов с телефона."""
    common = {"encryption": "none", "security": "reality", "fp": conf["FINGERPRINT"]}
    if kind == "xhttp":
        params = dict(
            common,
            sni=conf["SNI_XHTTP"],
            pbk=keys["XHTTP_PUBLIC_KEY"],
            sid=keys["XHTTP_SHORT_ID"],
            type="xhttp",
            path=keys["XHTTP_PATH"],
            # Режим задаём явно: сервер стоит в auto и примет любой, а
            # stream-one сворачивает обмен в один двунаправленный поток —
            # ровно то, чем гасится счётчик параллельных рукопожатий у ТСПУ.
            mode="stream-one",
        )
        port, label = conf["PORT_XHTTP"], "XHTTP"
    else:
        params = dict(
            common,
            sni=conf["SNI_VISION"],
            pbk=keys["VISION_PUBLIC_KEY"],
            sid=keys["VISION_SHORT_ID"],
            type="tcp",
            flow="xtls-rprx-vision",
        )
        port, label = conf["PORT_VISION"], "Vision"
    query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    tag = urllib.parse.quote(f"{name} {label}")
    return f"vless://{uuid}@{ip}:{port}?{query}#{tag}"
