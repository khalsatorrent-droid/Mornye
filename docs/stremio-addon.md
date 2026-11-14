# Stremio add-on

Mornye can serve its catalogue as a [Stremio](https://www.stremio.com/) add-on
on your local network. Stremio shows the same providers the app shows, and
plays through Mornye's own download pipeline: pick a source, the track is
downloaded into your library, and the file is streamed from there.

The add-on is off by default.

## Turning it on

1. Open **Settings → Stremio add-on**.
2. Turn on **Serve add-on on this network**. The server starts on port
   **8089** by default; change the port in the same page if it is taken.
3. Copy one of the **Manifest URLs** shown (they look like
   `http://192.168.1.23:8089/manifest.json`).

The page lists one address per network interface, private ranges first. Use the
address that is on the same network as the device running Stremio.

## Installing in Stremio

On a phone, tablet, TV or computer on the same network:

1. Open Stremio → **Add-ons** → **Install from URL** (or paste the manifest URL
   into the search bar).
2. Paste the manifest URL and install **Mornye Music**.

Keep Mornye open while you watch: the app resolves the download and serves the
audio file.

## What Stremio gets

Four catalogs, all under the `movie` type because that is the type every
Stremio client renders:

| Catalog | What it shows |
| --- | --- |
| **Mornye · Home** | The same home feed the app's Home tab uses, from the home-feed provider selected in Settings → Extensions. |
| **Mornye · Search** | Provider search, identical to searching in the app. |
| **Mornye · Library** | Everything already in your library, including local folders. |
| **Mornye · Library Search** | Search over the library only. |

Opening an album, playlist or artist lists its tracks as episodes; each track
opens its own stream list.

## Streams

Every track's stream list contains:

* **Mornye · Library** when the file is already on the device — plays instantly.
* One entry per enabled download extension, and per quality that extension
  offers. These are exactly the sources the app can download from, in the
  order configured under **Settings → Extensions → Provider Priority**.

Choosing a source:

1. Queues the track in Mornye's normal download queue, with your configured
   output folder, naming, tags and cover art.
2. Starts sending the file as soon as the source has written the first bytes,
   so playback starts before the download finishes.
3. Leaves the finished file in your library, so playing it again later is
   instant and needs no network.

If a download fails, Stremio reports the failure and the app queue shows the
error, with the usual retry.

## Endpoints

The server implements the plain Stremio add-on protocol:

| Endpoint | Purpose |
| --- | --- |
| `GET /manifest.json` | Add-on manifest, catalogs and resources. |
| `GET /catalog/movie/<catalogId>.json` | Catalog page; `search=` and `skip=` are honoured. |
| `GET /catalog/movie/<catalogId>/search=<q>&skip=<n>.json` | Catalog page with extras in the path. |
| `GET /meta/movie/<id>.json` | Track, album, playlist or artist detail. |
| `GET /stream/movie/<id>.json` | Stream list for one track. |
| `GET /play/<id>?m=dl&s=<source>&q=<quality>` | The audio file, with `Range` support. |
| `GET /cover/<libraryRowId>` | Cover art for a library item. |
| `GET /health` | Liveness check. |

Item ids look like `mny:t:<source>.<trackId>`, `mny:a:…` (album),
`mny:p:…` (playlist), `mny:r:…` (artist) and `mny:l:<rowId>` (library file).
They are stable across restarts, so Stremio's history keeps working.

## Limitations

* **The app must stay open.** The add-on runs inside Mornye, not as a separate
  service. On Android, keep the download service running so the queue is not
  paused.
* **Same network only.** The server listens on all interfaces on the given
  port and is meant for a trusted LAN. Do not expose it to the internet.
* **Paused queue, no playback.** If you pause downloads in Mornye, playback
  requests fail until you resume.
* **Seeking while downloading.** The first play of a track that is still being
  written is a chunked stream, so seeking is limited until the download
  finishes. Later plays read the finished file and seek normally.
* **SAF storage (Android).** When the download folder is a SAF tree, the file
  is copied to the app cache before it is served.
* **One type.** Everything is exposed as `movie`; Stremio clients do not have
  a dedicated music type, so albums appear as items with an episode list.

## Troubleshooting

* **Stremio cannot reach the add-on.** Check the address on the Settings page,
  make sure both devices are on the same Wi-Fi (guest networks usually isolate
  clients), and allow Mornye through the device firewall.
* **"Could not listen on port 8089".** Something else is using the port.
  Choose another one on the Settings page and press **Restart server**.
* **Stream list is empty.** The track needs an enabled download extension. Add
  one under **Settings → Extensions → Repo**.
* **Playback stops early.** The download failed or timed out; open the queue in
  Mornye to see why.
