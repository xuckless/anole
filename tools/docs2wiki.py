#!/usr/bin/env python3
"""Turns Anole's docs/*.md into the GitHub wiki's pages.

    tools/docs2wiki.py docs <wiki checkout> <commit>

The Wiki workflow runs it on every push to main that changes docs/. A new
guide needs an entry in PAGES (the script refuses a file it has no page
for); a guide renamed or removed leaves its old page in the wiki, to be
deleted there by hand.

Links between guides become wiki links, links to other repository files
become github.com links at <commit>, code blocks are left alone, and each
page loses its H1 (the wiki shows the page name as the title).
"""
import os
import re
import sys

REPO = "https://github.com/xuckless/anole"

# docs file -> (wiki page, description), in reading order.
PAGES = {
    "getting-started.md": ("Getting-Started", "Install Zig, add Anole, write and run a first app."),
    "routing.md": ("Routing", "Routes, parameters, middleware, requests and responses, errors."),
    "server.md": ("Server", "Listeners, TLS, HTTP/2 and HTTP/3, limits, timeouts, drain and restarts."),
    "config.md": ("Config", "Typed settings, .env files, environment and deployment modes, trusted proxies."),
    "websocket.md": ("WebSocket", "WebSocket over HTTP/1.1, HTTP/2 and HTTP/3; the loop and callback APIs."),
    "webtransport.md": ("WebTransport", "WebTransport sessions, streams and datagrams over HTTP/3."),
    "grpc.md": ("gRPC", "gRPC services, gRPC-Web, Connect and JSON transcoding."),
    "clients.md": ("Clients", "Outbound HTTP/1.1, HTTP/2, HTTP/3 and gRPC from a handler."),
    "database.md": ("Database", "PostgreSQL, SQLite, MongoDB and Redis, and the opt-in caches."),
    "auth.md": ("Auth", "JWT, OIDC sign-in, sessions, CSRF, API keys, roles and rate limits."),
    "observability.md": ("Observability", "Access logs, Prometheus metrics, OpenTelemetry tracing, health checks."),
    "from-fiber.md": ("From-Fiber", "Fiber's API next to Anole's."),
}

LINK = re.compile(r"\]\(([^)\s]+)\)")


def convert_target(target, commit):
    if re.match(r"^[a-z]+:", target) or target.startswith("#"):
        return target
    path, _, anchor = target.partition("#")
    anchor = "#" + anchor if anchor else ""
    name = os.path.basename(path)
    if os.path.dirname(path) in ("", ".") and name in PAGES:
        return PAGES[name][0] + anchor
    # Anything else is a repository path relative to docs/.
    repo_path = os.path.normpath(os.path.join("docs", path))
    kind = "tree" if path.endswith("/") or "." not in os.path.basename(repo_path) else "blob"
    return f"{REPO}/{kind}/{commit}/{repo_path}{anchor}"


def convert(text, commit):
    out, fenced = [], False
    lines = text.splitlines()
    if lines and lines[0].startswith("# "):
        lines = lines[1:]
        while lines and not lines[0].strip():
            lines = lines[1:]
    for line in lines:
        if line.lstrip().startswith("```"):
            fenced = not fenced
        elif not fenced:
            line = LINK.sub(lambda m: "](" + convert_target(m.group(1), commit) + ")", line)
            # Link text naming a guide's file reads as the page's name.
            for name, (page, _) in PAGES.items():
                line = line.replace(f"[{name}](", f"[{page.replace('-', ' ')}](")
        out.append(line)
    return "\n".join(out) + "\n"


def main():
    src, dst, commit = sys.argv[1:4]
    os.makedirs(dst, exist_ok=True)
    present = sorted(f for f in os.listdir(src) if f.endswith(".md"))
    missing = [f for f in present if f not in PAGES]
    if missing:
        sys.exit(f"no wiki page name for {missing}")
    for name, (page, _) in PAGES.items():
        with open(os.path.join(src, name)) as f:
            text = f.read()
        with open(os.path.join(dst, page + ".md"), "w") as f:
            f.write(convert(text, commit))

    note = (f"These pages are copied from [`docs/`]({REPO}/tree/main/docs) in the "
            f"repository (commit [`{commit[:7]}`]({REPO}/commit/{commit})). To change one, "
            f"edit the file in `docs/` and open a pull request; edits made here are overwritten.")
    guides = "\n".join(f"| [{page.replace('-', ' ')}]({page}) | {desc} |" for page, desc in PAGES.values())
    with open(os.path.join(dst, "Home.md"), "w") as f:
        f.write(f"""Anole is a Zig server library: REST, WebSockets, gRPC, HTTP/3 and WebTransport
from one core, with TLS, auth, database connectors and observability built in.

Start with [Getting Started](Getting-Started), then read the guide for what you are building.

| Guide | What it covers |
| --- | --- |
{guides}

Also in the repository: the [README]({REPO}#readme) (features, build flags),
[CHANGELOG.md]({REPO}/blob/main/CHANGELOG.md), [SECURITY.md]({REPO}/blob/main/SECURITY.md)
and the [examples]({REPO}/tree/main/examples).

{note}
""")
    with open(os.path.join(dst, "_Sidebar.md"), "w") as f:
        f.write("**[Home](Home)**\n\n" + "\n".join(
            f"- [{page.replace('-', ' ')}]({page})" for page, _ in PAGES.values()) + "\n")
    with open(os.path.join(dst, "_Footer.md"), "w") as f:
        f.write(note + "\n")


if __name__ == "__main__":
    main()
