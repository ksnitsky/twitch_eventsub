import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import internal/messages.{
  type WsToManagerMsg, WsClosed, WsConnected, WsEvent, WsKeepalive, WsReconnect,
}
import internal/session
import stratus
import types.{
  type Config, type Error, type Event, type Subscription, MessageParseFailed,
  UnknownMessageType, WebSocketError, emit_status,
}

// --- Public types ---

pub type UserMsg {
  Subscribe(Subscription, Subject(Result(Nil, Error)))
  Stop
}

// --- Internal types ---

pub type WsState {
  WsState(
    config: Config,
    handler: fn(Event) -> Nil,
    session_id: Option(String),
    manager: Subject(WsToManagerMsg),
  )
}

// --- Public API ---

/// Start a stratus WebSocket actor connected to Twitch EventSub.
pub fn start(
  config: Config,
  handler: fn(Event) -> Nil,
  manager: Subject(WsToManagerMsg),
  url: String,
) -> Result(Subject(stratus.InternalMessage(UserMsg)), Error) {
  let req = build_request(url)
  let init_state = WsState(config, handler, None, manager)

  let builder =
    stratus.new(req, init_state)
    |> stratus.on_message(handle_message)
    |> stratus.on_close(handle_close)

  case stratus.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(err) ->
      Error(WebSocketError("Failed to start WebSocket: " <> string.inspect(err)))
  }
}

/// Send a subscription request to the WebSocket actor.
pub fn subscribe(
  subject: Subject(stratus.InternalMessage(UserMsg)),
  sub: Subscription,
) -> Result(Nil, Error) {
  let reply_to = process.new_subject()
  let msg = Subscribe(sub, reply_to)
  process.send(subject, stratus.to_user_message(msg))

  use response <- result.try(
    process.receive(reply_to, 10_000)
    |> result.map_error(fn(_) {
      WebSocketError("Subscription request timed out")
    }),
  )
  response
}

/// Stop the WebSocket actor.
pub fn stop(subject: Subject(stratus.InternalMessage(UserMsg))) -> Nil {
  process.send(subject, stratus.to_user_message(Stop))
}

// --- Internal handlers ---

fn handle_message(
  state: WsState,
  msg: stratus.Message(UserMsg),
  _conn: stratus.Connection,
) -> stratus.Next(WsState, UserMsg) {
  case msg {
    stratus.Text(text) -> handle_twitch_text(state, text)
    stratus.User(Subscribe(sub, reply_to)) ->
      handle_subscribe(state, sub, reply_to)
    stratus.User(Stop) -> stratus.stop()
    _ -> stratus.continue(state)
  }
}

fn handle_twitch_text(
  state: WsState,
  text: String,
) -> stratus.Next(WsState, UserMsg) {
  case session.parse_message(text) {
    Ok(session.Welcome(session_id, keepalive_seconds)) -> {
      process.send(state.manager, WsConnected(session_id, keepalive_seconds))
      stratus.continue(WsState(..state, session_id: Some(session_id)))
    }
    Ok(session.Keepalive) -> {
      process.send(state.manager, WsKeepalive)
      stratus.continue(state)
    }
    Ok(session.Reconnect(url)) -> {
      process.send(state.manager, WsReconnect(url))
      stratus.stop()
    }
    Ok(session.Notification(_, event)) -> {
      process.send(state.manager, WsEvent(event))
      stratus.continue(state)
    }
    Ok(session.Unknown(msg_type)) -> {
      emit_status(state.config, UnknownMessageType(msg_type))
      stratus.continue(state)
    }
    Error(err) -> {
      emit_status(state.config, MessageParseFailed(string.inspect(err)))
      stratus.continue(state)
    }
  }
}

fn handle_subscribe(
  state: WsState,
  _sub: Subscription,
  reply_to: Subject(Result(Nil, Error)),
) -> stratus.Next(WsState, UserMsg) {
  // NOTE: Subscriptions are actually created by the manager via Helix API.
  // This handler exists for backward compatibility but should not be called
  // directly when using the manager. The manager handles subscriptions.
  process.send(reply_to, Error(WebSocketError("Use manager.subscribe instead")))
  stratus.continue(state)
}

fn handle_close(state: WsState, reason: stratus.CloseReason) -> Nil {
  process.send(state.manager, WsClosed(reason))
}

// --- Request building ---

fn build_request(url: String) -> request.Request(String) {
  case uri.parse(url) {
    Ok(parsed) -> {
      let scheme = case parsed.scheme {
        Some("wss") -> http.Https
        Some("ws") -> http.Http
        _ -> http.Https
      }
      let host = option.unwrap(parsed.host, "eventsub.wss.twitch.tv")
      let path = build_path(parsed.path, parsed.query)

      let req =
        request.new()
        |> request.set_host(host)
        |> request.set_path(path)
        |> request.set_scheme(scheme)
      case parsed.port {
        Some(port) -> request.set_port(req, port)
        None -> req
      }
    }
    Error(_) -> {
      request.new()
      |> request.set_host("eventsub.wss.twitch.tv")
      |> request.set_path("/ws")
      |> request.set_scheme(http.Https)
    }
  }
}

fn build_path(path: String, query: Option(String)) -> String {
  let base_path = case path {
    "" -> "/ws"
    p -> p
  }
  case query {
    Some(q) -> base_path <> "?" <> q
    None -> base_path
  }
}
