# iDownloader — Fork & Licensing Notice

iDownloader is a fork of [Ghost-Downloader-3](https://github.com/XiaoYouChR/Ghost-Downloader-3)
by XiaoYouChR. This repository is **not** the original project.

## Modification notice (GPLv3 §5a)

This program is a **modified version** of Ghost-Downloader-3. It was forked on
**2026-09-27** and has been modified continuously since; every modification is recorded
in the git history of this repository.

- Original work **Ghost-Downloader-3**: copyright © 2024–2026 XiaoYouChR,
  https://github.com/XiaoYouChR/Ghost-Downloader-3
- **iDownloader** fork and its modifications: copyright © 2026 Subham Subhasis Patra,
  https://github.com/SubhamSubhasisPatra/iDownloader

The major modifications so far:

- A native **iOS / iPadOS / Mac (Catalyst) client** written in Swift (`ios/`), including a
  vendored and patched copy of the swift-torrent library (`ios/Vendor/SwiftTorrent`).
- HTTP engine changes: pooled connection reuse, slow-connection stealing and retirement.
- BitTorrent tuning, GitHub proxy-site expansion, duplicate-file handling.
- The fork is rebranded as **iDownloader** and maintained separately from upstream.

## License

iDownloader is free software: you can redistribute it and/or modify it under the terms of
the **GNU General Public License as published by the Free Software Foundation, version 3**
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but **without any
warranty**; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the [GNU General Public License](LICENSE) for details.

Commercial use, sale, and redistribution of iDownloader are permitted **only under the
terms of GPLv3** — copies (including sold copies) must carry this license and must come
with access to the corresponding source code. See [docs/distribution.md](docs/distribution.md)
if you plan to sell or redistribute it.

## Source code availability (GPLv3 §6)

Every released binary of iDownloader (`.ipa`, `.dmg`, `.exe`, `.apk`, …) corresponds to a
tagged release of this public repository. The complete corresponding source for any
distributed build is available at no charge at:

> https://github.com/SubhamSubhasisPatra/iDownloader

(For a specific build, use the same version tag. If you received a binary copy and cannot
find its source, ask the person or store that provided it.)

## Third-party components

Bundled third-party code keeps its own license. The iOS app's dependencies are listed in
[ios/THIRD-PARTY-NOTICES.md](ios/THIRD-PARTY-NOTICES.md); the desktop/Android Python
dependencies are listed in the README's References section.

## Trademark / origin care

iDownloader is an independent fork. It is not made by, endorsed by, or affiliated with
XiaoYouChR or the Ghost Downloader project; the original project lives at
https://github.com/XiaoYouChR/Ghost-Downloader-3. Distributors must not present
iDownloader as the original Ghost Downloader or imply upstream endorsement.
