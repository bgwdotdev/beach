import beach
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import shore
import shore/key
import shore/layout
import shore/style
import shore/ui

// MAIN

pub fn main() {
  let assert Ok(actor.Started(data: server, ..)) = server()

  let spec =
    shore.spec_with_subject(
      init: fn(subj) { init(subj, server) },
      update:,
      view:,
      exit: process.new_subject(),
      keybinds: shore.default_keybinds(),
      redraw: shore.on_timer(16),
    )
  let config =
    beach.config(
      port: 2222,
      host_key_directory: ".",
      auth: beach.auth_anonymous(),
    )
  let assert Ok(_) = beach.start(spec, config)
  process.sleep_forever()
}

// MODEL

type Model {
  Model(
    error: Option(ServerError),
    shore: Subject(Msg),
    page: Page,
    username: String,
    input: String,
    chat: List(Chat),
    users: List(User),
    server: process.Subject(ServerMsg),
  )
}

type Page {
  Username
  Chatroom
}

type Chat {
  Chat(username: String, content: String)
}

type User {
  User(username: String)
}

fn init(
  subj: Subject(Msg),
  server: Subject(ServerMsg),
) -> #(Model, List(fn() -> Msg)) {
  let model =
    Model(
      error: None,
      shore: subj,
      page: Username,
      username: "",
      input: "",
      chat: [],
      users: [],
      server:,
    )
  let cmds = []
  #(model, cmds)
}

// UPDATE

type Msg {
  SetUsername(String)
  SendUsername
  SetInput(String)
  SendInput
  Tick
}

fn update(model: Model, msg: Msg) -> #(Model, List(fn() -> Msg)) {
  case msg {
    SetUsername(username) -> #(Model(..model, username:), [])
    SendUsername -> {
      let attempt =
        process.call(model.server, 1000, NewUser(
          subject: _,
          username: model.username,
        ))
      case attempt {
        Ok(Nil) -> {
          process.spawn(fn() { tick(model) })
          #(Model(..model, page: Chatroom), [])
        }
        Error(error) -> #(Model(..model, error: Some(error)), [])
      }
    }
    SetInput(input) -> #(Model(..model, input:), [])
    SendInput ->
      case
        process.call(model.server, 10, NewChat(_, model.username, model.input))
      {
        Ok(Nil) -> #(Model(..model, input: ""), [])
        Error(error) -> #(Model(..model, error: Some(error)), [])
      }
    Tick ->
      case process.call(model.server, 10, GetChat(_, model.username)) {
        Ok(#(chat, users)) -> #(
          Model(..model, chat:, users: list.map(users, User)),
          [],
        )
        Error(error) -> #(Model(..model, error: Some(error)), [])
      }
  }
}

fn tick(model: Model) {
  process.send(model.shore, Tick)
  process.sleep(1000)
  tick(model)
}

// VIEW

fn view(model: Model) -> shore.Node(Msg) {
  case model.page {
    Username -> layout.center(view_username(model), style.Px(50), style.Px(5))
    Chatroom ->
      layout.grid(
        gap: 0,
        rows: [style.Fill, style.Px(3)],
        cols: [style.Pct(80), style.Pct(20)],
        cells: [view_input(model), view_chat(model), view_users(model)],
      )
  }
}

fn view_username(model: Model) -> shore.Node(Msg) {
  [
    ui.input("username", model.username, style.Fill, SetUsername),
    ui.keybind(key.Enter, SendUsername),
    case model.error {
      None -> ui.br()
      Some(error) -> ui.text(string.inspect(error))
    },
  ]
  |> ui.box(Some("login"))
}

fn view_input(model: Model) -> layout.Cell(Msg) {
  ui.box(
    [
      ui.input(">", model.input, style.Fill, SetInput),
      ui.keybind(key.Enter, SendInput),
    ],
    Some("message"),
  )
  |> layout.cell(row: #(1, 1), col: #(0, 0), content: _)
}

fn view_chat(model: Model) -> layout.Cell(Msg) {
  model.chat
  |> list.reverse
  |> list.map(fn(chat) { ui.text(chat.username <> ": " <> chat.content) })
  //|> ui.col
  //|> fn(i) { [i] }
  |> ui.box(Some("chat"))
  |> layout.cell(row: #(0, 0), col: #(0, 0), content: _)
}

fn view_users(model: Model) -> layout.Cell(Msg) {
  list.map(model.users, fn(user) { ui.text(user.username) })
  |> ui.box(Some("users"))
  |> layout.cell(row: #(0, 1), col: #(1, 1), content: _)
}

// SERVER

type State {
  State(chat: List(Chat), users: Dict(String, Timestamp))
}

type ServerMsg {
  NewUser(subject: process.Subject(Result(Nil, ServerError)), username: String)
  NewChat(
    subject: process.Subject(Result(Nil, ServerError)),
    username: String,
    content: String,
  )
  GetChat(
    subject: process.Subject(Result(#(List(Chat), List(String)), ServerError)),
    username: String,
  )
  ServerTick
}

type ServerError {
  UsernameExists
  UsernameTooShort
}

fn server() -> Result(
  actor.Started(process.Subject(ServerMsg)),
  actor.StartError,
) {
  actor.new_with_initialiser(1000, server_init)
  |> actor.on_message(server_loop)
  |> actor.start()
}

fn server_init(
  subject: Subject(ServerMsg),
) -> Result(actor.Initialised(State, ServerMsg, Subject(ServerMsg)), String) {
  let _pid = process.spawn(fn() { server_tick(subject) })
  let state = State(chat: [], users: dict.new())
  actor.initialised(state)
  |> actor.returning(subject)
  |> Ok
}

fn server_tick(subject: Subject(ServerMsg)) -> Nil {
  process.send(subject, ServerTick)
  process.sleep(5000)
  server_tick(subject)
}

fn server_loop(state: State, msg: ServerMsg) -> actor.Next(State, a) {
  case msg {
    NewUser(subject:, username:) ->
      case dict.has_key(state.users, username), string.length(username) <= 3 {
        True, _ -> {
          process.send(subject, Error(UsernameExists))
          actor.continue(state)
        }
        _, True -> {
          process.send(subject, Error(UsernameTooShort))
          actor.continue(state)
        }
        _, _ -> {
          process.send(subject, Ok(Nil))
          State(
            ..state,
            users: dict.insert(state.users, username, timestamp.system_time()),
          )
          |> actor.continue
        }
      }

    NewChat(subject:, username:, content:) -> {
      process.send(subject, Ok(Nil))
      State(..state, chat: [Chat(username:, content:), ..state.chat])
      |> actor.continue
    }

    GetChat(subject:, username:) -> {
      process.send(subject, Ok(#(state.chat, dict.keys(state.users))))
      actor.continue(
        State(
          ..state,
          users: dict.insert(state.users, username, timestamp.system_time()),
        ),
      )
    }

    ServerTick -> {
      let now = timestamp.system_time()
      let users =
        dict.filter(state.users, fn(_, v) {
          let diff =
            timestamp.difference(v, now)
            |> duration.compare(duration.seconds(5))
          case diff {
            order.Gt -> False
            _ -> True
          }
        })
      State(..state, users:) |> actor.continue
    }
  }
}
