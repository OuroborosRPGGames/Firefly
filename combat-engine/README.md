# combat-engine

Vendored copy of the Rust combat engine from the Romance of Five Kingdoms
game repo. This is a snapshot — contributing a fix here is fine for Firefly,
but upstream the change against the source repo so other downstream games
benefit.

Source commit: 1c7f0280e65ee361be673a033d55f671439397d1

Build:

    ~/.cargo/bin/cargo build --release --manifest-path combat-engine/Cargo.toml

Run the socket server (used by Firefly's backend):

    ~/.cargo/bin/cargo run --release -p combat-server --manifest-path combat-engine/Cargo.toml
