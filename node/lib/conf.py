"""Разбор объявлений проекта. Общее для bin/render-config и bin/client."""
import pathlib
import sys


def read_conf(path):
    """Читает shell-присваивания key=value, пропуская комментарии и пустое."""
    out = {}
    for line in pathlib.Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def read_clients(path="secrets/clients.tsv"):
    """Список (имя, uuid). Отсутствующий файл — не ошибка, просто пусто."""
    p = pathlib.Path(path)
    if not p.exists():
        return []
    clients = []
    for line in p.read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            parts = line.split("\t")
            if len(parts) >= 2:
                clients.append((parts[0].strip(), parts[1].strip()))
    return clients


def write_clients(clients, path="secrets/clients.tsv"):
    p = pathlib.Path(path)
    p.write_text("".join(f"{n}\t{u}\n" for n, u in clients))
    p.chmod(0o600)


def die(msg):
    sys.exit(f"Ошибка: {msg}")
