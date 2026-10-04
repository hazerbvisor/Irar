# Irar

A native RAR extractor for iPhone and iPad, built with SwiftUI and libarchive. Requires iOS 17 or later.

- Import RAR, RAR5 and ZIP archives from Files, including cloud providers.
- Inspect names and uncompressed sizes before extraction.
- Extract modern `.part01.rar` and legacy `.rar` / `.r00` multipart sets. Import **all volumes together**; their names must remain unchanged.
- Follow progress, cancel work, browse extracted folders and save files or entire folders back to Files.
- Each extraction creates a new folder. Existing files are never overwritten.

## Build on Codemagic

1. Add this GitHub repository to Codemagic and choose the branch containing the app (`feature/native-rar-extractor` while the pull request is open).
2. Use the repository's `codemagic.yaml`, choose **ios-unsigned**, and start the build.
3. Download **Irar-unsigned.ipa** from the build artifacts.
4. Sign and install the IPA with your preferred sideloading tool. An unsigned IPA cannot be installed directly.

The workflow builds libarchive from the source included in this repository. It needs no external runtime DLLs, JIT entitlement, binary framework download or signing credentials to produce the unsigned artifact. Codemagic's macOS build availability and account limits still apply.

For Xcode, simulator builds, signed distribution and testing, see [Build instructions](docs/BUILDING.md).

## Supported archives and limits

RAR and RAR5 support uses libarchive's readers; some unusual compression variants may be unsupported. ZIP supports stored and Deflate entries. Password-protected archives, 7z files, archive creation and background extraction are not supported.

Keep Irar in the foreground while working. Import stores a local copy, and extraction needs enough space for the uncompressed files. Cancelled or failed extractions retain completed files and remove the file being written. Archives containing links, special files or unsafe paths are rejected.

Inspection is limited to 100,000 entries and 32 MiB of names, with a 4,096-byte path limit. If inspection reaches a limit, extraction is unavailable for that archive. See [Implementation and validation](docs/BUILDING.md#implementation-and-validation) for details.

## License

Irar is licensed under GPL-3.0-or-later. libarchive has its own permissive notices, available inside the app and in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
