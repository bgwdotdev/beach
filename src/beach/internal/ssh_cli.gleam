import beach/internal/ssh_server
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import shore
import shore/internal as shore_internal
import shore/key

//
// -behaviour(ssh_server_channel)
//

const timeout = 250

//
// API
//

pub type HandleMsgFfi

pub type ChannelId

pub type TerminalMode

// https://www.erlang.org/doc/apps/ssh/ssh_server_channel.html#c:handle_msg/2
pub opaque type HandleMsg {
  SshChannelUp(channel_id: ChannelId, pid: Pid)
  SshExit(pid: Pid, reason: Reason)
}

// https://www.erlang.org/doc/apps/ssh/ssh_server_channel.html#c:handle_ssh_msg/2
pub opaque type HandleSshMsg {
  SshCm(pid: Pid, msg: ChannelMsg)
}

type ChannelMsg {
  Data(channel_id: ChannelId, ssh_data_type_code: Int, data: String)
  Pty(
    channel_id: ChannelId,
    want_reply: Bool,
    terminal: #(Charlist, Int, Int, Int, Int, List(TerminalMode)),
  )
  WindowChange(
    channel_id: ChannelId,
    char_width: Int,
    row_height: Int,
    pixel_width: Int,
    pixel_height: Int,
  )
  Eof(channel_id: ChannelId)
  Closed(channel_id: ChannelId)
  Env(channel_id: ChannelId, want_reply: Bool, var: String, value: String)
  Shell(channel_id: ChannelId, want_reply: Bool)
  Exec(channel_id: ChannelId, want_reply: Bool, command: String)
  Signal(channel_id: ChannelId, signal_name: String)
  ExitStatus(channel_id: ChannelId, exit_status: Int)
  ExitSignal(
    channel_id: ChannelId,
    exit_signal: String,
    error_msg: String,
    language_string: String,
  )
}

pub opaque type Reason {
  Normal
  Shutdown(error: SshCliError)
}

type Stop(model, msg) {
  StopReason(reason: Reason)
  StopState(state: State(model, msg))
}

pub type SshCliError {
  UnexpectedArgsOnInit(args: String)
  ShoreRendererFailure(actor.StartError)
  ShoreInitFailure(actor.StartError)
  ExitMessage(reason: String)
}

type SendError {
  ChannelClosed
  SendTimeout
}

//
// INIT
//

pub type State(model, msg) {
  Init(spec: shore_internal.Spec(model, msg), config: ssh_server.Config(msg))
  State(
    ssh_pid: Pid,
    channel_id: ChannelId,
    connection: ssh_server.Connection,
    shore: Subject(shore.Event(msg)),
    on_disconnect: fn(ssh_server.Connection, Subject(shore.Event(msg))) -> Nil,
    result: Result(Nil, SshCliError),
  )
}

pub fn init(
  args: List(ssh_server.SshCliOptions(model, msg)),
) -> Continue(State(model, msg)) {
  case args {
    // NOTE: Second arg here is the atom `disabled` passed by setting `Exec(Disabled)`
    [opts, _] -> Init(spec: opts.spec, config: opts.config) |> Ok
    args ->
      Error(StopReason(Shutdown(UnexpectedArgsOnInit(string.inspect(args)))))
  }
  |> to_continue
}

//
// ACTOR LOOP
//

pub fn handle_msg(
  msg: HandleMsgFfi,
  state: State(model, msg),
) -> Continue(State(model, msg)) {
  let msg = msg |> to_handle_msg
  case msg, state {
    SshChannelUp(channel_id, pid), Init(..) as state -> {
      let connection = ssh_server.to_connection(connection_info(pid))
      {
        use actor.Started(data: renderer, ..) <- result.try(
          actor.new(RendererState(pid, channel_id))
          |> actor.on_message(render_loop)
          |> actor.start
          |> result.map_error(ShoreRendererFailure),
        )
        use shore <- result.try(
          state.spec
          |> shore_internal.start_custom_renderer(Some(renderer))
          |> result.map_error(ShoreInitFailure),
        )
        state.config.on_connect(connection, shore)
        Ok(State(
          ssh_pid: pid,
          channel_id: channel_id,
          connection:,
          shore:,
          on_disconnect: state.config.on_disconnect,
          result: Ok(Nil),
        ))
      }
      |> result.map_error(fn(error) {
        StopState(State(
          ssh_pid: pid,
          channel_id: channel_id,
          connection: connection,
          shore: process.new_subject(),
          on_disconnect: state.config.on_disconnect,
          result: Error(error),
        ))
      })
    }
    SshExit(reason:, ..), State(..) as state -> {
      Error(StopState(
        State(..state, result: Error(ExitMessage(string.inspect(reason)))),
      ))
    }
    msg, Init(..) -> {
      panic as { "state misconfigured on message: " <> string.inspect(msg) }
    }
    SshChannelUp(..), State(..) -> {
      panic as { "state already configured on channel up" }
    }
  }
  |> to_continue
}

//
// RENDER LOOP
//

type RendererState {
  RendererState(ssh_pid: Pid, channel_id: ChannelId)
}

fn render_loop(
  state: RendererState,
  msg: String,
) -> actor.Next(RendererState, String) {
  case send(state.ssh_pid, state.channel_id, msg, timeout) {
    Ok(_) -> actor.continue(state)
    Error(SendTimeout) -> actor.continue(state)
    Error(ChannelClosed) -> actor.stop()
  }
}

//
// SSH LOOP
//

pub fn handle_ssh_msg(
  msg: HandleSshMsg,
  state: State(model, msg),
) -> Continue(State(model, msg)) {
  case state {
    State(..) as state -> {
      case msg {
        SshCm(_, Pty(terminal: #(_, width, height, _, _, _), ..)) -> {
          shore_internal.resize(width:, height:)
          |> actor.send(state.shore, _)
          state |> Ok |> to_continue
        }
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
        // ignore or exit on any other event
        SshCm(_, Eof(..)) -> state |> Ok |> to_continue
        SshCm(_, Closed(..)) ->
          Error(StopState(State(..state, result: Ok(Nil))))
          |> to_continue

        SshCm(_, Env(..)) -> state |> Ok |> to_continue
        SshCm(_, Shell(..)) -> state |> Ok |> to_continue
        SshCm(_, Exec(..)) -> state |> Ok |> to_continue
        SshCm(_, Signal(..)) -> state |> Ok |> to_continue
        SshCm(_, ExitStatus(..)) -> state |> Ok |> to_continue
        SshCm(_, ExitSignal(..)) ->
          Error(StopState(State(..state, result: Ok(Nil))))
          |> to_continue
      }
    }
    Init(..) -> {
      panic as { "state misconfigured on ssh message: " <> string.inspect(msg) }
    }
  }
}

//
// EXIT
//

pub fn terminate(_reason: Reason, state: State(model, msg)) -> Nil {
  case state {
    Init(..) -> Nil
    State(..) as state -> state.on_disconnect(state.connection, state.shore)
  }
}

//
// SEND
//

@external(erlang, "beach_ffi", "ssh_connection_send")
fn send(
  ref: Pid,
  channel_id: ChannelId,
  data: String,
  timeout: Int,
) -> Result(Nil, SendError)

//
// HEPLERS
//

pub type Continue(state)

@external(erlang, "beach_ffi", "to_continue")
fn to_continue(result: Result(state, Stop(model, msg))) -> Continue(state)

@external(erlang, "beach_ffi", "to_handle_msg")
fn to_handle_msg(msg: HandleMsgFfi) -> HandleMsg

@external(erlang, "ssh", "connection_info")
fn connection_info(pid: Pid) -> ssh_server.ConnectionInfoFfi
