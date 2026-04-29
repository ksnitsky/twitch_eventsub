import gleam/json
import gleeunit/should
import internal/decoders
import types.{Cheermote, Emote, Mention, MessageContent, Text}

// --- message_content ---

pub fn message_content_with_empty_fragments_test() {
  let json = "{\"text\":\"hi\",\"fragments\":[]}"
  json.parse(json, decoders.message_content())
  |> should.be_ok
  |> should.equal(MessageContent(text: "hi", fragments: []))
}

pub fn message_content_without_fragments_field_test() {
  let json = "{\"text\":\"hi\"}"
  json.parse(json, decoders.message_content())
  |> should.be_ok
  |> should.equal(MessageContent(text: "hi", fragments: []))
}

// --- message_fragment ---

pub fn fragment_text_test() {
  let json =
    "{\"type\":\"text\",\"text\":\"hello\",\"cheermote\":null,\"emote\":null,\"mention\":null}"
  json.parse(json, decoders.message_fragment())
  |> should.be_ok
  |> should.equal(Text(text: "hello"))
}

pub fn fragment_emote_test() {
  let json =
    "{\"type\":\"emote\",\"text\":\"PogChamp\",\"emote\":{\"id\":\"305954156\",\"emote_set_id\":\"0\",\"owner_id\":\"12345\",\"format\":[\"static\"]},\"cheermote\":null,\"mention\":null}"
  json.parse(json, decoders.message_fragment())
  |> should.be_ok
  |> should.equal(Emote(text: "PogChamp", id: "305954156", set_id: "0"))
}

pub fn fragment_emote_missing_payload_test() {
  // Twitch has been observed sending emote-typed fragments with `emote: null`;
  // we should still produce an Emote with empty id/set_id rather than fail.
  let json =
    "{\"type\":\"emote\",\"text\":\"PogChamp\",\"emote\":null,\"cheermote\":null,\"mention\":null}"
  json.parse(json, decoders.message_fragment())
  |> should.be_ok
  |> should.equal(Emote(text: "PogChamp", id: "", set_id: ""))
}

pub fn fragment_mention_test() {
  let json =
    "{\"type\":\"mention\",\"text\":\"@alice\",\"mention\":{\"user_id\":\"42\",\"user_login\":\"alice\",\"user_name\":\"Alice\"},\"cheermote\":null,\"emote\":null}"
  json.parse(json, decoders.message_fragment())
  |> should.be_ok
  |> should.equal(Mention(text: "@alice", user_id: "42", user_login: "alice"))
}

pub fn fragment_cheermote_test() {
  let json =
    "{\"type\":\"cheermote\",\"text\":\"Cheer100\",\"cheermote\":{\"prefix\":\"Cheer\",\"bits\":100,\"tier\":1},\"emote\":null,\"mention\":null}"
  json.parse(json, decoders.message_fragment())
  |> should.be_ok
  |> should.equal(Cheermote(
    text: "Cheer100",
    prefix: "Cheer",
    bits: 100,
    tier: 1,
  ))
}

pub fn fragment_unknown_type_falls_back_to_text_test() {
  let json =
    "{\"type\":\"some_future_type\",\"text\":\"raw\",\"cheermote\":null,\"emote\":null,\"mention\":null}"
  json.parse(json, decoders.message_fragment())
  |> should.be_ok
  |> should.equal(Text(text: "raw"))
}

// --- chat_message integrates message_content + fragment_decoder ---

pub fn chat_message_with_mixed_fragments_test() {
  let json =
    "{\"broadcaster_user_id\":\"1\",\"broadcaster_user_login\":\"b\",\"chatter_user_id\":\"2\",\"chatter_user_login\":\"c\",\"message\":{\"text\":\"hi @alice PogChamp\",\"fragments\":["
    <> "{\"type\":\"text\",\"text\":\"hi \",\"cheermote\":null,\"emote\":null,\"mention\":null},"
    <> "{\"type\":\"mention\",\"text\":\"@alice\",\"mention\":{\"user_id\":\"42\",\"user_login\":\"alice\",\"user_name\":\"Alice\"},\"cheermote\":null,\"emote\":null},"
    <> "{\"type\":\"text\",\"text\":\" \",\"cheermote\":null,\"emote\":null,\"mention\":null},"
    <> "{\"type\":\"emote\",\"text\":\"PogChamp\",\"emote\":{\"id\":\"e1\",\"emote_set_id\":\"s1\"},\"cheermote\":null,\"mention\":null}"
    <> "]}}"

  let assert Ok(chat) = json.parse(json, decoders.chat_message())
  chat.message
  |> should.equal(
    MessageContent(text: "hi @alice PogChamp", fragments: [
      Text(text: "hi "),
      Mention(text: "@alice", user_id: "42", user_login: "alice"),
      Text(text: " "),
      Emote(text: "PogChamp", id: "e1", set_id: "s1"),
    ]),
  )
}

// --- subscription_id ---

pub fn subscription_id_test() {
  let json = "{\"id\":\"abc-123\",\"status\":\"enabled\"}"
  json.parse(json, decoders.subscription_id())
  |> should.be_ok
  |> should.equal("abc-123")
}
