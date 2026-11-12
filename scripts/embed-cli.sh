#!/bin/zsh
# Xcode build phase (macOS): builds the Rust bla in cli/ for the app's architectures and puts it in the app's
# Resources in place of the bla shell script, signed like the app. Without cargo the script stays, and bla runs
# the Swift command line in the app instead.
set -eu
[ "${PLATFORM_NAME:-macosx}" = macosx ] || exit 0
root=${0:A:h:h}
cargo=$(command -v cargo || true)
if [ -z "$cargo" ]; then
  for c in "$HOME/.cargo/bin/cargo" $HOME/.rustup/toolchains/stable-*/bin/cargo(N); do
    [ -x "$c" ] && { cargo=$c; break; }
  done
fi
if [ -z "$cargo" ]; then
  echo "warning: cargo not found; the app keeps the shell-script bla (Swift command line)"
  exit 0
fi
export PATH="${cargo:h}:$PATH"
export CARGO_TARGET_DIR="$root/cli/target"
sysroot=$(rustc --print sysroot)
built=()
for arch in ${=ARCHS:-arm64}; do
  case $arch in
    arm64) triple=aarch64-apple-darwin ;;
    x86_64) triple=x86_64-apple-darwin ;;
    *) continue ;;
  esac
  if [ ! -d "$sysroot/lib/rustlib/$triple" ]; then
    echo "warning: Rust target $triple is not installed (rustup target add $triple); bla is built without $arch"
    continue
  fi
  "$cargo" build --release --quiet --manifest-path "$root/cli/Cargo.toml" --target "$triple"
  built+=("$CARGO_TARGET_DIR/$triple/release/bla")
done
if [ ${#built} -eq 0 ]; then
  echo "warning: no Rust target for $ARCHS; the app keeps the shell-script bla"
  exit 0
fi
dest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/bla"
rm -f "$dest"
lipo -create "${built[@]}" -output "$dest"
chmod 755 "$dest"
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "$dest"
else
  codesign --force --sign - "$dest"
fi
