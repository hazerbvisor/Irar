# Building Irar

## Requirements

- macOS with Xcode 15 or newer and an iOS SDK supporting iOS 17. Current Xcode is recommended.
- Xcode command-line tools selected with `xcode-select`.
- Python 3 for the backend tests; Swift and C compilers are provided by Xcode.

Open `Irar.xcodeproj` and select the shared **Irar** scheme. For a physical device, select your team in Signing & Capabilities and, if necessary, choose your own unique bundle identifier. The default is `com.hazerbvisor.Irar`.

No dependency manager is required. The first build configures and compiles the pinned libarchive source archive with the Apple compiler. Rebuilds reuse the compiled library when the SDK, architecture, bridge and build script match. Both device and simulator builds are supported.

## Unsigned IPA

Codemagic runs the following commands after validating and testing the repository:

```sh
xcodebuild -project Irar.xcodeproj -scheme Irar -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
bash scripts/package-ipa.sh
```

The artifact is `build/Irar-unsigned.ipa`. It contains `Payload/Irar.app`. Use a sideloading tool to sign it for your device. A successful unsigned build does not establish that a particular sideloading service or signing account will accept it.

For signed installation or App Store/TestFlight distribution, use Xcode signing and Archive/Distribute App with your Apple developer account. The included Codemagic workflow only packages an unsigned IPA.

The optional GitHub Actions workflow also tests and builds an unsigned IPA on macOS; download the `Irar-unsigned-ipa` artifact from a successful run.

## Tests

```sh
bash tests/run-tests.sh
```

This builds the actual pinned library in a temporary directory and runs C/Python archive tests, Swift storage and bridge integration tests, SwiftUI syntax parsing, and project-input checks. The host tests work on macOS or Linux with Swift, a C compiler, make, Python 3, zlib development headers, tar and shasum. Temporary build products are removed afterward.

Coverage includes upstream real RAR/RAR5 and multipart fixtures, ZIP extraction, traversal and symlink rejection, exclusive output creation, cancellation cleanup, 64 MiB file import, part ordering, Unicode destinations, and Swift/C metadata and extraction. On Linux, a 256 MiB ZIP is extracted in a subprocess restricted to 160 MiB of address space to check streaming behavior. That memory-limit test is skipped on macOS because its process address-space limits behave differently.

The fixtures are decoded from libarchive's own test data in the vendored source package; tests require no network downloads. UI parsing on Linux is only a syntax check. An Xcode build is required to validate Apple SDK integration, and on-device testing is required to assess file providers, signing, UI behavior and foreground/background transitions.

## Implementation and validation

`FileStore` coordinates security-scoped provider reads, copies data in 64 KiB chunks and keeps user files in Documents/Imports and Documents/Extracted. Multipart detection chooses the first volume, orders parts numerically and rejects missing or duplicated parts. Existing import names cause an error rather than being silently renamed, preserving volume associations.

`ArchiveService` invokes the C bridge from a detached task and sends throttled progress updates to the main actor. It retains at most 100,000 entry records and 32 MiB of name data. It supports 64-bit byte counts; neither import nor extraction loads an entire archive into memory. Listing may still take time to decode a RAR stream.

The C bridge reads RAR, RAR5 and ZIP directly through libarchive. It validates paths and entry types, rejects links and special files, traverses the output using descriptor-relative operations and `O_NOFOLLOW`, and creates files exclusively. Cancellation removes the current partial output while keeping completed files. New extraction directories have unique names. The app does not preserve archive ownership, permissions or executable bits.

Extraction has no fixed total-output quota. Check available storage before starting large or unfamiliar archives. Out-of-space and unsupported/corrupt archive errors leave completed files available for export or deletion. Keep the app in the foreground; iOS can suspend its work in the background.

The app exposes its Documents folder through Files. Changes made there appear after Refresh. Extracted folders and files can also be exported using the system document picker without reading their contents into a Swift `Data` buffer.

## Source provenance

libarchive 3.8.7 is included as `vendor/libarchive-3.8.7.tar.xz`, sourced from the official libarchive release. SHA-256:

```text
d3a8ba457ae25c27c84fd2830a2efdcc5b1d40bf585d4eb0d35f47e99e5d4774
```

The build checks that digest before using the package. Optional external codecs, crypto libraries, tools and metadata dependencies are disabled; system zlib is the only external compression library. RAR decoding is implemented within libarchive.

The native archive bridge and adapter were adapted from the GPL-compatible file-manager work in [Madeira-QoL](https://github.com/hazerbvisor/Madeira-QoL/pull/1). Irar builds independently and does not include Madeira, Wine, Box64, Microsoft runtimes or their IPA assets.
