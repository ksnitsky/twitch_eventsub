import gleam/http
import gleam/int
import gleam/option.{None, Some}
import gleeunit/should
import internal/subscription
import support/mock_servers
import types.{
  type Config, type Error, type Subscription, AuthError, Config, Subscription,
  SubscriptionError,
}

const sample_session_id = "session-1"

fn config_for(port: Int) -> Config {
  Config(
    client_id: "stub-client",
    access_token: "stub-token",
    eventsub_ws_url: None,
    helix_base_url: Some("http://127.0.0.1:" <> int.to_string(port)),
    on_status: None,
  )
}

fn sample_subscription() -> Subscription {
  Subscription(type_: "channel.chat.message", version: "1", condition: [
    #("broadcaster_user_id", "111"),
    #("user_id", "222"),
  ])
}

pub fn create_returns_id_test() {
  let handler = fn(method, _body) {
    case method {
      http.Post -> #(
        202,
        "{\"data\":[{\"id\":\"sub-abc\",\"status\":\"enabled\"}]}",
      )
      _ -> #(405, "")
    }
  }
  let #(port, stop) = mock_servers.start_helix(handler)

  let result =
    subscription.create(
      config_for(port),
      sample_session_id,
      sample_subscription(),
    )

  stop()

  result
  |> should.be_ok
  |> should.equal("sub-abc")
}

pub fn create_401_returns_auth_error_test() {
  let handler = fn(_method, _body) { #(401, "{\"message\":\"unauthorized\"}") }
  let #(port, stop) = mock_servers.start_helix(handler)

  let result =
    subscription.create(
      config_for(port),
      sample_session_id,
      sample_subscription(),
    )

  stop()

  expect_auth_error(result)
}

pub fn create_403_returns_auth_error_test() {
  let handler = fn(_method, _body) { #(403, "{\"message\":\"forbidden\"}") }
  let #(port, stop) = mock_servers.start_helix(handler)

  let result =
    subscription.create(
      config_for(port),
      sample_session_id,
      sample_subscription(),
    )

  stop()

  expect_auth_error(result)
}

pub fn create_500_returns_subscription_error_test() {
  let handler = fn(_method, _body) { #(500, "{\"message\":\"server error\"}") }
  let #(port, stop) = mock_servers.start_helix(handler)

  let result =
    subscription.create(
      config_for(port),
      sample_session_id,
      sample_subscription(),
    )

  stop()

  expect_subscription_error(result)
}

pub fn delete_204_returns_ok_test() {
  let handler = fn(method, _body) {
    case method {
      http.Delete -> #(204, "")
      _ -> #(405, "")
    }
  }
  let #(port, stop) = mock_servers.start_helix(handler)

  let result = subscription.delete(config_for(port), "sub-abc")

  stop()

  result
  |> should.be_ok
  |> should.equal(Nil)
}

pub fn list_returns_ids_test() {
  let handler = fn(method, _body) {
    case method {
      http.Get -> #(200, "{\"data\":[{\"id\":\"a\"},{\"id\":\"b\"}]}")
      _ -> #(405, "")
    }
  }
  let #(port, stop) = mock_servers.start_helix(handler)

  let result = subscription.list(config_for(port))

  stop()

  result
  |> should.be_ok
  |> should.equal(["a", "b"])
}

fn expect_auth_error(result: Result(a, Error)) -> Nil {
  case result {
    Error(AuthError(_)) -> Nil
    _ -> panic as "Expected AuthError"
  }
}

fn expect_subscription_error(result: Result(a, Error)) -> Nil {
  case result {
    Error(SubscriptionError(_)) -> Nil
    _ -> panic as "Expected SubscriptionError"
  }
}
