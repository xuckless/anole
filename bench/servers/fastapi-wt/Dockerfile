# Python WebTransport bench server (aioquic 1.7.0, draft-02). Build from the repository root:
#   docker build -f bench/servers/fastapi-wt/Dockerfile -t anole-bench/fastapi-wt .
FROM python:3.13.16-slim-trixie
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY bench/servers/fastapi-wt/requirements.txt .
RUN pip install --no-cache-dir --root-user-action=ignore -r requirements.txt
COPY bench/servers/fastapi-wt/server.py .
ENTRYPOINT ["python", "server.py"]
