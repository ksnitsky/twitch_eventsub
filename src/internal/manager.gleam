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
  SubscriptionNotFound, WebSocketError,
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
  Unsubscribe(type_: String, reply_to: Subject(Result(Nil, Error)))
  ListSubscriptions(Subject(List(Subscription)))
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
    /// Active subscriptions paired with the ID Twitch assigned at create
    /// time. ID is required for unsubscribe; the `Subscription` value is
    /// kept so we can re-create them after a reconnect (when the old IDs
    /// become invalid because the session changes).
    subscriptions: List(#(String, Subscription)),
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
          logging.log(logging.Info, "twitch_eventsub: WebSocket connection started")
          actor.initialised(State(..state, ws_subject: Some(ws)))
          |> actor.selecting(selector)
          |> actor.returning(subject)
          |> Ok
        }
        Error(err) -> {
          logging.log(logging.Error, "twitch_eventsub: Failed to start WebSocket: " <> string.inspect(err))
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
          logging.log(logging.Error, "twitch_eventsub: Timeout waiting for session_welcome")
          Error(WebSocketError("Timeout waiting for session_welcome from Twitch"))
        }
      }
    }
    Error(err) -> {
      logging.log(logging.Error, "twitch_eventsub: Failed to start manager: " <> string.inspect(err))
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
  call(subject, fn(reply_to) { Subscribe(subscription, reply_to) })
}

/// Remove all active subscriptions of the given type. Returns
/// `SubscriptionNotFound` if there is no matching subscription.
pub fn unsubscribe(
  connection: Connection,
  subscription_type: String,
) -> Result(Nil, Error) {
  let Connection(subject) = connection
  call(subject, fn(reply_to) { Unsubscribe(subscription_type, reply_to) })
}

/// List all subscriptions currently tracked by the manager.
pub fn list_subscriptions(connection: Connection) -> List(Subscription) {
  let Connection(subject) = connection
  let reply_to = process.new_subject()
  process.send(subject, User(ListSubscriptions(reply_to)))
  process.receive(reply_to, 5000)
  |> result.unwrap([])
}

/// Disconnect from Twitch EventSub and clean up resources.
pub fn stop(connection: Connection) -> Nil {
  let Connection(subject) = connection
  process.send(subject, User(Stop))
}

/// Round-trip a UserMsg that carries a `Subject(Result(Nil, Error))` reply.
fn call(
  subject: Subject(Msg),
  build: fn(Subject(Result(Nil, Error))) -> UserMsg,
) -> Result(Nil, Error) {
  let reply_to = process.new_subject()
  process.send(subject, User(build(reply_to)))
  process.receive(reply_to, 10_000)
  |> result.map_error(fn(_) { WebSocketError("Manager request timed out") })
  |> result.flatten
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
    Unsubscribe(type_, reply_to) -> handle_unsubscribe(state, type_, reply_to)
    ListSubscriptions(reply_to) -> handle_list(state, reply_to)
    Stop -> handle_stop(state)
  }
}

fn handle_subscribe(
  state: State,
  sub: Subscription,
  reply_to: Subject(Result(Nil, Error)),
) -> actor.Next(State, Msg) {
  case state.session_id {
    None -> {
      process.send(reply_to, Error(SessionClosed))
      actor.continue(state)
    }
    Some(session_id) ->
      case subscription.create(state.config, session_id, sub) {
        Ok(id) -> {
          process.send(reply_to, Ok(Nil))
          actor.continue(
            State(..state, subscriptions: [#(id, sub), ..state.subscriptions]),
          )
        }
        Error(err) -> {
          process.send(reply_to, Error(err))
          actor.continue(state)
        }
      }
  }
}

fn handle_unsubscribe(
  state: State,
  subscription_type: String,
  reply_to: Subject(Result(Nil, Error)),
) -> actor.Next(State, Msg) {
  let #(matching, remaining) =
    list.partition(state.subscriptions, fn(entry) {
      let #(_, sub) = entry
      sub.type_ == subscription_type
    })

  case matching {
    [] -> {
      process.send(reply_to, Error(SubscriptionNotFound))
      actor.continue(state)
    }
    _ -> {
      let delete_result =
        list.try_each(matching, fn(entry) {
          let #(id, _) = entry
          subscription.delete(state.config, id)
        })
      process.send(reply_to, delete_result)
      // Remove from local state regardless — a failed delete usually means
      // the remote side already lost the subscription, and we don't want to
      // leak stale entries that would be re-created on the next reconnect.
      actor.continue(State(..state, subscriptions: remaining))
    }
  }
}

fn handle_list(
  state: State,
  reply_to: Subject(List(Subscription)),
) -> actor.Next(State, Msg) {
  let subs =
    state.subscriptions
    |> list.map(fn(entry) { entry.1 })
  process.send(reply_to, subs)
  actor.continue(state)
}

fn handle_stop(state: State) -> actor.Next(State, Msg) {
  logging.log(logging.Info, "twitch_eventsub: Stopping connection")

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
      logging.log(logging.Debug, "twitch_eventsub: Session connected: " <> session_id)

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
      logging.log(logging.Info, "twitch_eventsub: Reconnect requested to: " <> url)
      actor.continue(State(..state, reconnect_url: Some(url)))
    }

    WsEvent(event) -> {
      state.handler(event)
      actor.continue(state)
    }

    WsClosed(reason) -> {
      logging.log(logging.Info, "twitch_eventsub: WebSocket closed: " <> string.inspect(reason))

      // Cancel keepalive timer
      let _ = option.map(state.keepalive_timer, process.cancel_timer)

      case state.reconnect_url {
        Some(url) -> {
          // Server-initiated reconnect (session_reconnect)
          logging.log(logging.Info, "twitch_eventsub: Performing server-initiated reconnect")
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
      logging.log(logging.Debug, "twitch_eventsub: WebSocket actor started")
      actor.continue(State(..state, ws_subject: Some(ws_subject)))
    }
    Error(err) -> {
      logging.log(logging.Error, "twitch_eventsub: Failed to start WebSocket actor: " <> string.inspect(err))
      schedule_reconnect(State(..state, ws_subject: None, is_connected: False))
    }
  }
}

fn handle_reconnect_timer(state: State) -> actor.Next(State, Msg) {
  let url = option.unwrap(state.reconnect_url, "wss://eventsub.wss.twitch.tv/ws")
  logging.log(logging.Info, "twitch_eventsub: Reconnect timer fired, connecting to: " <> url)
  do_connect_async(state, url)
  actor.continue(state)
}

fn handle_keepalive_expired(state: State) -> actor.Next(State, Msg) {
  logging.log(logging.Error, "twitch_eventsub: Keepalive timeout expired, forcing reconnect")

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
      logging.log(logging.Error, "twitch_eventsub: Max reconnect attempts exceeded")
      actor.stop()
    }
    False -> {
      let backoff = calculate_backoff(state.reconnect_attempts)
      logging.log(logging.Info, "twitch_eventsub: Scheduling reconnect in " <> int.to_string(backoff) <> "ms")
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
    None -> state
    Some(session_id) -> {
      // Old IDs are tied to the previous session and are no longer valid.
      // Re-create each subscription, drop any that fail (and log them) so
      // the rest of the connection keeps working.
      let refreshed =
        list.filter_map(state.subscriptions, fn(entry) {
          let #(_old_id, sub) = entry
          case subscription.create(state.config, session_id, sub) {
            Ok(new_id) -> Ok(#(new_id, sub))
            Error(err) -> {
              logging.log(
                logging.Warning,
                "twitch_eventsub: Resubscription failed for "
                  <> sub.type_
                  <> ": "
                  <> string.inspect(err),
              )
              Error(Nil)
            }
          }
        })
      State(..state, subscriptions: refreshed)
    }
  }
}
