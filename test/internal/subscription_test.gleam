import gleeunit/should
import internal/subscription
import types.{Subscription}

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
