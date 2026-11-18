# libopus for MyvuAudio

`COpus.xcframework` is built locally from the official libopus 1.6.1 source release:

- https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz
- SHA256: `6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1`
- License: `OPUS-LICENSE.txt` (upstream COPYING, retained without changes).
- Slices: iOS arm64; iOS Simulator arm64/x86_64; macOS arm64/x86_64.
- Static Release build, generic floating-point implementation; no neural extensions or external service.

Rebuild with `bash scripts/build-opus.sh` (requires CMake, Ninja, and full Xcode).
The script verifies the source archive checksum and refuses to overwrite an existing framework.
Only the optional `MyvuAudio` product depends on this binary. Existing SDK products have no new dependency.
