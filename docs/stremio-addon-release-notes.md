# Mornye 5.3.1 + Stremio add-on

Built on Mornye 5.3.1 (`45df9860`). Binaries are attached by the Release
workflow when this repository has its signing secrets; if the build jobs fail,
this release stays source-only and can be built with the usual `flutter build`
and `cargo` steps from [CONTRIBUTING.md](CONTRIBUTING.md).

## What's new

Mornye can now serve its catalogue as a Stremio add-on on your local network.

* **Settings → Stremio add-on** — one switch, a port field (default **8089**),
  the live manifest URLs for every network interface, a copy button and a
  restart action. Off by default.
* **The same catalogue as the app** — Home uses the home-feed provider the app
  uses, Search calls the same provider search, and Library / Library Search
  read the library database. No second implementation of the providers.
* **Every download source you have** — a track's stream list has one entry per
  enabled download extension and per quality that extension offers, plus the
  copy already in your library.
* **Downloads into the library, then streams** — choosing a source queues the
  normal download (your output folder, naming, tags, cover art), playback
  starts as soon as the source has written the first bytes, and the finished
  file stays in the library so replays are instant.
* **Stable ids** — `mny:t:…`, `mny:a:…`, `mny:p:…`, `mny:r:…`, `mny:l:…`
  survive restarts, so Stremio history keeps working.

## Install

1. Settings → **Stremio add-on** → turn on **Serve add-on on this network**.
2. Copy the manifest URL shown, e.g. `http://192.168.1.23:8089/manifest.json`.
3. In Stremio on another device on the same network: **Add-ons → Install from
   URL**, paste it, install **Mornye Music**.

Keep Mornye open while you stream. See
[docs/stremio-addon.md](docs/stremio-addon.md) for catalogs, endpoints,
limitations and troubleshooting.

## Notes

* Everything is exposed under Stremio's `movie` type — Stremio has no music
  type, so albums and playlists list their tracks as episodes.
* Seeking is limited during the very first play of a track that is still being
  written; replays read the finished file and seek normally.
* The server listens on all interfaces on the chosen port and is meant for a
  trusted LAN. Do not expose it to the internet.
* This build has been syntax-checked and reviewed, not compiled in CI before
  release, so it is published as a pre-release.
