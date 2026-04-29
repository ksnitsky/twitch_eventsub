import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/result
import types.{
  type Error, type Event, ChatMessage, InvalidMessage, Message, Other,
}

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

// --- Parsers for each message type ---

fn parse_welcome(raw: dynamic.Dynamic) -> Result(EventSubMessage, Error) {
  use session_id <- result.try(
    decode.run(raw, decode.at(["payload", "session", "id"], decode.string))
    |> result.map_error(fn(_err) {
      InvalidMessage("Missing session id in welcome payload")
    }),
  )

  let keepalive_seconds =
    decode.run(
      raw,
      decode.at(
        ["payload", "session", "keepalive_timeout_seconds"],
        decode.int,
      ),
    )
    |> result.unwrap(10)

  Ok(Welcome(session_id, keepalive_seconds))
}

fn parse_reconnect(raw: dynamic.Dynamic) -> Result(EventSubMessage, Error) {
  use reconnect_url <- result.try(
    decode.run(
      raw,
      decode.at(["payload", "session", "reconnect_url"], decode.string),
    )
    |> result.map_error(fn(_err) {
      InvalidMessage("Missing reconnect_url in reconnect payload")
    }),
  )

  Ok(Reconnect(reconnect_url))
}

fn parse_notification(raw: dynamic.Dynamic) -> Result(EventSubMessage, Error) {
  use subscription_type <- result.try(
    decode.run(
      raw,
      decode.at(["metadata", "subscription_type"], decode.string),
    )
    |> result.map_error(fn(_err) {
      InvalidMessage("Missing subscription_type in notification metadata")
    }),
  )

  case subscription_type {
    "channel.chat.message" -> parse_chat_message(raw, subscription_type)
    _ -> parse_unknown_event(raw, subscription_type)
  }
}

fn parse_chat_message(
  raw: dynamic.Dynamic,
  subscription_type: String,
) -> Result(EventSubMessage, Error) {
  let decoder = {
    use broadcaster_user_id <- decode.field("broadcaster_user_id", decode.string)
    use broadcaster_user_login <- decode.field(
      "broadcaster_user_login",
      decode.string,
    )
    use chatter_user_id <- decode.field("chatter_user_id", decode.string)
    use chatter_user_login <- decode.field("chatter_user_login", decode.string)
    use message <- decode.field("message", message_decoder())

    decode.success(
      Message(
        ChatMessage(
          broadcaster_user_id:,
          broadcaster_user_login:,
          chatter_user_id:,
          chatter_user_login:,
          message:,
        ),
      ),
    )
  }

  use event <- result.try(
    decode.run(raw, decode.at(["payload", "event"], decoder))
    |> result.map_error(fn(_err) {
      InvalidMessage("Invalid chat message event payload")
    }),
  )

  Ok(Notification(subscription_type, event))
}

fn message_decoder() -> decode.Decoder(types.MessageContent) {
  use text <- decode.field("text", decode.string)
  decode.success(types.MessageContent(text:, fragments: [types.Text(text)]))
}

fn parse_unknown_event(
  raw: dynamic.Dynamic,
  subscription_type: String,
) -> Result(EventSubMessage, Error) {
  use event_dynamic <- result.try(
    decode.run(raw, decode.at(["payload", "event"], decode.dynamic))
    |> result.map_error(fn(_err) {
      InvalidMessage("Missing event in notification payload")
    }),
  )

  Ok(Notification(subscription_type, Other(subscription_type, event_dynamic)))
}
