package agenteditorcommons.impl;

import static java.util.Objects.requireNonNull;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

import com.fasterxml.jackson.databind.JsonNode;
import com.mendix.core.Core;
import com.mendix.extensibility.CustomBlobDocumentInfo;
import com.mendix.systemwideinterfaces.core.IContext;

import agentcommons.proxies.Agent;
import genaicommons.proxies.DeployedModel;
import genaicommons.proxies.Request;
import genaicommons.proxies.Response;

/**
 * A development servlet registered at /dev/preview_agent_suggestions that derives
 * improvement suggestions from a completed evaluation run.
 *
 * Register it at app startup with:
 *   Core.addDevelopmentServlet("preview_agent_suggestions", new AgentEditorGenerateSuggestionsServlet())
 *
 * POST /dev/preview_agent_suggestions
 * Body: { "documentId": "<uuid>", "payload": "{...}" }
 *   payload fields:
 *     results: array of { name, verdict, reason?, details? } — one entry per judged test case;
 *       details (for the first failed test cases only) holds { variables, responseText,
 *       toolsCalled: [{ name, isError, input?, output? }], description?, groundTruth? }, already
 *       truncated by the editor
 *     evaluatorDocumentId: optional string — the evaluator the run used; absent means the default
 *       evaluator (the agent's own model)
 * Response: { "suggestions": ["...", "..."] }
 *
 * Failed test cases with details are rendered with the agent's user prompt filled in with their
 * values; the agent's system prompt is sent once, unfilled, because that is what is improved.
 * An evaluator that cannot be loaded is reported as { status: "error", errorCode:
 * "EVALUATOR_UNAVAILABLE", message } with HTTP 200.
 */
public class AgentEditorGenerateSuggestionsServlet extends AbstractAgentDevServlet {

    private static final long serialVersionUID = 1L;

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        resp.setContentType("application/json");
        resp.setCharacterEncoding("UTF-8");

        try {
            JsonNode requestJson = parseRequestBody(req);

            String documentId = AgentDocumentUtils.getTextOrNull(requestJson, "documentId");
            requireNonNull(documentId, "Missing required field: documentId");

            JsonNode payload = parsePayload(requestJson);

            JsonNode resultsNode = payload.get("results");
            if (resultsNode == null || !resultsNode.isArray() || resultsNode.size() == 0) {
                throw new IllegalArgumentException("Missing or empty 'results' array in payload.");
            }

            String evaluatorDocumentId = AgentDocumentUtils.getTextOrNull(payload, "evaluatorDocumentId");

            IContext context = Core.createSystemContext();

            CustomBlobDocumentInfo agentCustomDocument = findAgentDocument(documentId);
            Agent agent = findAgentObject(context, agentCustomDocument);
            // Suggestions come from the model of the evaluator the run used.
            DeployedModel deployedModel = EvaluatorUtils.resolve(context, evaluatorDocumentId, agent).deployedModel();

            JsonNode agentContent = OBJECT_MAPPER.readTree(agentCustomDocument.content());
            String agentSystemPrompt = AgentDocumentUtils.getTextOrEmpty(agentContent, "systemPrompt");
            String agentUserPrompt = AgentDocumentUtils.getTextOrEmpty(agentContent, "userPrompt");
            String toolsContext = EvaluationUtils.buildToolsContext(agentContent, true);

            String userMessage = buildUserMessage(agentSystemPrompt, agentUserPrompt, toolsContext, resultsNode);

            Request request = new Request(context);
            request.setSystemPrompt(EvaluationPrompts.SUGGESTIONS_SYSTEM_PROMPT);
            request.set_AgentName(EvaluationUtils.TRACE_NAME_SUGGESTIONS);

            Response response = genaicommons.proxies.microflows.Microflows.chatCompletions_WithoutHistory(
                    context, deployedModel, userMessage, null, request);

            if (response == null) {
                throw new IllegalStateException("Suggestions model call returned no response.");
            }

            LOGGER.debug("Suggestions response: " + response.getResponseText());

            List<String> suggestions = parseSuggestions(response.getResponseText());

            resp.setStatus(HttpServletResponse.SC_OK);
            writeJson(resp, java.util.Map.of("suggestions", suggestions));

        } catch (EvaluatorUtils.EvaluatorUnavailableException e) {
            writeExpectedErrorResponse(resp, e, "Suggestions action", EvaluatorUtils.EVALUATOR_UNAVAILABLE_ERROR_CODE);
        } catch (Exception e) {
            writeErrorResponse(resp, e, "Suggestions action");
        }
    }

    private String buildUserMessage(String agentSystemPrompt, String agentUserPrompt,
            String toolsContext, JsonNode resultsNode) {
        StringBuilder sb = new StringBuilder();

        sb.append(String.format(EvaluationPrompts.AGENT_CONTEXT_TEMPLATE, agentSystemPrompt, agentUserPrompt));
        if (toolsContext != null && !toolsContext.isBlank()) {
            sb.append(toolsContext);
        }

        StringBuilder resultsText = new StringBuilder();
        for (int i = 0; i < resultsNode.size(); i++) {
            JsonNode result = resultsNode.get(i);
            String name = AgentDocumentUtils.getTextOrEmpty(result, "name");
            String verdict = AgentDocumentUtils.getTextOrEmpty(result, "verdict");
            String reason = AgentDocumentUtils.getTextOrNull(result, "reason");
            JsonNode details = result.get("details");

            if (details == null || !details.isObject()) {
                // Passing test cases, and failures beyond the detailed ones, are listed in one line.
                resultsText.append("- [").append(verdict.toUpperCase()).append("] ").append(name);
                if (reason != null && !reason.isBlank()) {
                    resultsText.append(" — ").append(reason);
                }
                resultsText.append("\n");
                continue;
            }

            resultsText.append("<FailedTestCase name=\"").append(name).append("\">\n");
            resultsText.append("<UserPrompt>\n")
                    .append(EvaluationUtils.fillVariables(agentUserPrompt, details.get("variables")))
                    .append("\n</UserPrompt>\n");
            appendBlock(resultsText, "TestIntent", AgentDocumentUtils.getTextOrNull(details, "description"));
            appendBlock(resultsText, "GroundTruth", AgentDocumentUtils.getTextOrNull(details, "groundTruth"));
            resultsText.append("<Response>\n").append(AgentDocumentUtils.getTextOrEmpty(details, "responseText"))
                    .append("\n</Response>\n");

            resultsText.append("<ToolsCalled>\n");
            JsonNode toolsCalled = details.get("toolsCalled");
            if (toolsCalled != null && toolsCalled.isArray()) {
                for (JsonNode tool : toolsCalled) {
                    resultsText.append("<ToolCall name=\"").append(AgentDocumentUtils.getTextOrEmpty(tool, "name"))
                            .append("\" isError=\"").append(tool.path("isError").asBoolean(false)).append("\">\n");
                    appendBlock(resultsText, "Input", AgentDocumentUtils.getTextOrNull(tool, "input"));
                    appendBlock(resultsText, "Output", AgentDocumentUtils.getTextOrNull(tool, "output"));
                    resultsText.append("</ToolCall>\n");
                }
            }
            resultsText.append("</ToolsCalled>\n");
            appendBlock(resultsText, "Reason", reason);
            resultsText.append("</FailedTestCase>\n");
        }

        sb.append(String.format(EvaluationPrompts.SUGGESTIONS_USER_MESSAGE_TEMPLATE,
                resultsNode.size(), resultsText.toString().stripTrailing()));
        return sb.toString();
    }

    private static void appendBlock(StringBuilder sb, String tag, String content) {
        if (content != null && !content.isBlank()) {
            sb.append("<").append(tag).append(">\n").append(content).append("\n</").append(tag).append(">\n");
        }
    }

    private List<String> parseSuggestions(String responseText) {
        try {
            String cleaned = responseText.strip();
            if (cleaned.startsWith("```")) {
                cleaned = cleaned.replaceAll("^```[a-zA-Z]*\\n?", "").replaceAll("\\n?```$", "").strip();
            }

            JsonNode parsed = OBJECT_MAPPER.readTree(cleaned);
            if (!parsed.isArray()) {
                LOGGER.warn("Suggestions response was not a JSON array. Raw: " + responseText);
                return List.of();
            }

            List<String> suggestions = new ArrayList<>();
            for (JsonNode item : parsed) {
                if (item.isTextual()) {
                    String text = item.asText().strip();
                    if (!text.isBlank()) {
                        suggestions.add(text);
                    }
                }
            }
            return suggestions;

        } catch (Exception e) {
            LOGGER.warn("Failed to parse suggestions response. Raw: " + responseText);
            return List.of();
        }
    }

}
