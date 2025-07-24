import beach/internal/ssh_server
import gleam/erlang/process.{type Subject}
import gleam/result
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

/// TODO
pub type ConnectionInfo =
  ssh_server.ConnectionInfo

fn error_to_public(error: ssh_server.StartError) -> StartError {
  case error {
    ssh_server.AddressInUse -> AddressInUse
    ssh_server.SshApplicationNotStarted -> SshApplicationNotStarted
    ssh_server.HostKeyNotFound -> HostKeyNotFound
    ssh_server.SshDaemonFault(e) -> SshDaemonFault(e)
  }
}

/// TODO
pub fn connection_username(info: ssh_server.ConnectionInfo) -> String {
  info.username
}

/// TODO
pub fn connection_ip_address(info: ssh_server.ConnectionInfo) -> String {
  info.ip
}

/// TODO
pub fn connection_port(info: ssh_server.ConnectionInfo) -> Int {
  info.port
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
  auth auth: ssh_server.Auth,
  on_connect on_connect: fn(
    ssh_server.ConnectionInfo,
    Subject(shore.Event(msg)),
  ) ->
    Nil,
  on_disconnect on_disconnect: fn(
    ssh_server.ConnectionInfo,
    Subject(shore.Event(msg)),
  ) ->
    Nil,
) -> ssh_server.Config(msg) {
  ssh_server.Config(
    port:,
    host_key_directory:,
    auth:,
    on_connect:,
    on_disconnect:,
  )
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
  config: ssh_server.Config(msg),
) -> Result(process.Pid, StartError) {
  ssh_server.serve(spec, config) |> result.map_error(error_to_public)
}

/// Allow anyone to connect without requiring a password or public key
///
pub fn auth_anonymous() -> ssh_server.Auth {
  ssh_server.Anonymous
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
pub fn auth_password(auth: fn(String, String) -> Bool) -> ssh_server.Auth {
  ssh_server.Password(auth:)
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
pub fn auth_public_key(
  auth: fn(String, ssh_server.PublicKey) -> Bool,
) -> ssh_server.Auth {
  ssh_server.Key(auth)
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
  key_auth key_auth: fn(String, ssh_server.PublicKey) -> Bool,
) -> ssh_server.Auth {
  ssh_server.KeyOrPassword(password_auth:, key_auth:)
}

/// Converts an OpenSSH public key string into a PublicKey type for comparison
///
/// ## Example
///
/// ```
/// public_key("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOE7rwqgX3K2Cj8wY/gAOiEQ0T9lEINdNwFq9HEVXB71 username@shore")
/// ```
///
pub fn public_key(public_key: String) -> ssh_server.PublicKey {
  ssh_server.decode_key(public_key)
}
