import gleam/erlang/process.{type Subject, type Timer}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import logging
import stratus
import types.{
  type Config, type Error, type Event, type Subscription, SessionClosed,
  WebSocketError,
}
import internal/messages.{
  type WsToManagerMsg, WsClosed, WsConnected, WsEvent, WsKeepalive, WsReconnect,
}
import internal/websocket
import internal/subscription

// --- Public types ---

/// Opaque connection handle.
pub opaque type Connection {
  Connection(subject: Subject(Msg))
}

// --- Internal types ---

pub type UserMsg {
  Subscribe(Subscription, Subject(Result(Nil, Error)))
  Stop
}

pub type Msg {
  User(UserMsg)
  FromWs(WsToManagerMsg)
  WsStarted(Result(Subject(stratus.InternalMessage(websocket.UserMsg)), Error))
  ReconnectTimer
  KeepaliveExpired
}

pub type State {
  State(
    config: Config,
    handler: fn(Event) -> Nil,
    self: Subject(Msg),
    ws_subject: Option(Subject(stratus.InternalMessage(websocket.UserMsg))),
    session_id: Option(String),
    subscriptions: List(Subscription),
    reconnect_url: Option(String),
    keepalive_timer: Option(Timer),
    reconnect_timer: Option(Timer),
    reconnect_attempts: Int,
    max_reconnect_attempts: Int,
    is_connected: Bool,
    ready_subject: Option(Subject(Nil)),
  )
}

const max_reconnect_backoff_ms = 60_000
const initial_reconnect_backoff_ms = 1_000
const default_keepalive_seconds = 10
const keepalive_grace_ms = 2_000

// --- Public API ---

/// Start the manager and initial WebSocket connection.
///
/// Waits up to 5 seconds for `session_welcome` from Twitch before returning.
pub fn start(
  config: Config,
  handler: fn(Event) -> Nil,
) -> Result(Connection, Error) {
  let ready_subject = process.new_subject()

  let builder =
    actor.new_with_initialiser(10_000, fn(subject) {
      let ws_subject = process.new_subject()

      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.merge_selector(
          process.new_selector()
          |> process.select_map(ws_subject, fn(ws_msg) { FromWs(ws_msg) })
        )

      let state = State(
        config: config,
        handler: handler,
        self: subject,
        ws_subject: None,
        session_id: None,
        subscriptions: [],
        reconnect_url: None,
        keepalive_timer: None,
        reconnect_timer: None,
        reconnect_attempts: 0,
        max_reconnect_attempts: 10,
        is_connected: False,
        ready_subject: Some(ready_subject),
      )

      // Attempt initial WebSocket connection
      case websocket.start(config, handler, ws_subject, "wss://eventsub.wss.twitch.tv/ws") {
        Ok(ws) -> {
          logging.log(logging.Info, "gwitchel: WebSocket connection started")
          actor.initialised(State(..state, ws_subject: Some(ws)))
          |> actor.selecting(selector)
          |> actor.returning(subject)
          |> Ok
        }
        Error(err) -> {
          logging.log(logging.Error, "gwitchel: Failed to start WebSocket: " <> string.inspect(err))
          let backoff = initial_reconnect_backoff_ms
          let timer = process.send_after(subject, backoff, ReconnectTimer)
          actor.initialised(State(..state, reconnect_timer: Some(timer), reconnect_attempts: 1))
          |> actor.selecting(selector)
          |> actor.returning(subject)
          |> Ok
        }
      }
    })
    |> actor.on_message(handle_message)

  case actor.start(builder) {
    Ok(started) -> {
      // Wait for session_welcome before returning to caller
      case process.receive(ready_subject, 5000) {
        Ok(_) -> Ok(Connection(started.data))
        Error(_) -> {
          logging.log(logging.Error, "gwitchel: Timeout waiting for session_welcome")
          Error(WebSocketError("Timeout waiting for session_welcome from Twitch"))
        }
      }
    }
    Error(err) -> {
      logging.log(logging.Error, "gwitchel: Failed to start manager: " <> string.inspect(err))
      Error(WebSocketError("Failed to start manager actor"))
    }
  }
}

/// Subscribe to an EventSub event type.
pub fn subscribe(
  connection: Connection,
  subscription: Subscription,
) -> Result(Nil, Error) {
  let Connection(subject) = connection
  let reply_to = process.new_subject()
  process.send(subject, User(Subscribe(subscription, reply_to)))

  process.receive(reply_to, 10_000)
  |> result.map_error(fn(_) { WebSocketError("Subscription request timed out") })
  |> result.flatten
}

/// Disconnect from Twitch EventSub and clean up resources.
pub fn stop(connection: Connection) -> Nil {
  let Connection(subject) = connection
  process.send(subject, User(Stop))
}

// --- Internal message handlers ---

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    User(user_msg) -> handle_user_msg(state, user_msg)
    FromWs(ws_msg) -> handle_ws_msg(state, ws_msg)
    WsStarted(result) -> handle_ws_started(state, result)
    ReconnectTimer -> handle_reconnect_timer(state)
    KeepaliveExpired -> handle_keepalive_expired(state)
  }
}

fn handle_user_msg(state: State, msg: UserMsg) -> actor.Next(State, Msg) {
  case msg {
    Subscribe(sub, reply_to) -> handle_subscribe(state, sub, reply_to)
    Stop -> handle_stop(state)
  }
}

fn handle_subscribe(
  state: State,
  sub: Subscription,
  reply_to: Subject(Result(Nil, Error)),
) -> actor.Next(State, Msg) {
  let new_state = State(..state, subscriptions: [sub, ..state.subscriptions])

  case state.session_id {
    Some(session_id) -> {
      let result = subscription.create(state.config, session_id, sub)
      process.send(reply_to, result)
    }
    None -> {
      process.send(reply_to, Error(SessionClosed))
    }
  }

  actor.continue(new_state)
}

fn handle_stop(state: State) -> actor.Next(State, Msg) {
  logging.log(logging.Info, "gwitchel: Stopping connection")

  // Cancel all timers
  let _ = option.map(state.keepalive_timer, process.cancel_timer)
  let _ = option.map(state.reconnect_timer, process.cancel_timer)

  // Stop WebSocket actor if running
  option.map(state.ws_subject, websocket.stop)

  actor.stop()
}

fn handle_ws_msg(state: State, msg: WsToManagerMsg) -> actor.Next(State, Msg) {
  case msg {
    WsConnected(session_id, keepalive_seconds) -> {
      logging.log(logging.Debug, "gwitchel: Session connected: " <> session_id)

      // Signal to the parent process that we are ready
      case state.ready_subject {
        Some(ready) -> process.send(ready, Nil)
        None -> Nil
      }

      // Cancel any pending reconnect timer
      let _ = option.map(state.reconnect_timer, process.cancel_timer)

      // Start keepalive timer
      let timeout_ms = keepalive_seconds * 1000 + keepalive_grace_ms
      let timer = process.send_after(state.self, timeout_ms, KeepaliveExpired)

      let new_state = State(
        ..state,
        session_id: Some(session_id),
        keepalive_timer: Some(timer),
        reconnect_timer: None,
        reconnect_attempts: 0,
        is_connected: True,
        ready_subject: None,
      )

      // Re-subscribe to all previously registered subscriptions
      let new_state = resubscribe_all(new_state)

      actor.continue(new_state)
    }

    WsKeepalive -> {
      // Reset keepalive timer
      let _ = option.map(state.keepalive_timer, process.cancel_timer)

      let timeout_ms = default_keepalive_seconds * 1000 + keepalive_grace_ms
      let timer = process.send_after(state.self, timeout_ms, KeepaliveExpired)
      actor.continue(State(..state, keepalive_timer: Some(timer)))
    }

    WsReconnect(url) -> {
      logging.log(logging.Info, "gwitchel: Reconnect requested to: " <> url)
      actor.continue(State(..state, reconnect_url: Some(url)))
    }

    WsEvent(event) -> {
      state.handler(event)
      actor.continue(state)
    }

    WsClosed(reason) -> {
      logging.log(logging.Info, "gwitchel: WebSocket closed: " <> string.inspect(reason))

      // Cancel keepalive timer
      let _ = option.map(state.keepalive_timer, process.cancel_timer)

      case state.reconnect_url {
        Some(url) -> {
          // Server-initiated reconnect (session_reconnect)
          logging.log(logging.Info, "gwitchel: Performing server-initiated reconnect")
          do_connect_async(state, url)
          actor.continue(State(..state, reconnect_url: None, ws_subject: None, is_connected: False))
        }
        None -> {
          // Unexpected disconnect — schedule reconnect with backoff
          schedule_reconnect(state)
        }
      }
    }
  }
}

fn handle_ws_started(
  state: State,
  result: Result(Subject(stratus.InternalMessage(websocket.UserMsg)), Error),
) -> actor.Next(State, Msg) {
  case result {
    Ok(ws_subject) -> {
      logging.log(logging.Debug, "gwitchel: WebSocket actor started")
      actor.continue(State(..state, ws_subject: Some(ws_subject)))
    }
    Error(err) -> {
      logging.log(logging.Error, "gwitchel: Failed to start WebSocket actor: " <> string.inspect(err))
      schedule_reconnect(State(..state, ws_subject: None, is_connected: False))
    }
  }
}

fn handle_reconnect_timer(state: State) -> actor.Next(State, Msg) {
  let url = option.unwrap(state.reconnect_url, "wss://eventsub.wss.twitch.tv/ws")
  logging.log(logging.Info, "gwitchel: Reconnect timer fired, connecting to: " <> url)
  do_connect_async(state, url)
  actor.continue(state)
}

fn handle_keepalive_expired(state: State) -> actor.Next(State, Msg) {
  logging.log(logging.Error, "gwitchel: Keepalive timeout expired, forcing reconnect")

  // Stop current WebSocket actor
  option.map(state.ws_subject, websocket.stop)

  schedule_reconnect(State(..state, ws_subject: None, is_connected: False))
}

// --- Helper functions ---

fn do_connect_async(state: State, url: String) -> Nil {
  // Start WebSocket in a separate process to avoid blocking the manager
  let ws_subject = process.new_subject()
  let _ = process.spawn_unlinked(fn() {
    case websocket.start(state.config, state.handler, ws_subject, url) {
      Ok(ws) -> process.send(state.self, WsStarted(Ok(ws)))
      Error(err) -> process.send(state.self, WsStarted(Error(err)))
    }
  })
  Nil
}

fn schedule_reconnect(state: State) -> actor.Next(State, Msg) {
  case state.reconnect_attempts >= state.max_reconnect_attempts {
    True -> {
      logging.log(logging.Error, "gwitchel: Max reconnect attempts exceeded")
      actor.stop()
    }
    False -> {
      let backoff = calculate_backoff(state.reconnect_attempts)
      logging.log(logging.Info, "gwitchel: Scheduling reconnect in " <> int.to_string(backoff) <> "ms")
      let timer = process.send_after(state.self, backoff, ReconnectTimer)
      actor.continue(State(
        ..state,
        reconnect_timer: Some(timer),
        reconnect_attempts: state.reconnect_attempts + 1,
        ws_subject: None,
        is_connected: False,
      ))
    }
  }
}

pub fn calculate_backoff(attempt: Int) -> Int {
  let base = initial_reconnect_backoff_ms
  let exponential = base * int.bitwise_shift_left(1, attempt)
  int.min(exponential, max_reconnect_backoff_ms)
}

fn resubscribe_all(state: State) -> State {
  case state.session_id {
    Some(session_id) -> {
      list.each(state.subscriptions, fn(sub) {
        case subscription.create(state.config, session_id, sub) {
          Ok(_) -> Nil
          Error(err) -> {
            logging.log(logging.Warning, "gwitchel: Resubscription failed: " <> string.inspect(err))
            Nil
          }
        }
      })
      state
    }
    None -> state
  }
}
