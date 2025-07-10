import beach/internal/ssh_server
import gleam/erlang/atom
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process
import gleam/result
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

/// Configuration for a beach ssh server
///
/// ## Example
/// ```gleam
/// beach.config(
///   port: 2222,
///   host_key_directory: ".",
///   auth: beach.auth_anonymous(),
/// )
/// ```
pub fn config(
  port port: Int,
  host_key_directory host_key_directory: String,
  auth auth: Auth,
) -> Config {
  Config(port:, host_key_directory:, auth:)
}

/// Starts an ssh server serving shore application to connecting clients.
///
/// ## Example
/// ```gleam
/// pub fn main() {
///   let exit = process.new_subject()
///   let spec =
///     shore.spec(
///       init:,
///       update:,
///       view:,
///       exit:,
///       keybinds: shore.default_keybinds(),
///       redraw: shore.on_timer(16),
///     )
///   let config =
///     beach.config(
///       port: 2222,
///       host_key_directory: ".",
///       auth: beach.auth_anonymous(),
///     )
///   let assert Ok(_) = beach.start(spec, config)
///   process.sleep_forever()
/// }
/// ```
///
pub fn start(
  spec: shore_internal.Spec(model, msg),
  config: Config,
) -> Result(process.Pid, StartError) {
  serve(spec, config)
}

/// Allow anyone to connect without requiring a password or public key
///
pub fn auth_anonymous() -> Auth {
  Anonymous
}

/// Provide a password challenge for users to complete
///
/// ## Example
///
/// ```
/// fn user_login(username: String, password: String) -> Bool {
///   case username, password {
///     "Joe", "Hello!" -> True
///     _, _ -> False
///   }
/// }
///
/// fn main() {
///   let auth = auth_password(user_login)
///   config(auth:, ..)
/// }
/// ```
///
pub fn auth_password(auth: fn(String, String) -> Bool) -> Auth {
  Password(auth:)
}

/// Provide public key challenge. public key must be present in
/// `authorized_keys` file held in the `user_directory` folder.
///
/// Requires a callback function which containers the username on successful
/// authentication. Can be used for further validation, logging, etc.
///
/// Note: It is safe to have this function always return `True` e.g. `fn(_) { True }`
///
/// ## Example
///
/// ```
/// fn user_login(username: String, public_key: PublicKey) -> Bool {
///    let challenge =
///      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOE7rwqgX3K2Cj8wY/gAOiEQ0T9lEINdNwFq9HEVXB71 username@shore"
///      |> public_key
///    challenge == public_key && username == "Joe"
/// }
///
/// fn main() {
///   let auth = auth_public_key(user_login)
///   config(auth:, ..)
/// }
/// ```
///
pub fn auth_public_key(auth: fn(String, PublicKey) -> Bool) -> Auth {
  Key(auth)
}

/// Provide public key challenge, falling back to password challenge if no
/// matching public key.
///
/// Alternatively, uses can set their preferred auth method via the `-o PreferredAuthentications=password,publickey`.
///
/// See individual examples for `auth_public_key` and `auth_password` for implementation.
///
pub fn auth_public_key_or_password(
  password_auth password_auth: fn(String, String) -> Bool,
  key_auth key_auth: fn(String, PublicKey) -> Bool,
) -> Auth {
  KeyOrPassword(password_auth:, key_auth:)
}

/// Converts an OpenSSH public key string into a PublicKey type for comparison
///
/// ## Example
///
/// ```
/// public_key("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOE7rwqgX3K2Cj8wY/gAOiEQ0T9lEINdNwFq9HEVXB71 username@shore")
/// ```
///
pub fn public_key(public_key: String) -> PublicKey {
  decode_key(public_key)
}

//
// INTERNAL
//

const module = "beach@internal@"

/// ssh server configuration
pub opaque type Config {
  Config(
    /// port to expose the ssh server on
    port: Int,
    /// Path to directory with ssh_host keys
    /// https://www.erlang.org/doc/apps/ssh/ssh_file#SYSDIR
    host_key_directory: String,
    /// TODO
    auth: Auth,
  )
}

/// Authentication method to use for ssh connections
pub opaque type Auth {
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

fn serve(
  spec: shore_internal.Spec(model, msg),
  config: Config,
) -> Result(process.Pid, StartError) {
  let opts = [
    SshCli(#(atom.create(module <> "ssh_cli"), [spec])),
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
pub opaque type PublicKey {
  PublicKey(key: PublicUserKeyFfi)
}

//
// FFI
//

type PeerAddress =
  #(#(Int, Int, Int, Int), Int)

type PublicUserKeyFfi =
  #(#(atom.Atom, BitArray, #(atom.Atom, #(Int, Int, Int, Int))))

type CheckKey =
  List(fn(String, PublicKey) -> Bool)

type DaemonOption(model, msg) {
  SystemDir(Charlist)
  AuthMethods(Charlist)
  Pwdfun(fn(Charlist, Charlist, PeerAddress, AuthState) -> #(Bool, AuthState))
  SshCli(#(atom.Atom, List(shore_internal.Spec(model, msg))))
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

fn decode_key(public_key: String) -> PublicKey {
  // TODO: we probably shouldn't assert here, what does ffi do, just panic also?
  let assert [#(key, _comment)] = public_key |> decode_ffi(OpensshKey)
  PublicKey(key)
}
