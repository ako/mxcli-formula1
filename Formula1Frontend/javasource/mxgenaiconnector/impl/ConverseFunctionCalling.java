

package mxgenaiconnector.impl;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonMappingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.mendix.core.CoreException;
import com.mendix.systemwideinterfaces.core.IContext;
import genaicommons.proxies.ENUM_MessageRole;

import genaicommons.proxies.Request;



public class ConverseFunctionCalling{

	private static final ObjectMapper MAPPER = new ObjectMapper();

	//........Handle ToolCall and ToolResult........

	//All Messages of type Tool need to be mapped to a ToolResult ContentBlock as role "user"
	public static void mapToolResult(ArrayNode messageList, int i,IContext context, Request request) throws JsonMappingException, JsonProcessingException, CoreException {
		JsonNode current = (i >= 0 && i < messageList.size()) ? messageList.get(i) : null;
		if (current == null || !current.isObject()) {
			return;
		}

		// A tool-role message is a tool RESULT, consumed by getToolResultBlock() below. It must keep its
		// toolCallId until then, so it must never be passed to setAssistantToolUse (which strips that
		// field) even though it also carries its own (normally empty) toolCalls array.
		if (!isToolMessage(current)) {
			setAssistantToolUse((ObjectNode) current);
			return;
		}

		//Get the assistant message right before the tool messages and populate it with the original json from the response
		JsonNode issuer = (i > 0) ? messageList.get(i - 1) : null;
		if (issuer != null && issuer.isObject()) {
			setAssistantToolUse((ObjectNode) issuer);
		}

		//Add Content of toolResult to Content for all subsequent tool messages
		ArrayNode newContent = MAPPER.createArrayNode();
		while (i < messageList.size() && isToolMessage(messageList.get(i))) {
			newContent.add(getToolResultBlock(messageList.get(i)));
			//"tool" message no longer needed; the next one shifts down into this index
			messageList.remove(i);
		}

		ObjectNode newUserMessage = MAPPER.createObjectNode();
		newUserMessage.put("role", ENUM_MessageRole.user.toString());
		newUserMessage.set("content", newContent);

		//ArrayNode.insert appends when the index is at or past the end of the array.
		messageList.insert(i, newUserMessage);
	}

	//Transform a GenAICommons "tool" message to a Converse "ToolResultBlock"
	private static ObjectNode getToolResultBlock(JsonNode toolMessage) throws CoreException {
		// Resolve the id BEFORE anything else touches the message: an absent/blank field must fail
		// loudly here rather than silently becoming "" in the outgoing toolResult.
		String toolUseId = toolMessage.path("toolCallId").asText("");
		if (toolUseId.isBlank()) {
			throw new CoreException("Cannot map tool result to Converse: message with role 'tool' has no "
					+ "toolCallId. Every toolResult must echo the toolUseId of the toolUse it answers. "
					+ describe(toolMessage));
		}

		ObjectNode result = MAPPER.createObjectNode();
		result.put("result", firstTextBlock(toolMessage.path("content")));
		ObjectNode contentItem = MAPPER.createObjectNode();
        contentItem.set("json", result);

        ArrayNode contentArray = MAPPER.createArrayNode();
        contentArray.add(contentItem);

        ObjectNode toolResult = MAPPER.createObjectNode();
        toolResult.put("toolUseId", toolUseId);
        toolResult.set("content", contentArray);

        ObjectNode toolResultWrapper = MAPPER.createObjectNode();
        toolResultWrapper.set("toolResult", toolResult);

		return toolResultWrapper;
	}

	//Text of the first text block in a content array, or "" when there is none (does not assume index 0).
	private static String firstTextBlock(JsonNode contentArray) {
		if (contentArray != null && contentArray.isArray()) {
			for (JsonNode contentNode : contentArray) {
				if (contentNode != null && contentNode.hasNonNull("text")) {
					return contentNode.path("text").asText();
				}
			}
		}
		return "";
	}

	//The "tool" role is only applicable for tool results that haven't been mapped yet to Converse nodes.
	private static boolean isToolMessage(JsonNode messageNode) {
		return (!(messageNode.path("role").isNull()) && messageNode.path("role").asText().equals(ENUM_MessageRole.tool.toString()));
	}

	//Map toolCalls on a message into Converse toolUse blocks inside the message content.
	private static void setAssistantToolUse(ObjectNode messageNode) throws JsonMappingException, JsonProcessingException, CoreException {
		if (messageNode == null) {
			return;
		}
		// Defence in depth: a tool result carries no invocations of its own to map here.
		if (isToolMessage(messageNode)) {
			return;
		}
		JsonNode toolCallsNode = messageNode.path("toolCalls");
		if (!toolCallsNode.isArray() || toolCallsNode.isEmpty()) {
			return;
		}
		ArrayNode contentArray = messageNode.has("content") && messageNode.get("content").isArray()
				? (ArrayNode) messageNode.get("content")
				: MAPPER.createArrayNode();

		for (JsonNode toolCall : toolCallsNode) {
			ObjectNode toolUseNode = MAPPER.createObjectNode();
			String toolUseId = resolveToolUseId(messageNode, toolCall, toolCallsNode.size());
			if (toolUseId.isBlank()) {
				throw new CoreException("Cannot map toolUse to Converse: no toolUseId for tool '"
						+ toolCall.path("name").asText("<unnamed>") + "'. " + describe(messageNode));
			}
			toolUseNode.put("toolUseId", toolUseId);
			if (toolCall.has("name")) {
				toolUseNode.put("name", toolCall.path("name").asText());
			}
			JsonNode inputNode = toolCall.get("input");
			if (inputNode != null && !inputNode.isNull()) {
				JsonNode inputToUse = inputNode;
				if (inputNode.isTextual()) {
					String inputText = inputNode.asText();
					try {
						inputToUse = MAPPER.readTree(inputText);
					} catch (Exception e) {
						ObjectNode wrappedInput = MAPPER.createObjectNode();
						wrappedInput.put("value", inputText);
						inputToUse = wrappedInput;
					}
				}
				toolUseNode.set("input", inputToUse);
			}
			ObjectNode toolUseWrapper = MAPPER.createObjectNode();
			toolUseWrapper.set("toolUse", toolUseNode);
			contentArray.add(toolUseWrapper);
		}
		removeEmptyTextBlocks(contentArray);
		messageNode.set("content", contentArray);
		messageNode.remove("toolCalls");
		messageNode.remove("toolCallId");
	}

	//Message-level toolCallId is only a legitimate id source when there is exactly one call on the
	//message; with several calls it could only contribute an id belonging to a different invocation.
	private static String resolveToolUseId(ObjectNode messageNode, JsonNode toolCall, int toolCallCount) {
		String toolUseId = toolCall.has("toolUseId") ? toolCall.path("toolUseId").asText() : "";
		if (toolUseId.isBlank()) {
			toolUseId = toolCall.has("toolCallId") ? toolCall.path("toolCallId").asText() : "";
		}
		if (toolUseId.isBlank() && toolCallCount == 1) {
			toolUseId = messageNode.has("toolCallId") ? messageNode.path("toolCallId").asText() : "";
		}
		return toolUseId;
	}

	private static void removeEmptyTextBlocks(ArrayNode contentArray) {
		int i = 0;
		while (i < contentArray.size()) {
			JsonNode contentNode = contentArray.get(i);
			boolean emptyObject = contentNode != null && contentNode.isObject() && contentNode.isEmpty();
			boolean blankText = contentNode != null
					&& contentNode.has("text")
					&& contentNode.get("text").isTextual()
					&& contentNode.get("text").asText().isBlank();
			if (emptyObject || blankText) {
				contentArray.remove(i);
			}
			else {
				i++;
			}
		}
	}

	//Structural facts only (role + field names), no message content, for use in thrown error messages.
	private static String describe(JsonNode messageNode) {
		StringBuilder fields = new StringBuilder();
		messageNode.fieldNames().forEachRemaining(name -> fields.append(fields.length() == 0 ? "" : ", ").append(name));
		return "Message role='" + messageNode.path("role").asText("<none>") + "', fields=[" + fields + "].";
	}
}