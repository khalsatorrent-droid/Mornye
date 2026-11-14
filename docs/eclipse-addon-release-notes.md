# Mornye 5.3.1 + Eclipse add-on

Built on Mornye 5.3.1 (`45df9860`).

Android APKs are attached below: the **Lite** variant (the optional Discord
Social SDK is left out, since its key is not part of this fork), signed with the
debug key so they install once "install from unknown sources" is enabled.

* `Mornye-5.3.1-eclipse-arm64-v8a.apk` — most phones and tablets
* `Mornye-5.3.1-eclipse-armeabi-v7a.apk` — older 32-bit devices
* `Mornye-5.3.1-eclipse-universal.apk` — if unsure which one you need

iOS and desktop packages are not attached; build those from source or use the
upstream release. Checksums are in `SHA256SUMS.txt`.

## What's new

Mornye can serve its catalogue as an [Eclipse Music](https://eclipsemusic.app/)
add-on on your local network.

* **Settings → Eclipse add-on** — one switch, a port field (default **8089**),
  a download-source picker, the live manifest URLs for every network interface,
  a copy button and a restart action. Off by default.
* **The same catalogue as the app** — `/search` calls the same metadata
  provider search, the detail endpoints use the same provider records, and the
  catalog rows cover the home feed and your library.
* **Downloads into the library, then streams** — `/stream` answers at once with
  a URL; opening it queues the normal download (your output folder, naming,
  tags, cover art), sends the file as soon as the source has written its first
  bytes, and leaves it in the library so replays are instant.
* **Library first** — files you already have are offered first and play with no
  network at all.
* **Stable ids** — `mny:t:…`, `mny:a:…`, `mny:p:…`, `mny:r:…`, `mny:l:…` resolve
  without server state.

## Install

1. Settings → **Eclipse add-on** → turn on **Serve add-on on this network**.
2. Copy the manifest URL shown, e.g. `http://192.168.1.23:8089/manifest.json`.
3. In Eclipse Music: **Settings → Connections → Add Connection → Addon**, paste
   it, install **Mornye**.

Keep Mornye open while you listen. See
[docs/eclipse-addon.md](docs/eclipse-addon.md) for endpoints, limitations and
troubleshooting.

## Notes

* Eclipse asks for one stream URL per track, so the source comes from the
  settings page (default service, or a pinned download extension) rather than a
  per-track choice.
* Seeking is limited during the very first play of a track that is still being
  written; replays read the finished file and seek normally.
* The server listens on all interfaces on the chosen port and is meant for a
  trusted LAN. Eclipse expects HTTPS for anything reachable from outside.
* This build has been compiled in CI, but the add-on has not been exercised
  against Eclipse on a device, so it is published as a pre-release.
