# Y-Sharp — cloud image
# node is included because yt-dlp needs a JS runtime to solve YouTube signatures.
FROM node:22-bookworm-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    YSHARP_DATA_DIR=/data \
    YSHARP_JS_RUNTIME=node

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip ffmpeg curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN python3 -m pip install --break-system-packages -r requirements.txt

COPY app ./app
COPY static ./static

RUN mkdir -p /data && useradd -m -u 10001 ysharp && chown -R ysharp:ysharp /data /app
USER ysharp

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD curl -fsS "http://127.0.0.1:${PORT:-8000}/api/health" || exit 1

CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000} --proxy-headers --forwarded-allow-ips='*'"]
