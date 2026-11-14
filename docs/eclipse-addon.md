# Eclipse add-on

Mornye can serve its catalogue as an [Eclipse Music](https://eclipsemusic.app/)
add-on on your local network. Eclipse searches the same providers the app uses,
and plays through Mornye's own download pipeline: the track is downloaded into
your library and the file is streamed from there.

The add-on is off by default.

## Turning it on

1. Open **Settings → Eclipse add-on**.
2. Turn on **Serve add-on on this network**. The server starts on port
   **8089** by default; change the port on the same page if it is taken.
3. Pick a **Download source**, or leave it on **Default service** to use
   whatever Settings → Download uses.
4. Copy one of the **Manifest URLs** shown (they look like
   `http://192.168.1.23:8089/manifest.json`).

The page lists one address per network interface, private ranges first. Use the
address that is on the same network as the device running Eclipse.

## Installing in Eclipse

1. Eclipse Music → **Settings → Connections → Add Connection → Addon**.
2. Paste the manifest URL and install **Mornye**.

Eclipse accepts plain HTTP for local network addresses, so no certificate is
needed. Keep Mornye open while you listen: the app resolves the download and
serves the audio file.

## What Eclipse gets

| Endpoint | What it serves |
| --- | --- |
| `GET /manifest.json` | Add-on manifest, resources and catalog rows. |
| `GET /search?q=` | Provider search — tracks, albums, artists and playlists — with your own library files first. |
| `GET /stream/{id}` | The URL Eclipse plays for one track. |
| `GET /album/{id}` | Album tracks, from the same metadata provider the app uses. |
| `GET /artist/{id}` | Artist top tracks and albums. |
| `GET /playlist/{id}` | Playlist tracks. |
| `GET /catalog/{id}?skip=` | The declared rows: **Mornye · Home** and **Mornye · Library**. |
| `GET /play/{id}` | The audio itself, with `Range` support. |
| `GET /cover/{libraryRowId}` | Cover art for a library item. |
| `GET /health` | Liveness check. |

Item ids look like `mny:t:<source>.<trackId>`, `mny:a:…` (album),
`mny:p:…` (playlist), `mny:r:…` (artist) and `mny:l:<rowId>` (library file),
so an id passed back to `/stream` or a detail endpoint resolves without state.

## How playback works

`/stream/{id}` answers immediately with a URL; it does not download anything.
When Eclipse opens that URL:

1. If the track is already in your library, the file is served straight away.
2. Otherwise the track is queued in Mornye's normal download queue — your
   output folder, naming, tags and cover art — and the file is sent as soon as
   the source has written its first bytes, so playback starts before the
   download finishes.
3. The finished file stays in the library, so the next play needs no network.

A failed download comes back as an error, and the queue in Mornye shows why.

## Limitations

* **The app must stay open.** The add-on runs inside Mornye, not as a separate
  service. On Android, keep the download service running so the queue is not
  paused.
* **Same network only.** The server listens on all interfaces on the given port
  and is meant for a trusted LAN. Do not expose it to the internet; Eclipse
  expects HTTPS for anything reachable from outside.
* **One source per track.** Eclipse asks for a single stream URL, so the source
  is the one chosen on the settings page rather than a per-track choice.
* **Seeking while downloading.** The first play of a track that is still being
  written is a chunked stream, so seeking is limited until the download
  finishes. Later plays read the finished file and seek normally.
* **SAF storage (Android).** When the download folder is a SAF tree, the file
  is copied to the app cache before it is served.

## Troubleshooting

* **Eclipse cannot reach the add-on.** Check the address on the Settings page,
  make sure both devices are on the same Wi-Fi (guest networks usually isolate
  clients), and allow Mornye through the device firewall.
* **"Could not listen on port 8089".** Something else is using the port. Pick
  another one and press **Restart server**.
* **Search returns nothing.** The catalogue comes from your metadata provider:
  check it is enabled under **Settings → Extensions**.
* **Playback fails immediately.** No download extension is enabled, or the
  queue is paused in Mornye. Both are reported on the player.
