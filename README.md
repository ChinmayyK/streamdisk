# StreamDisk

StreamDisk mounts your Google Drive as a disk on your Mac. Files show up in Finder at full size but take no space on your Mac. When you open one, only the bytes the app reads are fetched, so a 50 GB video starts playing in a second or two in any player: QuickTime, IINA, VLC, Final Cut, and others.

## How it works

- StreamDisk runs a small NFSv3 server on `127.0.0.1` and mounts it with the macOS NFS client. No kernel extension, no system extension, no root.
- Reads become HTTP range requests against the Google Drive API. Data is cached in memory in 1 MiB chunks and never written to disk.
- Downloads are scheduled by urgency. Bytes a player is blocked on go first, the file's tail (where MP4/MOV and MKV keep their index) is fetched on open, and readahead grows while you watch and is cancelled when you seek.
- The app uses the `drive.file` scope. It sees only the files it puts in Drive, which live in a `StreamDisk` folder.
- The Google refresh token is stored in the macOS Keychain.

Swift 6, no third-party dependencies.

## Build

Requires macOS 14 or later and Xcode.

```sh
scripts/setup-signing.sh   # once: local code-signing identity, no Apple account needed
scripts/build.sh           # builds .build/debug/streamdisk
```

## Use

You need a Google OAuth client of type "Desktop app" with the Drive API enabled.

```sh
streamdisk login --client ~/Downloads/client_secret_….json
streamdisk put ~/Movies/trip.mov --to films
streamdisk mount            # mounts at ~/StreamDisk; Ctrl-C to unmount
```

## Tests

```sh
swift test
STREAMDISK_MOUNT_TESTS=1 swift test   # also mounts a real volume through the system NFS client
```

## License

StreamDisk is free and open source under the [GNU General Public License v3.0](LICENSE).
