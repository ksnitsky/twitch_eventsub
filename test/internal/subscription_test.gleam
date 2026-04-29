import gleeunit/should
import internal/subscription
import types.{
  type Error, AuthError, InvalidMessage, Subscription, SubscriptionError,
}

// --- build_subscription_body ---

pub fn build_subscription_body_test() {
  let sub =
    Subscription(type_: "channel.chat.message", version: "1", condition: [
      #("broadcaster_user_id", "123"),
      #("user_id", "456"),
    ])

  let body = subscription.build_subscription_body(sub, "test-session-id")

  should.equal(
    body,
    "{\"type\":\"channel.chat.message\",\"version\":\"1\",\"condition\":{\"broadcaster_user_id\":\"123\",\"user_id\":\"456\"},\"transport\":{\"method\":\"websocket\",\"session_id\":\"test-session-id\"}}",
  )
}

pub fn build_subscription_body_empty_condition_test() {
  let sub = Subscription(type_: "channel.follow", version: "1", condition: [])

  let body = subscription.build_subscription_body(sub, "test-session-id")

  should.equal(
    body,
    "{\"type\":\"channel.follow\",\"version\":\"1\",\"condition\":{},\"transport\":{\"method\":\"websocket\",\"session_id\":\"test-session-id\"}}",
  )
}

// --- status_to_error: 401/403 must be auth, others must be subscription ---

pub fn status_to_error_401_is_auth_test() {
  case subscription.status_to_error(401, "{\"message\":\"unauthorized\"}") {
    AuthError(_) -> Nil
    other -> panic_with("Expected AuthError for 401", other)
  }
}

pub fn status_to_error_403_is_auth_test() {
  case subscription.status_to_error(403, "missing scope") {
    AuthError(_) -> Nil
    other -> panic_with("Expected AuthError for 403", other)
  }
}

pub fn status_to_error_400_is_subscription_test() {
  case subscription.status_to_error(400, "bad request") {
    SubscriptionError(_) -> Nil
    other -> panic_with("Expected SubscriptionError for 400", other)
  }
}

pub fn status_to_error_500_is_subscription_test() {
  case subscription.status_to_error(500, "server error") {
    SubscriptionError(_) -> Nil
    other -> panic_with("Expected SubscriptionError for 500", other)
  }
}

fn panic_with(label: String, value: Error) -> a {
  panic as { label <> ": " <> describe_error(value) }
}

fn describe_error(err: Error) -> String {
  case err {
    AuthError(msg) -> "AuthError(" <> msg <> ")"
    SubscriptionError(msg) -> "SubscriptionError(" <> msg <> ")"
    InvalidMessage(msg) -> "InvalidMessage(" <> msg <> ")"
    _ -> "other"
  }
}

// --- response parsing ---

pub fn parse_first_subscription_id_test() {
  let body =
    "{\"data\":[{\"id\":\"abc-123\",\"status\":\"enabled\",\"type\":\"channel.chat.message\",\"version\":\"1\"}]}"
  subscription.parse_first_subscription_id(body)
  |> should.be_ok
  |> should.equal("abc-123")
}

pub fn parse_first_subscription_id_empty_data_test() {
  let body = "{\"data\":[]}"
  case subscription.parse_first_subscription_id(body) {
    Error(InvalidMessage(_)) -> Nil
    other ->
      panic as { "Expected InvalidMessage, got: " <> describe_result(other) }
  }
}

pub fn parse_subscription_ids_multiple_test() {
  let body = "{\"data\":[{\"id\":\"a\"},{\"id\":\"b\"},{\"id\":\"c\"}]}"
  subscription.parse_subscription_ids(body)
  |> should.be_ok
  |> should.equal(["a", "b", "c"])
}

pub fn parse_subscription_ids_invalid_json_test() {
  case subscription.parse_subscription_ids("not json") {
    Error(InvalidMessage(_)) -> Nil
    other ->
      panic as { "Expected InvalidMessage, got: " <> describe_result(other) }
  }
}

fn describe_result(r: Result(a, Error)) -> String {
  case r {
    Ok(_) -> "Ok"
    Error(e) -> describe_error(e)
  }
}
