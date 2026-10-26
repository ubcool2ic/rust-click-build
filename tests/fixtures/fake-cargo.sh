#!/usr/bin/env bash
# Fake cargo for tests. Logs every call to $FAKE_CARGO_LOG.
# FAKE_CARGO_FAIL_TAG=v1.0.1 makes `cargo build` fail when the manifest pins that tag.
echo "$*" >> "${FAKE_CARGO_LOG:-/dev/null}"
case "$1" in
  --version) echo "cargo 1.99.0 (fake)"; exit 0 ;;
  metadata) echo '{"target_directory":null}'; exit 0 ;;
  update) [ "${FAKE_CARGO_UPDATE_EXIT:-0}" = 0 ] && echo "    Updating git repository rtk" ; exit "${FAKE_CARGO_UPDATE_EXIT:-0}" ;;
  build)
    mp=""; prev=""
    for a in "$@"; do [ "$prev" = "--manifest-path" ] && mp="$a"; prev="$a"; done
    if [ -n "$FAKE_CARGO_FAIL_TAG" ] && grep -q "tag = \"$FAKE_CARGO_FAIL_TAG\"" "$mp"; then
      echo "error[E0425]: cannot find function \`old_api\` in crate \`rtk\`" >&2
      echo "  --> src/main.rs:3:10" >&2
      echo "error: could not compile \`app\`" >&2
      exit 101
    fi
    echo "   Compiling fake v0.1.0"; echo "    Finished"; exit 0 ;;
  *) exit 0 ;;
esac
