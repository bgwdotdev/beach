# beach

[![Package Version](https://img.shields.io/hexpm/v/beach)](https://hex.pm/packages/beach)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/beach/)

A library for serving a [shore](https://github.com/bgwdotdev/shore) TUI over ssh.

Further documentation can be found at <https://hexdocs.pm/beach>.

## Host Keys

Beach requires your provide ssh host keys for your application. You can create these by running the following command:

```sh
# this is only needed once
ssh-keygen -t ed25519 -f ssh_host_ed25519_key -N ''
```

## Example

```sh
gleam add beach@1
```
```gleam
import beach
import shore

pub fn main() {
  let exit = process.new_subject()
  let spec =
    shore.spec(
      init:,
      update:,
      view:,
      exit:,
      keybinds: shore.default_keybinds(),
      redraw: shore.on_timer(16),
    )
  let config =
    beach.config(
      port: 2222,
      host_key_directory: ".",
      auth: beach.auth_anonymous(),
      on_connect: fn(_connection, _shore) { Nil },
      on_disconnect: fn(_connection, _shore) { Nil },
      max_sessions: Some(1000),
    )
  let assert Ok(_) = beach.start(spec, config)
  process.sleep_forever()
}

// see shore for application implementation
```

```sh
ssh localhost -p 2222
```
