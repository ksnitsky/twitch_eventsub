import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/result
import internal/decoders
import types.{type Error, type Event, InvalidMessage, Message, Other}

/// Internal representation of raw EventSub WebSocket messages.
pub type EventSubMessage {
  Welcome(session_id: String, keepalive_seconds: Int)
  Keepalive
  Reconnect(reconnect_url: String)
  Notification(type_: String, event: Event)
  Unknown(String)
}

/// Parse a JSON string from Twitch EventSub WebSocket.
pub fn parse_message(json_string: String) -> Result(EventSubMessage, Error) {
  use raw <- result.try(
    json.parse(json_string, decode.dynamic)
    |> result.map_error(fn(_err) {
      InvalidMessage("Failed to parse JSON to dynamic value")
    }),
  )

  use message_type <- result.try(
    decode.run(raw, decode.at(["metadata", "message_type"], decode.string))
    |> result.map_error(fn(_err) {
      InvalidMessage("Missing or invalid message_type in metadata")
    }),
  )

  case message_type {
    "session_welcome" -> parse_welcome(raw)
    "session_keepalive" -> Ok(Keepalive)
    "session_reconnect" -> parse_reconnect(raw)
    "notification" -> parse_notification(raw)
    other -> Ok(Unknown(other))
  }
}

/// Run a decoder at a path and tag any failure as `InvalidMessage(context)`.
fn decode_at(
  raw: dynamic.Dynamic,
  path: List(String),
  decoder: decode.Decoder(a),
  context: String,
) -> Result(a, Error) {
  decode.run(raw, decode.at(path, decoder))
  |> result.map_error(fn(_) { InvalidMessage(context) })
}

fn parse_welcome(raw: dynamic.Dynamic) -> Result(EventSubMessage, Error) {
  use #(session_id, keepalive_seconds) <- result.map(decode_at(
    raw,
    ["payload", "session"],
    decoders.welcome_session(),
    "Missing session id in welcome payload",
  ))
  Welcome(session_id, keepalive_seconds)
}

fn parse_reconnect(raw: dynamic.Dynamic) -> Result(EventSubMessage, Error) {
  use url <- result.map(decode_at(
    raw,
    ["payload", "session"],
    decoders.reconnect_url(),
    "Missing reconnect_url in reconnect payload",
  ))
  Reconnect(url)
}

fn parse_notification(raw: dynamic.Dynamic) -> Result(EventSubMessage, Error) {
  use subscription_type <- result.try(decode_at(
    raw,
    ["metadata", "subscription_type"],
    decode.string,
    "Missing subscription_type in notification metadata",
  ))

  case subscription_type {
    "channel.chat.message" -> parse_chat_message(raw, subscription_type)
    _ -> parse_unknown_event(raw, subscription_type)
  }
}

fn parse_chat_message(
  raw: dynamic.Dynamic,
  subscription_type: String,
) -> Result(EventSubMessage, Error) {
  use chat <- result.map(decode_at(
    raw,
    ["payload", "event"],
    decoders.chat_message(),
    "Invalid chat message event payload",
  ))
  Notification(subscription_type, Message(chat))
}

fn parse_unknown_event(
  raw: dynamic.Dynamic,
  subscription_type: String,
) -> Result(EventSubMessage, Error) {
  use event_dynamic <- result.map(decode_at(
    raw,
    ["payload", "event"],
    decode.dynamic,
    "Missing event in notification payload",
  ))
  Notification(subscription_type, Other(subscription_type, event_dynamic))
}
