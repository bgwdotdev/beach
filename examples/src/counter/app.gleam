import beach
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import shore
import shore/key
import shore/layout
import shore/style
import shore/ui

// MAIN

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
      on_connect: fn(_conn, _shore) { Nil },
      on_disconnect: fn(_conn, _shore) { Nil },
      max_sessions: None,
    )
  let assert Ok(_) = beach.start(spec, config)
  process.sleep_forever()
}

// MODEL

pub opaque type Model {
  Model(counter: Int)
}

fn init() -> #(Model, List(fn() -> Msg)) {
  let model = Model(counter: 0)
  let cmds = []
  #(model, cmds)
}

// UPDATE

pub opaque type Msg {
  Increment
  Decrement
}

fn update(model: Model, msg: Msg) -> #(Model, List(fn() -> Msg)) {
  case msg {
    Increment -> #(Model(counter: model.counter + 1), [])
    Decrement -> #(Model(counter: model.counter - 1), [])
  }
}

// VIEW

fn view(model: Model) -> shore.Node(Msg) {
  [
    ui.col([
      ui.text(
        "keybinds

i: increments
d: decrements
ctrl+x: exits
      ",
      ),
      ui.text(int.to_string(model.counter)),
      ui.br(),
      ui.row([
        ui.button("increment", key.Char("i"), Increment),
        ui.button("decrement", key.Char("d"), Decrement),
      ]),
    ]),
  ]
  |> ui.box(Some("Counter"))
  |> layout.center(style.Px(50), style.Px(11))
}
