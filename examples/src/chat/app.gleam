import beach
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import shore
import shore/key
import shore/layout
import shore/style
import shore/ui

// MAIN

pub fn main() {
  let assert Ok(actor.Started(data: server, ..)) = server()

  let spec =
    shore.spec(
      init: fn() { init(server) },
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
      on_connect: fn(conn, shore) { on_connect(conn, shore, server) },
      on_disconnect: fn(conn, shore) { on_disconnect(conn, shore, server) },
    )
  let assert Ok(_) = beach.start(spec, config)
  process.sleep_forever()
}

fn on_connect(
  connection: beach.ConnectionInfo,
  shore: Subject(shore.Event(Msg)),
  server: Subject(ServerMsg),
) -> Nil {
  let username = beach.connection_username(connection)
  process.send(server, NewSubscriber(shore, username))
  process.send(shore, shore.send(SetUsername(username)))
}

fn on_disconnect(
  _connection: beach.ConnectionInfo,
  shore: Subject(shore.Event(Msg)),
  server: Subject(ServerMsg),
) -> Nil {
  process.send(server, RemoveSubscriber(shore))
}

// MODEL

type Model {
  Model(
    error: Option(ServerError),
    page: Page,
    username: String,
    input: String,
    chat: List(Chat),
    users: List(User),
    server: process.Subject(ServerMsg),
  )
}

type Page {
  Loading
  Fault
  Chatroom
}

type Chat {
  Chat(username: String, content: String)
}

type User {
  User(username: String)
}

fn init(server: Subject(ServerMsg)) -> #(Model, List(fn() -> Msg)) {
  let model =
    Model(
      error: None,
      page: Loading,
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
  Connecting(Result(String, ServerError))
  SetUsername(String)
  SetInput(String)
  SendInput
  Sync(List(Chat), List(User))
}

fn update(model: Model, msg: Msg) -> #(Model, List(fn() -> Msg)) {
  case msg {
    Connecting(Ok(username)) -> #(Model(..model, username:, page: Chatroom), [])
    Connecting(Error(error)) -> #(
      Model(..model, error: Some(error), page: Fault),
      [],
    )
    SetUsername(username) -> #(Model(..model, username: username), [])
    SetInput(input) -> #(Model(..model, input:), [])
    SendInput ->
      case
        process.call(model.server, 10, NewChat(_, model.username, model.input))
      {
        Ok(Nil) -> #(Model(..model, input: ""), [])
        Error(error) -> #(Model(..model, error: Some(error)), [])
      }
    Sync(chat, users) -> #(Model(..model, chat:, users:), [])
  }
}

// VIEW

fn view(model: Model) -> shore.Node(Msg) {
  case model.page {
    Loading -> layout.center(ui.text("loading"), style.Px(10), style.Px(1))
    Fault -> view_fault(model)
    Chatroom ->
      layout.grid(
        gap: 0,
        rows: [style.Fill, style.Px(3)],
        cols: [style.Pct(80), style.Pct(20)],
        cells: [view_input(model), view_chat(model), view_users(model)],
      )
  }
}

fn view_fault(model: Model) -> shore.Node(Msg) {
  let msg = case model.error {
    Some(UsernameExists) -> "username is already taken"
    Some(UsernameTooShort) ->
      "username is too short, must be at least 3 characters long"
    None -> "unexpect error occured"
  }
  let content =
    [ui.text(msg)]
    |> ui.box(Some("error"))
  let len = string.length(msg) + 7
  layout.center(content, style.Px(len), style.Px(3))
}

fn view_input(model: Model) -> layout.Cell(Msg) {
  ui.box(
    [ui.input_submit(">", model.input, style.Fill, SetInput, SendInput, False)],
    Some("message"),
  )
  |> layout.cell(row: #(1, 1), col: #(0, 0), content: _)
}

fn view_chat(model: Model) -> layout.Cell(Msg) {
  model.chat
  |> list.reverse
  |> list.map(fn(chat) { chat.username <> ": " <> chat.content })
  |> string.join("\n")
  |> fn(chat) { [ui.text(chat)] }
  |> ui.box(Some("chat"))
  |> layout.cell(row: #(0, 0), col: #(0, 0), content: _)
}

fn view_users(model: Model) -> layout.Cell(Msg) {
  model.users
  |> list.map(fn(user) {
    let User(user) = user
    user
  })
  |> string.join("\n")
  |> fn(users) { [ui.text(users)] }
  |> ui.box(Some("users"))
  |> layout.cell(row: #(0, 1), col: #(1, 1), content: _)
}

// SERVER

type State {
  State(chat: List(Chat), subscribers: Dict(Subject(shore.Event(Msg)), User))
}

type ServerMsg {
  NewSubscriber(shore: Subject(shore.Event(Msg)), username: String)
  RemoveSubscriber(shore: Subject(shore.Event(Msg)))
  NewChat(
    subject: process.Subject(Result(Nil, ServerError)),
    username: String,
    content: String,
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
  let state = State(chat: [], subscribers: dict.new())
  actor.initialised(state)
  |> actor.returning(subject)
  |> Ok
}

fn server_tick(subject: Subject(ServerMsg)) -> Nil {
  process.send(subject, ServerTick)
  process.sleep(250)
  server_tick(subject)
}

fn server_loop(state: State, msg: ServerMsg) -> actor.Next(State, a) {
  case msg {
    NewSubscriber(shore:, username:) ->
      case validate_username(state, username) {
        Ok(Nil) -> {
          let state =
            State(
              ..state,
              subscribers: dict.insert(state.subscribers, shore, User(username)),
            )
          process.send(shore, shore.send(Connecting(Ok(username))))
          actor.continue(state)
        }
        Error(error) -> {
          process.send(shore, shore.send(Connecting(Error(error))))
          actor.continue(state)
        }
      }
    RemoveSubscriber(shore:) ->
      State(..state, subscribers: dict.delete(state.subscribers, shore))
      |> actor.continue

    NewChat(subject:, username:, content:) -> {
      process.send(subject, Ok(Nil))
      State(..state, chat: [Chat(username:, content:), ..state.chat])
      |> actor.continue
    }

    ServerTick -> {
      let users =
        dict.values(state.subscribers)
        |> list.sort(fn(a, b) { string.compare(a.username, b.username) })
      let _ =
        state.subscribers
        |> dict.keys
        |> list.each(process.send(_, shore.send(Sync(state.chat, users))))
      actor.continue(state)
    }
  }
}

fn validate_username(state: State, username: String) -> Result(Nil, ServerError) {
  use _ok <- result.try(fn() {
    let is_match =
      state.subscribers
      |> dict.filter(fn(_, v) { v.username == username })
      |> dict.is_empty
      |> bool.negate
    case is_match {
      True -> Error(UsernameExists)
      False -> Ok(Nil)
    }
  }())
  use _ok <- result.try(fn() {
    let is_short = string.length(username) <= 3
    case is_short {
      True -> Error(UsernameTooShort)
      False -> Ok(Nil)
    }
  }())
  Ok(Nil)
}
