# Y-Sharp

**Self-hosted video & audio downloader.** Paste a link, pick a quality, keep the file. Video up to 4K, or audio ripped straight to MP3/M4A. Powered by [yt-dlp](https://github.com/yt-dlp/yt-dlp) + ffmpeg, served by FastAPI, with a single-page UI and no build step.

```
y-sharp/
├── app/
│   ├── main.py         # FastAPI routes, rate limiting, file serving
│   ├── downloader.py   # yt-dlp engine: probing, format selection, progress hooks
│   ├── jobs.py         # job registry + janitor that deletes expired files
│   └── config.py       # env-driven settings, ffmpeg/JS-runtime detection
├── static/index.html   # the whole UI (inline CSS/JS, zero dependencies)
├── tests/              # 20 offline tests — no network needed
├── run.py              # local dev launcher
├── Dockerfile          # cloud image (ffmpeg + node included)
├── render.yaml         # one-click Render deploy
└── .env.example        # every setting, documented
```

---

## Quick start

```bash
cd y-sharp
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python run.py          # -> http://localhost:8000
```

You need **ffmpeg** on PATH for merging video+audio and for MP3 conversion. If it's missing, Y-Sharp falls back to the `imageio-ffmpeg` bundled binary automatically — check `GET /api/health` to confirm (`"ffmpeg": true`).

Optional but recommended: **node** or **deno** on PATH. YouTube requires a JS runtime to solve stream signatures; without one many formats disappear.

System install: `sudo apt install ffmpeg nodejs` / `brew install ffmpeg node`.

---

## Deploying to the cloud

**Vercel and Netlify will not work** — they're serverless with short timeouts, read-only filesystems and no ffmpeg. Downloading a 300 MB video and merging it doesn't fit that model. Use a container host instead.

### Render
1. Push this folder to GitHub.
2. Render → **New → Blueprint** → pick the repo. `render.yaml` does the rest.
3. Use the **Starter** plan. Free instances sleep and kill long requests.

### Docker Compose (VPS / home server)
```bash
cp .env.example .env
chmod 600 .env
# Optional, after you have exported a local cookies.txt:
printf 'YSHARP_COOKIES_B64=%s\n' "$(base64 -w0 cookies.txt)" >> .env
docker compose up -d --build
```
On macOS, replace `base64 -w0 cookies.txt` with `base64 < cookies.txt | tr -d '\n'`. Add the cookie line only once; don’t commit `.env` or share its contents. Open `http://YOUR_SERVER:8000`; check `http://YOUR_SERVER:8000/api/health`. Logs: `docker compose logs -f y-sharp`. To update: `docker compose up -d --build`. The named `ysharp_data` volume keeps files and settings storage across container recreates. Set `YSHARP_PORT=8080` before startup to expose it on port 8080.

The image is `node:22-bookworm-slim` + Python + ffmpeg and runs as a non-root user. **YouTube may still require account cookies or a suitable network; Compose makes the service deployable, it does not bypass YouTube's IP checks.** See the next section for cookie setup.

### Behind Nginx
```nginx
location / {
    proxy_pass http://127.0.0.1:8000;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_read_timeout 3600s;      # long downloads
    client_max_body_size 0;
}
```

---

## YouTube on a cloud server: automatic fallback + full-quality options

YouTube sometimes blocks its desktop player on datacenter IPs. Y-Sharp tries `default` first, then automatically falls back to YouTube's Android player if the first client is blocked or exposes no downloadable streams. The Android client worked from a datacenter in our live test, but only exposed a **360p** progressive MP4 for the test video. When this happens the UI flags **Limited mode** and shows the actual resolutions available; it does not pretend 4K is downloadable.

### Enable higher YouTube resolutions

1. In a browser where you are signed into YouTube, export a Netscape-format `cookies.txt` for `youtube.com` using a trusted local cookie-export method. Use only an account you are comfortable using for this, and only for videos you are authorized to download.
2. Set `YSHARP_COOKIES_B64` as a **secret environment variable** on the machine running Y-Sharp. Do not paste the cookie file or its encoded value into chat, commit it to Git, or expose it in a public issue.

For Linux, create a private `.env` file next to your Docker command:

```bash
printf 'YSHARP_COOKIES_B64=%s\n' "$(base64 -w0 cookies.txt)" > .env
chmod 600 .env
# When creating/recreating the container:
docker run --env-file .env -p 8000:8000 -v ysharp_data:/data y-sharp
```

On macOS, use `$(base64 < cookies.txt | tr -d '\n')` instead of `base64 -w0`. On Render, add `YSHARP_COOKIES_B64` under the service's Environment settings, paste the locally generated base64 value there, and save/redeploy. For a non-Docker VPS process, export it before starting `python run.py` or Uvicorn:

```bash
export YSHARP_COOKIES_B64="$(base64 -w0 cookies.txt)"
python run.py
```

Restart or recreate Y-Sharp after changing the secret. Check `GET /api/health`: `"cookies": true` means the file was loaded. Then submit the YouTube link again; `POST /api/info` should show more available heights if YouTube serves them to that account/server. If it still only shows 360p, the cookie export may be incomplete/expired or that video/account/server may not expose higher formats. Cookies expire periodically, so rotate them when needed. A residential proxy can also help with IP-based restrictions:

```bash
export YSHARP_PROXY=http://user:pass@host:port
```

You can override the fallback sequence with `YSHARP_YT_CLIENTS=default,android`. A normal home ISP connection often avoids the datacenter bot check, but YouTube behavior changes and no client or proxy can guarantee access to every video.

An optional BgUtils PO-token provider can be configured with `YSHARP_POT_BASE_URL` if you run the provider separately. PO tokens are not a guaranteed workaround for bot checks or YouTube's current SABR-only streams.
---

## API

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/health` | ffmpeg / JS runtime / cookies / load status |
| `POST` | `/api/info` | `{url}` → title, thumbnail, duration, available heights, formats |
| `POST` | `/api/download` | `{url, mode, quality, audio_format, audio_bitrate}` → `{job_id}` |
| `GET` | `/api/jobs/{id}` | status, progress %, speed, ETA, stage, filename |
| `GET` | `/api/jobs/{id}/file` | the finished file (attachment) |
| `POST` | `/api/jobs/{id}/cancel` | request cancellation |
| `DELETE` | `/api/jobs/{id}` | delete the job and its file immediately |
| `GET` | `/api/jobs` | last 50 jobs |

Interactive docs at `/docs`.

```bash
# probe
curl -X POST localhost:8000/api/info -H 'Content-Type: application/json' \
     -d '{"url":"https://www.youtube.com/watch?v=..."}'

# queue a 1080p download
curl -X POST localhost:8000/api/download -H 'Content-Type: application/json' \
     -d '{"url":"https://youtu.be/...","mode":"video","quality":"1080"}'

# rip audio
curl -X POST localhost:8000/api/download -H 'Content-Type: application/json' \
     -d '{"url":"https://soundcloud.com/...","mode":"audio","audio_format":"mp3","audio_bitrate":"320"}'
```

**Quality values:** `best`, `2160`, `1440`, `1080`, `720`, `480`, `360`, `240`, `144`.
**Audio formats:** `mp3`, `m4a`, `opus`, `best`.

Video downloads prefer H.264/AAC in an MP4 container so the result plays everywhere (iPhone, TV, QuickTime) instead of a VP9/Opus file that some players choke on.

---

## Design decisions worth knowing

- **Jobs, not blocking requests.** `POST /api/download` returns instantly with a `job_id`; the UI polls every 800 ms. No request sits open for ten minutes, so proxies and browsers can't time it out.
- **Files are ephemeral by design.** Each job gets its own directory under the data dir; a janitor thread deletes files 30 minutes after completion (`YSHARP_FILE_TTL`). The browser's "Recent" list lives in `localStorage` and re-fetches by job id, so it degrades gracefully when a file has expired.
- **The engine never raises into the queue.** `download()` catches everything and always leaves a terminal state, so a crashed job can't wedge the UI.
- **Automatic YouTube client fallback.** The default player is tried first; if it is bot-checked or exposes no usable stream, Y-Sharp retries the configured client sequence (by default, `android`). The UI warns when it had to fall back and only offers qualities the probe actually found.
- **Friendly errors.** yt-dlp's raw exception text is mapped to one actionable sentence ("This video is age-restricted. Sign-in cookies are required…"), because the raw text is four lines of GitHub links.
- **Guards out of the box.** Per-IP rate limiting, a queue cap, max duration, max file size, and a concurrency limit of 2 — enough to stop one user from pinning your VPS.
- **No CDN, no fonts, no framework.** The UI is one HTML file with inline CSS/JS, so it loads instantly and works offline / behind a strict CSP.

---

## Configuration

See `.env.example` for the annotated list. Highlights:

| Variable | Default | Meaning |
|---|---|---|
| `YSHARP_DATA_DIR` | `/tmp/ysharp` | where files are written |
| `YSHARP_FILE_TTL` | `1800` | seconds before finished files are deleted |
| `YSHARP_MAX_CONCURRENT` | `2` | parallel downloads |
| `YSHARP_MAX_QUEUE` | `25` | refuse new jobs past this depth |
| `YSHARP_MAX_DURATION` | `14400` | reject videos longer than 4 h |
| `YSHARP_MAX_FILESIZE_MB` | `2048` | reject oversized files |
| `YSHARP_RATE_LIMIT` | `20` | requests/min/IP (0 = off) |
| `YSHARP_COOKIES_B64` | — | base64 cookies.txt for sign-in / full quality |
| `YSHARP_PROXY` | — | outbound proxy |
| `YSHARP_YT_CLIENTS` | `default,android` | player-client fallback order |
| `YSHARP_POT_BASE_URL` | — | optional BgUtils PO-token server URL |
| `YSHARP_JS_RUNTIME` | auto | `node` / `deno` / `bun` |

---

## Tests

```bash
python -m pytest tests -q      # 25 passed — no network required
```

Covers URL hardening (rejects `javascript:` and non-http schemes), option validation, format selection, error mapping, player-client fallback (including a client that returns thumbnails only), the full job lifecycle with the engine stubbed, expiry cleanup, and file delivery.

---

## Maintenance

yt-dlp ships extractor fixes constantly — YouTube breaks within days of a lag. Rebuild monthly:

```bash
pip install -U yt-dlp          # local
docker build --no-cache -t y-sharp .   # container
```

Pin the version in `requirements.txt` if you need reproducibility, but then set a reminder to bump it.

---

## Legal

Y-Sharp is a tool, and like any recording tool it can be misused. Use it for content you own, content licensed for reuse (Creative Commons, public domain), or where local law permits — downloading a video doesn't transfer any rights you didn't already have, and re-uploading someone else's work is infringement regardless of how you got the file. YouTube's Terms of Service prohibit downloading except through features they provide; that's between you and them. If you deploy this for other people, add your own terms page.
