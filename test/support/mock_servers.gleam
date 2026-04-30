import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http.{type Method}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{Some}
import mist

// --- Helix HTTP mock ---

/// Handler signature for the Helix mock. Receives the HTTP method and
/// raw request body, returns `(status, body)`.
pub type HelixHandler =
  fn(Method, BitArray) -> #(Int, String)

/// Start a Helix mock on a free port. Returns the bound port and a stop
/// function. The handler is invoked for any request the server receives.
pub fn start_helix(handler: HelixHandler) -> #(Int, fn() -> Nil) {
  let port_subject = process.new_subject()

  let mist_handler = fn(req: Request(mist.Connection)) -> Response(
    mist.ResponseData,
  ) {
    case mist.read_body(req, 1_000_000) {
      Ok(req_with_body) -> {
        let #(status, body) = handler(req_with_body.method, req_with_body.body)
        response.new(status)
        |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
      }
      Error(_) ->
        response.new(500)
        |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
  }

  let assert Ok(started) =
    mist.new(mist_handler)
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(actual_port, _scheme, _ip) {
      process.send(port_subject, actual_port)
    })
    |> mist.start

  let assert Ok(port) = process.receive(port_subject, 5000)
  // Mist's start links the supervisor to the caller; unlink so killing the
  // supervisor in the stop function does not also kill the test process.
  process.unlink(started.pid)
  let stop = fn() {
    process.send_exit(started.pid)
    Nil
  }
  #(port, stop)
}

// --- EventSub WebSocket mock ---

/// Lifecycle events the WS mock reports for each client connection.
pub type WsEvent {
  WsConnected
  WsDisconnected
}

/// Start an EventSub WebSocket mock on a free port. Each new client connection
/// runs the same `initial_frames` script — every frame is sent in order
/// immediately after the upgrade. Connection lifecycle events are reported on
/// `events_subject`. Returns the bound port and a stop function.
pub fn start_eventsub(
  initial_frames: List(String),
  events_subject: Subject(WsEvent),
) -> #(Int, fn() -> Nil) {
  let port_subject = process.new_subject()

  let mist_handler = fn(req: Request(mist.Connection)) -> Response(
    mist.ResponseData,
  ) {
    mist.websocket(
      request: req,
      on_init: fn(_conn) {
        process.send(events_subject, WsConnected)
        // Subjects can only be received from by the process that owns them,
        // so we create a self-subject inside the handler process and pre-load
        // it with the scripted frames. The selector then routes them back
        // through `Custom` to the message handler below.
        let self_subject = process.new_subject()
        list.each(initial_frames, fn(frame) {
          process.send(self_subject, frame)
        })
        let selector =
          process.new_selector()
          |> process.select(self_subject)
        #(Nil, Some(selector))
      },
      on_close: fn(_state) { process.send(events_subject, WsDisconnected) },
      handler: fn(state, msg, conn) {
        case msg {
          mist.Custom(text) -> {
            let _ = mist.send_text_frame(conn, text)
            mist.continue(state)
          }
          mist.Closed | mist.Shutdown -> mist.stop()
          _ -> mist.continue(state)
        }
      },
    )
  }

  let assert Ok(started) =
    mist.new(mist_handler)
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(actual_port, _scheme, _ip) {
      process.send(port_subject, actual_port)
    })
    |> mist.start

  let assert Ok(port) = process.receive(port_subject, 5000)
  // Mist's start links the supervisor to the caller; unlink so killing the
  // supervisor in the stop function does not also kill the test process.
  process.unlink(started.pid)
  let stop = fn() {
    process.send_exit(started.pid)
    Nil
  }
  #(port, stop)
}

// --- JSON payload helpers ---

const fixed_timestamp = "2026-01-01T00:00:00Z"

/// Build a Twitch-style `session_welcome` payload.
pub fn welcome_payload(session_id: String, keepalive_seconds: Int) -> String {
  json.object([
    #(
      "metadata",
      json.object([
        #("message_id", json.string("welcome-1")),
        #("message_type", json.string("session_welcome")),
        #("message_timestamp", json.string(fixed_timestamp)),
      ]),
    ),
    #(
      "payload",
      json.object([
        #(
          "session",
          json.object([
            #("id", json.string(session_id)),
            #("status", json.string("connected")),
            #("connected_at", json.string(fixed_timestamp)),
            #("keepalive_timeout_seconds", json.int(keepalive_seconds)),
            #("reconnect_url", json.null()),
          ]),
        ),
      ]),
    ),
  ])
  |> json.to_string
}

/// Build a Twitch-style `session_keepalive` payload.
pub fn keepalive_payload() -> String {
  json.object([
    #(
      "metadata",
      json.object([
        #("message_id", json.string("ka-1")),
        #("message_type", json.string("session_keepalive")),
        #("message_timestamp", json.string(fixed_timestamp)),
      ]),
    ),
    #("payload", json.object([])),
  ])
  |> json.to_string
}

/// Build a Twitch-style `session_reconnect` payload pointing at `new_url`.
pub fn reconnect_payload(new_url: String) -> String {
  json.object([
    #(
      "metadata",
      json.object([
        #("message_id", json.string("rc-1")),
        #("message_type", json.string("session_reconnect")),
        #("message_timestamp", json.string(fixed_timestamp)),
      ]),
    ),
    #(
      "payload",
      json.object([
        #(
          "session",
          json.object([
            #("id", json.string("session-rc")),
            #("status", json.string("reconnecting")),
            #("connected_at", json.string(fixed_timestamp)),
            #("reconnect_url", json.string(new_url)),
          ]),
        ),
      ]),
    ),
  ])
  |> json.to_string
}

/// Build a Twitch-style `channel.chat.message` notification payload.
pub fn chat_notification_payload(
  broadcaster_user_id broadcaster_user_id: String,
  chatter_user_id chatter_user_id: String,
  text text: String,
) -> String {
  json.object([
    #(
      "metadata",
      json.object([
        #("message_id", json.string("notif-1")),
        #("message_type", json.string("notification")),
        #("message_timestamp", json.string(fixed_timestamp)),
        #("subscription_type", json.string("channel.chat.message")),
        #("subscription_version", json.string("1")),
      ]),
    ),
    #(
      "payload",
      json.object([
        #(
          "event",
          json.object([
            #("broadcaster_user_id", json.string(broadcaster_user_id)),
            #("broadcaster_user_login", json.string("broadcaster")),
            #("chatter_user_id", json.string(chatter_user_id)),
            #("chatter_user_login", json.string("chatter")),
            #(
              "message",
              json.object([
                #("text", json.string(text)),
                #("fragments", json.array([], of: json.string)),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  ])
  |> json.to_string
}
