import gleam/json
import gleam/option.{None, Some}
import gleeunit/should
import internal/decoders
import types.{
  Badge, Cheer, Cheermote, Emote, Mention, MessageContent, Reply, Text,
}

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
  |> should.equal(
    Emote(
      text: "PogChamp",
      id: "305954156",
      set_id: "0",
      owner_id: "12345",
      format: ["static"],
    ),
  )
}

pub fn fragment_emote_missing_payload_test() {
  // Twitch has been observed sending emote-typed fragments with `emote: null`;
  // we should still produce an Emote with empty id/set_id rather than fail.
  let json =
    "{\"type\":\"emote\",\"text\":\"PogChamp\",\"emote\":null,\"cheermote\":null,\"mention\":null}"
  json.parse(json, decoders.message_fragment())
  |> should.be_ok
  |> should.equal(
    Emote(text: "PogChamp", id: "", set_id: "", owner_id: "", format: []),
  )
}

pub fn fragment_mention_test() {
  let json =
    "{\"type\":\"mention\",\"text\":\"@alice\",\"mention\":{\"user_id\":\"42\",\"user_login\":\"alice\",\"user_name\":\"Alice\"},\"cheermote\":null,\"emote\":null}"
  json.parse(json, decoders.message_fragment())
  |> should.be_ok
  |> should.equal(Mention(
    text: "@alice",
    user_id: "42",
    user_login: "alice",
    user_name: "Alice",
  ))
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
      Mention(
        text: "@alice",
        user_id: "42",
        user_login: "alice",
        user_name: "Alice",
      ),
      Text(text: " "),
      Emote(text: "PogChamp", id: "e1", set_id: "s1", owner_id: "", format: []),
    ]),
  )
}

// --- chat_message field-level tests ---

pub fn chat_message_full_payload_test() {
  let json =
    "{\"broadcaster_user_id\":\"1\",\"broadcaster_user_login\":\"b\",\"broadcaster_user_name\":\"Broadcaster\",\"chatter_user_id\":\"2\",\"chatter_user_login\":\"c\",\"chatter_user_name\":\"Chatter\",\"message_id\":\"m-1\",\"message_type\":\"text\",\"message\":{\"text\":\"hi\",\"fragments\":[]},\"color\":\"#FF0000\",\"badges\":[{\"set_id\":\"broadcaster\",\"id\":\"1\",\"info\":\"\"},{\"set_id\":\"subscriber\",\"id\":\"12\",\"info\":\"30\"}],\"cheer\":null,\"reply\":null,\"channel_points_custom_reward_id\":null,\"source_broadcaster_user_id\":null}"

  let assert Ok(chat) = json.parse(json, decoders.chat_message())
  chat.broadcaster_user_name |> should.equal("Broadcaster")
  chat.chatter_user_name |> should.equal("Chatter")
  chat.message_id |> should.equal("m-1")
  chat.message_type |> should.equal("text")
  chat.color |> should.equal("#FF0000")
  chat.badges
  |> should.equal([
    Badge(set_id: "broadcaster", id: "1", info: ""),
    Badge(set_id: "subscriber", id: "12", info: "30"),
  ])
  chat.cheer |> should.equal(None)
  chat.reply |> should.equal(None)
  chat.channel_points_custom_reward_id |> should.equal(None)
  chat.source_broadcaster_user_id |> should.equal(None)
}

pub fn chat_message_with_cheer_test() {
  let json =
    "{\"broadcaster_user_id\":\"1\",\"broadcaster_user_login\":\"b\",\"chatter_user_id\":\"2\",\"chatter_user_login\":\"c\",\"message\":{\"text\":\"Cheer100\",\"fragments\":[]},\"cheer\":{\"bits\":100}}"

  let assert Ok(chat) = json.parse(json, decoders.chat_message())
  chat.cheer |> should.equal(Some(Cheer(bits: 100)))
}

pub fn chat_message_with_reply_test() {
  let json =
    "{\"broadcaster_user_id\":\"1\",\"broadcaster_user_login\":\"b\",\"chatter_user_id\":\"2\",\"chatter_user_login\":\"c\",\"message\":{\"text\":\"@alice ok\",\"fragments\":[]},\"reply\":{\"parent_message_id\":\"p-1\",\"parent_message_body\":\"hi\",\"parent_user_id\":\"42\",\"parent_user_login\":\"alice\",\"parent_user_name\":\"Alice\",\"thread_message_id\":\"t-1\",\"thread_user_id\":\"42\",\"thread_user_login\":\"alice\",\"thread_user_name\":\"Alice\"}}"

  let assert Ok(chat) = json.parse(json, decoders.chat_message())
  chat.reply
  |> should.equal(
    Some(Reply(
      parent_message_id: "p-1",
      parent_message_body: "hi",
      parent_user_id: "42",
      parent_user_login: "alice",
      parent_user_name: "Alice",
      thread_message_id: "t-1",
      thread_user_id: "42",
      thread_user_login: "alice",
      thread_user_name: "Alice",
    )),
  )
}

pub fn chat_message_with_custom_reward_test() {
  let json =
    "{\"broadcaster_user_id\":\"1\",\"broadcaster_user_login\":\"b\",\"chatter_user_id\":\"2\",\"chatter_user_login\":\"c\",\"message\":{\"text\":\"redeemed\",\"fragments\":[]},\"channel_points_custom_reward_id\":\"reward-uuid\"}"

  let assert Ok(chat) = json.parse(json, decoders.chat_message())
  chat.channel_points_custom_reward_id |> should.equal(Some("reward-uuid"))
}

pub fn chat_message_with_shared_chat_source_test() {
  let json =
    "{\"broadcaster_user_id\":\"1\",\"broadcaster_user_login\":\"b\",\"chatter_user_id\":\"2\",\"chatter_user_login\":\"c\",\"message\":{\"text\":\"hi\",\"fragments\":[]},\"source_broadcaster_user_id\":\"99\",\"source_broadcaster_user_login\":\"otherchannel\",\"source_broadcaster_user_name\":\"OtherChannel\",\"source_message_id\":\"src-msg-1\",\"source_badges\":[{\"set_id\":\"vip\",\"id\":\"1\",\"info\":\"\"}]}"

  let assert Ok(chat) = json.parse(json, decoders.chat_message())
  chat.source_broadcaster_user_id |> should.equal(Some("99"))
  chat.source_broadcaster_user_login |> should.equal(Some("otherchannel"))
  chat.source_broadcaster_user_name |> should.equal(Some("OtherChannel"))
  chat.source_message_id |> should.equal(Some("src-msg-1"))
  chat.source_badges
  |> should.equal(Some([Badge(set_id: "vip", id: "1", info: "")]))
}

// --- subscription_id ---

pub fn subscription_id_test() {
  let json = "{\"id\":\"abc-123\",\"status\":\"enabled\"}"
  json.parse(json, decoders.subscription_id())
  |> should.be_ok
  |> should.equal("abc-123")
}
