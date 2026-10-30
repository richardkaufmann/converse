namespace Converse.Core;

public static class SwitchboardInstructions
{
    public const string ConversationPolicy = "Switchboard: interpret “tell <session> <message>” as a one-way tell; no reply or receipt turn is requested. Interpret “ask <session> <question>” as ask: a correlated answer, blocker, or decline is expected. A transport acknowledgement is not an answer. Use exact IDs from list-sessions. Commands execute only as the ENTIRE final reply in a converse JSON fence: {\"command\":\"ask\",\"to\":\"ID\",\"text\":\"question\"} (use command tell for one-way messages). Reply to a request with tell and inReplyTo set to its request UUID; do not ask merely to acknowledge receipt. Legacy tell with replyExpected:true also requests an answer.";
    public static string WithPolicy(ChatSession session, string prompt) => session.MessagingEnabled && session.Agent is null
        ? prompt + "\n[" + ConversationPolicy + "]" : prompt;
}
