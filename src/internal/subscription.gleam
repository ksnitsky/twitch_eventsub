import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/httpc
import types.{type Config, type Error, type Subscription, HttpError, SubscriptionError}

/// Create an EventSub subscription via the Helix API.
pub fn create(
  config: Config,
  session_id: String,
  subscription: Subscription,
) -> Result(Nil, Error) {
  let body = build_subscription_body(subscription, session_id)

  let req =
    request.new()
    |> request.set_host("api.twitch.tv")
    |> request.set_path("/helix/eventsub/subscriptions")
    |> request.set_scheme(http.Https)
    |> request.set_method(http.Post)
    |> request.set_header("Client-Id", config.client_id)
    |> request.set_header("Authorization", "Bearer " <> config.access_token)
    |> request.set_header("Content-Type", "application/json")
    |> request.set_body(body)

  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(err) {
      HttpError("HTTP request failed: " <> string.inspect(err))
    }),
  )

  case resp.status {
    202 | 201 -> Ok(Nil)
    _ -> {
      let error_msg =
        "Subscription failed with status "
        <> string.inspect(resp.status)
        <> ": "
        <> resp.body
      Error(SubscriptionError(error_msg))
    }
  }
}

pub fn build_subscription_body(subscription: Subscription, session_id: String) -> String {
  let condition_object =
    subscription.condition
    |> list.map(fn(pair) {
      let #(key, value) = pair
      #(key, json.string(value))
    })

  json.object([
    #("type", json.string(subscription.type_)),
    #("version", json.string(subscription.version)),
    #("condition", json.object(condition_object)),
    #(
      "transport",
      json.object([
        #("method", json.string("websocket")),
        #("session_id", json.string(session_id)),
      ]),
    ),
  ])
  |> json.to_string()
}
