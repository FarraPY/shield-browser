#!/usr/bin/env python3
"""Convierte listas de filtros tipo EasyList (sintaxis Adblock Plus) al formato
JSON de reglas de bloqueo de WebKit (WKContentRuleList).

Uso:
    python tools/convert_filters.py            # descarga listas y genera JSON
    python tools/convert_filters.py --offline  # usa las listas ya descargadas

Salida: Shield/Resources/Blocklists/*.json  (cada fichero < MAX_RULES reglas)
"""
import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "tools" / ".cache"
OUT = ROOT / "Shield" / "Resources" / "Blocklists"

LISTS = {
    "easylist": "https://easylist.to/easylist/easylist.txt",
    "easyprivacy": "https://easylist.to/easylist/easyprivacy.txt",
    "easylist_es": "https://easylist-downloads.adblockplus.org/easylistspanish.txt",
    "peterlowe": "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext",
}

MAX_RULES = 40000          # WebKit admite 150k por lista; usamos trozos más pequeños
SELECTORS_PER_RULE = 150   # selectores CSS agrupados por regla css-display-none

ALL_TYPES = ["document", "image", "style-sheet", "script", "font", "raw",
             "svg-document", "media", "popup", "ping", "other"]
TYPE_MAP = {
    "script": ["script"], "image": ["image", "svg-document"], "stylesheet": ["style-sheet"],
    "css": ["style-sheet"], "font": ["font"], "media": ["media"], "object": ["media"],
    "xmlhttprequest": ["raw"], "xhr": ["raw"], "websocket": ["raw"], "fetch": ["raw"],
    "ping": ["ping"], "popup": ["popup"], "other": ["other"], "document": ["document"],
    "doc": ["document"], "subdocument": ["document"], "frame": ["document"],
}
# Opciones que cambian el significado de la regla y no podemos representar -> se descarta la regla
UNSUPPORTED = {"csp", "redirect", "redirect-rule", "removeparam", "queryprune", "rewrite",
               "replace", "header", "permissions", "sitekey", "webrtc", "empty", "mp4",
               "inline-script", "inline-font", "to", "denyallow", "method", "badfilter",
               "generichide", "ghide", "elemhide", "ehide", "specifichide", "shide",
               "genericblock", "cname", "strict1p", "strict3p", "urltransform",
               "urlskip", "uritransform", "ipaddress", "reason", "jsonprune", "hls"}
IGNORED = {"important", "all", "match-case", "third-party", "3p", "first-party", "1p",
           "~third-party", "~3p", "~first-party", "~1p", "collapse", "~collapse"}

# Pseudo-clases propias de extensiones que WebKit no entiende
BAD_SELECTOR = re.compile(
    r":(-abp-|has-text|contains|xpath|upward|remove|style|matches-|min-text|watch-attr|"
    r"others|if|nth-ancestor|properties|matches-path|matches-attr|matches-prop|"
    r"remove-attr|remove-class|shadow)", re.I)
DOMAIN_OK = re.compile(r"^[a-z0-9.-]+$")


def fetch(name, url, offline):
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / f"{name}.txt"
    if not offline:
        print(f"descargando {name} ...", file=sys.stderr)
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 Shield-builder"})
        with urllib.request.urlopen(req, timeout=60) as r:
            path.write_bytes(r.read())
    return path.read_text(encoding="utf-8", errors="ignore").splitlines()


def domains(spec, sep):
    inc, exc = [], []
    for d in spec.split(sep):
        d = d.strip().lower()
        neg = d.startswith("~")
        d = d.lstrip("~")
        if not d or not DOMAIN_OK.match(d) or d.endswith(".*") or "." not in d:
            continue
        (exc if neg else inc).append("*" + d)
    return inc, exc


def pattern_to_regex(p):
    """Traduce el patrón ABP a la subconjunto de regex que admite WebKit."""
    if p in ("", "*", "|", "||"):
        return ".*"
    out = ""
    if p.startswith("||"):
        out = r"^[^:]+://+([^:/]+\.)?"
        p = p[2:]
    elif p.startswith("|"):
        out = "^"
        p = p[1:]
    end_anchor = p.endswith("|")
    if end_anchor:
        p = p[:-1]
    if "|" in p or "{" in p or "}" in p:
        return None  # WebKit no admite alternancia ni cuantificadores
    for i, c in enumerate(p):
        if c == "*":
            out += ".*"
        elif c == "^":
            out += r"([/:?&=].*)?$" if i == len(p) - 1 else r"[/:?&=]"
        elif c in ".+?()[]{}\\|$":
            out += "\\" + c
        else:
            out += c
    if end_anchor:
        out += "$"
    if not out.isascii():
        return None
    return out


def parse_network(line):
    exception = line.startswith("@@")
    if exception:
        line = line[2:]
    pattern, opts = line, ""
    if "$" in line and not (line.startswith("/") and line.endswith("/")):
        idx = line.rfind("$")
        pattern, opts = line[:idx], line[idx + 1:]
    if pattern.startswith("/") and pattern.endswith("/") and len(pattern) > 1:
        return None  # regex estilo JS: WebKit usa otro subconjunto, se omite
    trigger = {}
    types, neg_types = [], []
    for o in filter(None, (x.strip() for x in opts.split(","))):
        key = o.split("=", 1)[0].lower()
        if key.lstrip("~") in UNSUPPORTED:
            return None
        if key == "domain":
            inc, exc = domains(o.split("=", 1)[1], "|")
            if inc:
                trigger["if-domain"] = inc
            elif exc:
                trigger["unless-domain"] = exc
            else:
                return None
        elif key in ("third-party", "3p", "~first-party", "~1p"):
            trigger["load-type"] = ["third-party"]
        elif key in ("~third-party", "~3p", "first-party", "1p"):
            trigger["load-type"] = ["first-party"]
        elif key == "match-case":
            trigger["url-filter-is-case-sensitive"] = True
        elif key.lstrip("~") in TYPE_MAP:
            (neg_types if key.startswith("~") else types).extend(TYPE_MAP[key.lstrip("~")])
            if key.lstrip("~") in ("subdocument", "frame") and not key.startswith("~"):
                trigger["load-context"] = ["child-frame"]
        elif key in IGNORED:
            continue
        else:
            return None  # opción desconocida: mejor no arriesgar
    rx = pattern_to_regex(pattern)
    if rx is None:
        return None
    if rx == ".*" and "if-domain" not in trigger and not exception:
        return None  # bloquearía todo internet
    trigger = {"url-filter": rx, **trigger}
    if types:
        trigger["resource-type"] = sorted(set(types))
    elif neg_types:
        trigger["resource-type"] = [t for t in ALL_TYPES if t not in neg_types]
    if "load-context" in trigger and set(trigger.get("resource-type", [])) != {"document"}:
        del trigger["load-context"]
    if not exception and "resource-type" not in trigger:
        # sin tipo explícito: no bloquear la navegación principal (evita páginas en blanco)
        trigger["resource-type"] = [t for t in ALL_TYPES if t != "document"]
    action = {"type": "ignore-previous-rules" if exception else "block"}
    return exception, {"trigger": trigger, "action": action}


def valid_selector(sel):
    if not sel or BAD_SELECTOR.search(sel) or "{" in sel or "}" in sel or not sel.isascii():
        return False
    try:
        import soupsieve
        soupsieve.compile(sel)
        return True
    except Exception:
        return False


def convert(lines_by_list):
    blocks, exceptions = [], []
    generic = {}            # selector -> set(dominios de excepción)
    specific = {}           # (tuple(if-domain)) -> [selectores]
    generic_exc = []        # (domains, selector)
    stats = {"total": 0, "skipped": 0}
    for lines in lines_by_list:
        for raw in lines:
            line = raw.strip()
            if not line or line.startswith(("!", "[")):
                continue
            stats["total"] += 1
            if "#@#" in line:
                d, sel = line.split("#@#", 1)
                if d:
                    generic_exc.append((d, sel))
                continue
            if "##" in line:
                d, sel = line.split("##", 1)
                if not valid_selector(sel):
                    stats["skipped"] += 1
                    continue
                if not d:
                    generic.setdefault(sel, set())
                else:
                    inc, _ = domains(d, ",")
                    if not inc:
                        stats["skipped"] += 1
                        continue
                    specific.setdefault(tuple(sorted(inc)), []).append(sel)
                continue
            if re.search(r"#[?$%@]#|#\+js|\$\$|#\^", line):
                stats["skipped"] += 1  # scriptlets / filtros HTML / avanzados
                continue
            r = parse_network(line)
            if r is None:
                stats["skipped"] += 1
                continue
            (exceptions if r[0] else blocks).append(r[1])
    for d, sel in generic_exc:
        if sel in generic:
            inc, _ = domains(d, ",")
            generic[sel].update(inc)

    # Reglas CSS (ocultación cosmética)
    css = []
    plain = [s for s, exc in generic.items() if not exc]
    for i in range(0, len(plain), SELECTORS_PER_RULE):
        css.append({"trigger": {"url-filter": ".*"},
                    "action": {"type": "css-display-none", "selector": ", ".join(plain[i:i + SELECTORS_PER_RULE])}})
    for s, exc in generic.items():
        if exc:
            css.append({"trigger": {"url-filter": ".*", "unless-domain": sorted(exc)},
                        "action": {"type": "css-display-none", "selector": s}})
    for doms, sels in specific.items():
        for i in range(0, len(sels), SELECTORS_PER_RULE):
            css.append({"trigger": {"url-filter": ".*", "if-domain": list(doms)},
                        "action": {"type": "css-display-none", "selector": ", ".join(sels[i:i + SELECTORS_PER_RULE])}})

    # Deduplicar bloqueos
    seen, uniq = set(), []
    for r in blocks:
        k = json.dumps(r, sort_keys=True)
        if k not in seen:
            seen.add(k)
            uniq.append(r)
    blocks = uniq
    # Excepciones de documento completo ($document / $elemhide ya se descartan)
    stats.update(blocks=len(blocks), exceptions=len(exceptions), css=len(css))
    return blocks, exceptions, css, stats


def write_chunks(blocks, exceptions, css):
    OUT.mkdir(parents=True, exist_ok=True)
    for f in OUT.glob("*.json"):
        f.unlink()
    files = []
    room = MAX_RULES - len(exceptions)
    for n, i in enumerate(range(0, len(blocks), room)):
        # las excepciones van al final de cada trozo: en WebKit sólo afectan a su propia lista
        chunk = blocks[i:i + room] + exceptions
        name = f"network-{n + 1}.json"
        (OUT / name).write_text(json.dumps(chunk, separators=(",", ":")), encoding="utf-8")
        files.append((name, len(chunk)))
    for n, i in enumerate(range(0, len(css), MAX_RULES)):
        name = f"cosmetic-{n + 1}.json"
        (OUT / name).write_text(json.dumps(css[i:i + MAX_RULES], separators=(",", ":")), encoding="utf-8")
        files.append((name, len(css[i:i + MAX_RULES])))
    return files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--offline", action="store_true")
    args = ap.parse_args()
    lists = [fetch(n, u, args.offline) for n, u in LISTS.items()]
    blocks, exceptions, css, stats = convert(lists)
    files = write_chunks(blocks, exceptions, css)
    print(json.dumps(stats), file=sys.stderr)
    for name, count in files:
        print(f"  {name}: {count} reglas", file=sys.stderr)


if __name__ == "__main__":
    main()
