import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{Some}
import gleam/otp/actor
import gleam/string
import shore
import shore/internal as shore_internal
import shore/key

pub type TODO

//
// API NOW
//

pub type HandleMsgFfi

// https://www.erlang.org/doc/apps/ssh/ssh_client_channel.html#c:handle_msg/2
pub opaque type HandleMsg {
  SshChannelUp(channel_id: Int, pid: Pid)
  SshExit(pid: Pid, reason: Reason)
}

// https://www.erlang.org/doc/apps/ssh/ssh_client_channel.html#c:handle_ssh_msg/2
pub opaque type HandleSshMsg {
  SshCm(pid: Pid, msg: ChannelMsg)
}

type ChannelMsg {
  Data(channel_id: Int, ssh_data_type_code: Int, data: String)
  Shell(a: Int, bool: Bool)
  Pty(
    channel_id: Int,
    want_reply: Bool,
    // TODO: map this to Terminal type
    terminal: #(Charlist, Int, Int, Int, Int, List(TODO)),
  )
  WindowChange(
    channel_id: Int,
    char_width: Int,
    row_height: Int,
    pixel_width: Int,
    pixel_height: Int,
  )
  // TODO:
  // eof
  // closed
  // env
  // shell
  // exec
  // signal
  // exit_status
  // exit_signal
}

pub opaque type Reason {
  Normal
  Shutdown
}

//
// START POINT
//

pub type Init(model, msg) {
  Init(spec: shore_internal.Spec(model, msg))
}

pub type State(msg) {
  State(ssh_pid: Pid, channel_id: Int, shore: Subject(shore.Event(msg)))
}

// TODO: error handling
pub fn init(
  args: List(shore_internal.Spec(model, msg)),
) -> Continue(Init(model, msg)) {
  // NOTE: Second arg here is the atom `disabled` passed by setting `Exec(Disabled)`
  let assert [spec, _] = args
    as "PANIC: This crash is framework bug caused by bad use of ffi and should never ever happen"
  Init(spec:) |> Ok |> to_continue
}

type RendererState {
  RendererState(ssh_pid: Pid, channel_id: Int)
}

pub fn handle_msg(
  msg: HandleMsgFfi,
  state: Init(model, msg),
) -> Continue(State(msg)) {
  let msg = msg |> to_handle_msg
  case msg {
    SshChannelUp(channel_id, pid) -> {
      let assert Ok(actor.Started(data: renderer, ..)) =
        actor.new(RendererState(pid, channel_id))
        |> actor.on_message(render_loop)
        |> actor.start
      let assert Ok(shore) =
        state.spec |> shore_internal.start_custom_renderer(Some(renderer))
      State(ssh_pid: pid, channel_id: channel_id, shore:)
      |> Ok
      |> to_continue
    }
    SshExit(reason:, ..) -> {
      Error(#(0, reason)) |> to_continue
    }
  }
}

@external(erlang, "beach_ffi", "to_handle_msg")
fn to_handle_msg(msg: HandleMsgFfi) -> HandleMsg

fn render_loop(
  state: RendererState,
  msg: String,
) -> actor.Next(RendererState, String) {
  case send(state.ssh_pid, state.channel_id, msg) {
    Ok(_) -> actor.continue(state)
    // TODO: should we do better error handling here?
    // error can be Closed or Timeout
    Error(..) -> actor.stop()
  }
}

pub fn handle_ssh_msg(
  msg: HandleSshMsg,
  state: State(msg),
) -> Continue(State(msg)) {
  case msg {
    SshCm(_, Pty(terminal: #(_, width, height, _, _, _), ..)) -> {
      shore_internal.resize(width:, height:)
      |> actor.send(state.shore, _)
      state |> Ok |> to_continue
    }
    SshCm(_, Shell(..)) -> {
      state |> Ok |> to_continue
    }
    // TODO: should we handle ctrl+c, no?
    SshCm(_, Data(data:, ..)) -> {
      data
      |> key.from_string
      |> shore_internal.key_press
      |> actor.send(state.shore, _)
      state |> Ok |> to_continue
    }
    SshCm(_, WindowChange(char_width:, row_height:, ..)) -> {
      shore_internal.resize(width: char_width, height: row_height)
      |> actor.send(state.shore, _)
      state |> Ok |> to_continue
    }
    x -> {
      echo "unhandled " <> string.inspect(x)
      state |> Ok |> to_continue
    }
  }
}

// NOTE: return value is ignored
pub fn terminate(_reason: Reason, state: State(msg)) -> Nil {
  let assert Ok(Nil) =
    shore_internal.restore_terminal()
    |> send(state.ssh_pid, state.channel_id, _)
  Nil
}

@external(erlang, "beach_ffi", "ssh_connection_send")
fn send(ref: Pid, id: Int, data: String) -> Result(Nil, Reason)

//
// HEPLERS
//

pub type Continue(state)

@external(erlang, "beach_ffi", "to_continue")
fn to_continue(result: Result(state, #(Int, Reason))) -> Continue(state)
