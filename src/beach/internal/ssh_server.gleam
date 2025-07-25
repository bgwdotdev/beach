import gleam/erlang/atom
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process.{type Subject}
import shore
import shore/internal as shore_internal

pub type StartError {
  /// Port in use by another application
  AddressInUse
  /// Erlang ssh application is not running
  SshApplicationNotStarted
  /// ssh host key files not found
  HostKeyNotFound
  /// unexpected other term() provided by ssh:daemon (which should be converted to strict value, open issue/pr if found)
  SshDaemonFault(String)
}

//
// INTERNAL
//

const module = "beach@internal@"

/// ssh server configuration
pub type Config(msg) {
  Config(
    /// port to expose the ssh server on
    port: Int,
    /// Path to directory with ssh_host keys
    /// https://www.erlang.org/doc/apps/ssh/ssh_file#SYSDIR
    host_key_directory: String,
    /// authentication method
    auth: Auth,
    /// TODO:
    on_connect: fn(Connection, Subject(shore.Event(msg))) -> Nil,
    /// TODO:
    on_disconnect: fn(Connection, Subject(shore.Event(msg))) -> Nil,
  )
}

pub type SshCliOptions(model, msg) {
  SshCliOptions(spec: shore_internal.Spec(model, msg), config: Config(msg))
}

pub type Connection {
  Connection(username: String, ip: String, port: Int)
}

/// Authentication method to use for ssh connections
pub type Auth {
  Anonymous
  Password(auth: fn(String, String) -> Bool)
  Key(auth: fn(String, PublicKey) -> Bool)
  KeyOrPassword(
    password_auth: fn(String, String) -> Bool,
    key_auth: fn(String, PublicKey) -> Bool,
  )
}

fn config_auth(config: Auth) -> List(DaemonOption(model, msg)) {
  case config {
    Anonymous -> [NoAuthNeeded(True)]

    Password(app_auth) -> [
      NoAuthNeeded(False),
      AuthMethods("keyboard-interactive,password" |> charlist.from_string),
      Pwdfun(fn(user, secret, _peer_address, state) {
        let #(user, secret) = to_auth(user, secret)
        let ok = app_auth(user, secret)
        throttle(ok, state)
      }),
    ]

    Key(app_auth) -> [
      NoAuthNeeded(False),
      AuthMethods("publickey" |> charlist.from_string),
      KeyCb(#(atom.create(module <> "ssh_server_key_api"), [app_auth])),
    ]

    KeyOrPassword(password_auth:, key_auth:) -> [
      NoAuthNeeded(False),
      AuthMethods(
        "publickey,keyboard-interactive,password" |> charlist.from_string,
      ),
      Pwdfun(fn(user, secret, _peer_address, state) {
        let #(user, secret) = to_auth(user, secret)
        let ok = password_auth(user, secret)
        throttle(ok, state)
      }),
      KeyCb(#(atom.create(module <> "ssh_server_key_api"), [key_auth])),
    ]
  }
}

type AuthState {
  Undefined
  AuthState(throttle: Int)
}

/// adds expanding delay after failed login attempts
fn throttle(ok: Bool, state: AuthState) -> #(Bool, AuthState) {
  case ok, state {
    True, _ -> #(True, Undefined)
    False, Undefined -> {
      process.sleep(1000)
      #(False, AuthState(throttle: 2000))
    }
    False, AuthState(throttle:) -> {
      process.sleep(throttle)
      #(False, AuthState(throttle: throttle * 2))
    }
  }
}

pub fn serve(
  spec: shore_internal.Spec(model, msg),
  config: Config(msg),
) -> Result(process.Pid, StartError) {
  let opts = [
    SshCli(#(atom.create(module <> "ssh_cli"), [SshCliOptions(spec:, config:)])),
    SystemDir(config.host_key_directory |> charlist.from_string),
    Shell(Disabled),
    Exec(Disabled),
    ParallelLogin(True),
    ..config_auth(config.auth)
  ]
  daemon(config.port, opts)
}

fn to_auth(user: Charlist, secret: Charlist) -> #(String, String) {
  let user = user |> charlist.to_string
  let secret = secret |> charlist.to_string
  #(user, secret)
}

/// An OpenSSH public key
pub type PublicKey {
  PublicKey(key: PublicUserKeyFfi)
}

//
// FFI
//

pub type ConnectionInfoFfi

type PeerAddress =
  #(#(Int, Int, Int, Int), Int)

pub type PublicUserKeyFfi =
  #(#(atom.Atom, BitArray, #(atom.Atom, #(Int, Int, Int, Int))))

pub type CheckKey =
  List(fn(String, PublicKey) -> Bool)

type DaemonOption(model, msg) {
  SystemDir(Charlist)
  AuthMethods(Charlist)
  Pwdfun(fn(Charlist, Charlist, PeerAddress, AuthState) -> #(Bool, AuthState))
  SshCli(#(atom.Atom, List(SshCliOptions(model, msg))))
  NoAuthNeeded(Bool)
  Exec(Disabled)
  Shell(Disabled)
  ParallelLogin(Bool)
  KeyCb(#(atom.Atom, CheckKey))
}

@external(erlang, "beach_ffi", "daemon")
fn daemon(
  port: Int,
  opts: List(DaemonOption(model, msg)),
) -> Result(process.Pid, StartError)

type Disabled {
  Disabled
}

type SshKeyType {
  OpensshKey
}

type PublicUserKeyDecode =
  List(#(PublicUserKeyFfi, List(Comment)))

type Comment {
  Comment(BitArray)
}

@external(erlang, "ssh_file", "decode")
fn decode_ffi(key: String, type_: SshKeyType) -> PublicUserKeyDecode

pub fn decode_key(public_key: String) -> PublicKey {
  // TODO: we probably shouldn't assert here, what does ffi do, just panic also?
  let assert [#(key, _comment)] = public_key |> decode_ffi(OpensshKey)
  PublicKey(key)
}

@external(erlang, "beach_ffi", "to_connection_info")
pub fn to_connection(connection: ConnectionInfoFfi) -> Connection
