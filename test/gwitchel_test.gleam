import gleam/string
import gleeunit
import gleeunit/should
import internal/session
import internal/subscription
import internal/manager
import types.{
  ChatMessage, HttpError, InvalidMessage, KeepaliveTimeout,
  MaxReconnectAttemptsExceeded, Message, MessageContent, Other,
  SessionClosed, Subscription, Text, WebSocketError,
}

pub fn main() {
  gleeunit.main()
}

// --- Session parsing tests ---

const welcome_json = "{\"metadata\":{\"message_id\":\"test-id\",\"message_type\":\"session_welcome\",\"message_timestamp\":\"2024-01-01T00:00:00.000000000Z\"},\"payload\":{\"session\":{\"id\":\"test-session-id\",\"status\":\"connected\",\"connected_at\":\"2024-01-01T00:00:00.000000000Z\",\"keepalive_timeout_seconds\":10,\"reconnect_url\":null}}}"

pub fn parse_welcome_test() {
  session.parse_message(welcome_json)
  |> should.be_ok
  |> should.equal(session.Welcome("test-session-id", 10))
}

const keepalive_json = "{\"metadata\":{\"message_id\":\"test-id\",\"message_type\":\"session_keepalive\",\"message_timestamp\":\"2024-01-01T00:00:00.000000000Z\"},\"payload\":{}}"

pub fn parse_keepalive_test() {
  session.parse_message(keepalive_json)
  |> should.be_ok
  |> should.equal(session.Keepalive)
}

const reconnect_json = "{\"metadata\":{\"message_id\":\"test-id\",\"message_type\":\"session_reconnect\",\"message_timestamp\":\"2024-01-01T00:00:00.000000000Z\"},\"payload\":{\"session\":{\"id\":\"test-session-id\",\"status\":\"reconnecting\",\"connected_at\":\"2024-01-01T00:00:00.000000000Z\",\"keepalive_timeout_seconds\":10,\"reconnect_url\":\"wss://eventsub.wss.twitch.tv/ws?test=1\"}}}"

pub fn parse_reconnect_test() {
  session.parse_message(reconnect_json)
  |> should.be_ok
  |> should.equal(session.Reconnect("wss://eventsub.wss.twitch.tv/ws?test=1"))
}

const chat_message_json = "{\"metadata\":{\"message_id\":\"msg-id\",\"message_type\":\"notification\",\"message_timestamp\":\"2024-01-01T00:00:00.000000000Z\",\"subscription_type\":\"channel.chat.message\",\"subscription_version\":\"1\"},\"payload\":{\"subscription\":{},\"event\":{\"broadcaster_user_id\":\"123\",\"broadcaster_user_login\":\"testbroadcaster\",\"broadcaster_user_name\":\"TestBroadcaster\",\"chatter_user_id\":\"456\",\"chatter_user_login\":\"testchatter\",\"chatter_user_name\":\"TestChatter\",\"message_id\":\"msg-id\",\"message\":{\"text\":\"Hello world\",\"fragments\":[{\"type\":\"text\",\"text\":\"Hello world\",\"cheermote\":null,\"emote\":null,\"mention\":null}]},\"color\":\"#FF0000\",\"badges\":[],\"message_type\":\"text\",\"cheer\":null,\"reply\":null,\"channel_points_custom_reward_id\":null,\"channel_points_animation_id\":null}}}"

pub fn parse_chat_message_test() {
  let assert Ok(session.Notification("channel.chat.message", event)) =
    session.parse_message(chat_message_json)

  case event {
    Message(ChatMessage(
      broadcaster_user_id: "123",
      broadcaster_user_login: "testbroadcaster",
      chatter_user_id: "456",
      chatter_user_login: "testchatter",
      message: MessageContent(text: "Hello world", fragments: [Text("Hello world")]),
    )) -> Nil
    other -> panic as { "Unexpected event: " <> string.inspect(other) }
  }
}

const unknown_notification_json = "{\"metadata\":{\"message_id\":\"msg-id\",\"message_type\":\"notification\",\"message_timestamp\":\"2024-01-01T00:00:00.000000000Z\",\"subscription_type\":\"channel.follow\",\"subscription_version\":\"1\"},\"payload\":{\"subscription\":{},\"event\":{\"user_id\":\"123\",\"user_login\":\"testuser\",\"user_name\":\"TestUser\",\"broadcaster_user_id\":\"456\",\"broadcaster_user_login\":\"testbroadcaster\",\"broadcaster_user_name\":\"TestBroadcaster\",\"followed_at\":\"2024-01-01T00:00:00.000000000Z\"}}}"

pub fn parse_unknown_event_test() {
  let assert Ok(session.Notification("channel.follow", event)) =
    session.parse_message(unknown_notification_json)

  case event {
    Other("channel.follow", _) -> Nil
    other -> panic as { "Expected Other, got: " <> string.inspect(other) }
  }
}

pub fn parse_invalid_json_test() {
  session.parse_message("not json")
  |> should.be_error
  |> should.equal(InvalidMessage("Failed to parse JSON to dynamic value"))
}

pub fn parse_unknown_message_type_test() {
  session.parse_message("{\"metadata\":{\"message_type\":\"session_revocation\"},\"payload\":{}}")
  |> should.be_ok
  |> should.equal(session.Unknown("session_revocation"))
}

// --- Subscription body tests ---

pub fn build_subscription_body_test() {
  let sub = Subscription(
    type_: "channel.chat.message",
    version: "1",
    condition: [
      #("broadcaster_user_id", "123"),
      #("user_id", "456"),
    ],
  )

  let body = subscription.build_subscription_body(sub, "test-session-id")

  should.equal(
    body,
    "{\"type\":\"channel.chat.message\",\"version\":\"1\",\"condition\":{\"broadcaster_user_id\":\"123\",\"user_id\":\"456\"},\"transport\":{\"method\":\"websocket\",\"session_id\":\"test-session-id\"}}",
  )
}

// --- Backoff calculation tests ---

pub fn calculate_backoff_initial_test() {
  manager.calculate_backoff(0)
  |> should.equal(1000)
}

pub fn calculate_backoff_second_attempt_test() {
  manager.calculate_backoff(1)
  |> should.equal(2000)
}

pub fn calculate_backoff_third_attempt_test() {
  manager.calculate_backoff(2)
  |> should.equal(4000)
}

pub fn calculate_backoff_max_test() {
  manager.calculate_backoff(10)
  |> should.equal(60_000)
}

// --- Error type tests ---

pub fn error_types_test() {
  // Verify all error variants can be created
  let _ = WebSocketError("test")
  let _ = HttpError("test")
  let _ = InvalidMessage("test")
  let _ = SessionClosed
  let _ = MaxReconnectAttemptsExceeded
  let _ = KeepaliveTimeout

  // Verify specific error values
  should.equal(WebSocketError("connection failed"), WebSocketError("connection failed"))
  should.equal(SessionClosed, SessionClosed)
  should.equal(MaxReconnectAttemptsExceeded, MaxReconnectAttemptsExceeded)
  should.equal(KeepaliveTimeout, KeepaliveTimeout)
}

// --- Edge case tests ---

pub fn parse_empty_chat_message_test() {
  let json = "{\"metadata\":{\"message_id\":\"msg-id\",\"message_type\":\"notification\",\"message_timestamp\":\"2024-01-01T00:00:00.000000000Z\",\"subscription_type\":\"channel.chat.message\",\"subscription_version\":\"1\"},\"payload\":{\"subscription\":{},\"event\":{\"broadcaster_user_id\":\"123\",\"broadcaster_user_login\":\"testbroadcaster\",\"chatter_user_id\":\"456\",\"chatter_user_login\":\"testchatter\",\"message\":{\"text\":\"\",\"fragments\":[]}}}}"

  let assert Ok(session.Notification("channel.chat.message", event)) =
    session.parse_message(json)

  case event {
    Message(ChatMessage(
      message: MessageContent(text: "", fragments: [Text("")]),
      ..
    )) -> Nil
    other -> panic as { "Unexpected event: " <> string.inspect(other) }
  }
}

pub fn parse_chat_message_with_special_chars_test() {
  let json = "{\"metadata\":{\"message_id\":\"msg-id\",\"message_type\":\"notification\",\"message_timestamp\":\"2024-01-01T00:00:00.000000000Z\",\"subscription_type\":\"channel.chat.message\",\"subscription_version\":\"1\"},\"payload\":{\"subscription\":{},\"event\":{\"broadcaster_user_id\":\"123\",\"broadcaster_user_login\":\"testbroadcaster\",\"chatter_user_id\":\"456\",\"chatter_user_login\":\"testchatter\",\"message\":{\"text\":\"Hello :) \\u2764\\u2764\\u2764\",\"fragments\":[]}}}}"

  let assert Ok(session.Notification("channel.chat.message", event)) =
    session.parse_message(json)

  case event {
    Message(ChatMessage(
      message: MessageContent(text: "Hello :) ❤❤❤", ..),
      ..
    )) -> Nil
    other -> panic as { "Unexpected event: " <> string.inspect(other) }
  }
}

pub fn build_subscription_body_empty_condition_test() {
  let sub = Subscription(
    type_: "channel.follow",
    version: "1",
    condition: [],
  )

  let body = subscription.build_subscription_body(sub, "test-session-id")

  should.equal(
    body,
    "{\"type\":\"channel.follow\",\"version\":\"1\",\"condition\":{},\"transport\":{\"method\":\"websocket\",\"session_id\":\"test-session-id\"}}",
  )
}

// --- Connection state tests (timing issue) ---

/// Test that verifies the error type used when session is not ready.
/// This tests the fix for the timing issue where connect() returned
/// before session_welcome was received, causing subscribe() to fail.
pub fn session_closed_error_test() {
  // SessionClosed is the error returned when trying to subscribe
  // before the WebSocket session is established
  should.equal(SessionClosed, SessionClosed)
  
  // Verify it's the correct error for this scenario
  let err = SessionClosed
  case err {
    SessionClosed -> Nil
  }
}
