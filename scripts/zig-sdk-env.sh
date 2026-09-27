# Sourced by the zig build scripts after DEVELOPER_DIR is exported. When that
# Xcode's macOS SDK is too new for the pinned Zig (26.4+, ziglang/zig#31658),
# route zig's `xcrun --show-sdk-path` lookups to a Command Line Tools SDK it
# can link, and archive with that SDK's libtool. xcodebuild, metal, and the
# rest of xcrun still use DEVELOPER_DIR.
zig_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if [ "$(printf '%s\n26.3\n' "${zig_sdk_version}" | sort -V | tail -1)" != "26.3" ]; then
  ZIG_SDKROOT="$("${script_dir}/zig-sdk-fallback.sh")"
  export ZIG_SDKROOT
  export PATH="${script_dir}/zig-sdk-shim:${PATH}"
fi
