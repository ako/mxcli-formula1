package agenteditorcommons.impl;

import static java.util.Objects.requireNonNull;

import java.io.IOException;
import java.util.HashMap;
import java.util.Map;

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
 * A development servlet registered at /dev/preview_agent_evaluate that judges
 * the response the agent produced for one test case.
 *
 * Register it at app startup with:
 *   Core.addDevelopmentServlet("preview_agent_evaluate", new AgentEditorEvaluationServlet())
 *
 * POST /dev/preview_agent_evaluate
 * Body: { "documentId": "<uuid>", "payload": "{...}" }
 *   payload fields:
 *     testCase: { variables, responseText, toolsCalled: [{name, input?}], description?, groundTruth? }
 *     evaluatorDocumentId: optional string — the evaluator document whose prompt holds the judge
 *       criteria and whose model judges; absent means the default evaluator (default criteria and
 *       the agent's own deployed model)
 * Response: { "verdict": "pass"|"fail", "reason": "..." }
 *
 * The agent's system prompt and user prompt are sent to the judge with the test case's variable
 * values filled in, so the judge sees exactly what the agent received.
 *
 * The evaluator replaces the judge criteria only: the judge mechanics and the output contract are
 * fixed here. Unparseable output is retried once. If still unparseable after retry, an error
 * response is returned. An evaluator that cannot be loaded is reported as { status: "error",
 * errorCode: "EVALUATOR_UNAVAILABLE", message } with HTTP 200.
 */
public class AgentEditorEvaluationServlet extends AbstractAgentDevServlet {

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

            JsonNode testCaseNode = payload.get("testCase");
            if (testCaseNode == null || !testCaseNode.isObject()) {
                throw new IllegalArgumentException("Missing 'testCase' object in payload.");
            }

            String evaluatorDocumentId = AgentDocumentUtils.getTextOrNull(payload, "evaluatorDocumentId");

            IContext context = Core.createSystemContext();

            CustomBlobDocumentInfo agentCustomDocument = findAgentDocument(documentId);
            Agent agent = findAgentObject(context, agentCustomDocument);
            EvaluatorUtils.ResolvedEvaluator evaluator = EvaluatorUtils.resolve(context, evaluatorDocumentId, agent);
            DeployedModel deployedModel = evaluator.deployedModel();
            String systemPrompt = String.format(EvaluationPrompts.EVALUATION_SYSTEM_PROMPT_TEMPLATE, evaluator.criteria());

            JsonNode agentContent = OBJECT_MAPPER.readTree(agentCustomDocument.content());
            String agentSystemPrompt = AgentDocumentUtils.getTextOrEmpty(agentContent, "systemPrompt");
            String agentUserPrompt = AgentDocumentUtils.getTextOrEmpty(agentContent, "userPrompt");
            String toolsContext = EvaluationUtils.buildToolsContext(agentContent, true);

            JsonNode variables = testCaseNode.get("variables");
            String userMessage = buildUserMessage(
                    EvaluationUtils.fillVariables(agentSystemPrompt, variables),
                    EvaluationUtils.fillVariables(agentUserPrompt, variables),
                    toolsContext, testCaseNode);

            Request request = new Request(context);
            request.setSystemPrompt(systemPrompt);
            request.set_AgentName(EvaluationUtils.TRACE_NAME_EVALUATION);

            Map<String, Object> verdict = judgeWithRetry(context, deployedModel, systemPrompt, request, userMessage);

            resp.setStatus(HttpServletResponse.SC_OK);
            writeJson(resp, verdict);

        } catch (EvaluatorUtils.EvaluatorUnavailableException e) {
            writeExpectedErrorResponse(resp, e, "Evaluate action", EvaluatorUtils.EVALUATOR_UNAVAILABLE_ERROR_CODE);
        } catch (Exception e) {
            writeErrorResponse(resp, e, "Evaluate action");
        }
    }

    /**
     * Calls the judge model and retries once if the output cannot be parsed.
     * A failed second attempt throws, which surfaces as a 500 error to the caller.
     */
    private Map<String, Object> judgeWithRetry(IContext context, DeployedModel deployedModel, String systemPrompt,
            Request request, String userMessage) throws Exception {

        String responseText = callModel(context, deployedModel, request, userMessage);
        Map<String, Object> verdict = tryParseVerdict(responseText);
        if (verdict != null) {
            return verdict;
        }

        LOGGER.warn("Judge returned unparseable output on first attempt — retrying once. Raw output: " + responseText);

        Request retryRequest = new Request(context);
        retryRequest.setSystemPrompt(systemPrompt);
        retryRequest.set_AgentName(EvaluationUtils.TRACE_NAME_EVALUATION);
        String retryResponse = callModel(context, deployedModel, retryRequest, userMessage);
        verdict = tryParseVerdict(retryResponse);
        if (verdict != null) {
            return verdict;
        }

        LOGGER.error("Judge returned unparseable output after retry. Raw output: " + retryResponse);
        throw new IllegalStateException("Judge returned unparseable output after retry. Check the runtime logs.");
    }

    private String callModel(IContext context, DeployedModel deployedModel,
            Request request, String userMessage) {
        Response response = genaicommons.proxies.microflows.Microflows.chatCompletions_WithoutHistory(
                context, deployedModel, userMessage, null, request);
        if (response == null) {
            throw new IllegalStateException("Judge model call returned no response.");
        }
        LOGGER.debug("Judge response: " + response.getResponseText());
        return response.getResponseText();
    }

    /**
     * Attempts to parse the model's output as a single verdict object.
     * Returns null if parsing fails or the structure is invalid.
     * Raw output is never surfaced to the caller.
     */
    private Map<String, Object> tryParseVerdict(String responseText) {
        try {
            String cleaned = responseText.strip();
            if (cleaned.startsWith("```")) {
                cleaned = cleaned.replaceAll("^```[a-zA-Z]*\\n?", "").replaceAll("\\n?```$", "").strip();
            }

            JsonNode parsed = OBJECT_MAPPER.readTree(cleaned);
            if (!parsed.isObject()) {
                return null;
            }

            String verdict = AgentDocumentUtils.getTextOrNull(parsed, "verdict");
            String reason = AgentDocumentUtils.getTextOrNull(parsed, "reason");
            if (!"pass".equals(verdict) && !"fail".equals(verdict)) {
                return null;
            }

            Map<String, Object> result = new HashMap<>();
            result.put("verdict", verdict);
            result.put("reason", reason != null ? reason : "");
            return result;

        } catch (Exception e) {
            return null;
        }
    }

    private String buildUserMessage(String systemPrompt, String userPrompt, String toolsContext, JsonNode testCase) {
        StringBuilder sb = new StringBuilder();

        // 1. The agent's prompts as the agent received them, and its configuration
        sb.append("<SystemPrompt>\n").append(systemPrompt).append("\n</SystemPrompt>\n\n");
        sb.append("<UserPrompt>\n").append(userPrompt).append("\n</UserPrompt>\n\n");
        if (toolsContext != null && !toolsContext.isBlank()) {
            sb.append(toolsContext);
        }

        // 2. The test case — the judge mechanics and criteria are in the system prompt
        String description = AgentDocumentUtils.getTextOrNull(testCase, "description");
        if (description != null && !description.isBlank()) {
            sb.append("<TestIntent>\n").append(description).append("\n</TestIntent>\n\n");
        }

        String groundTruth = AgentDocumentUtils.getTextOrNull(testCase, "groundTruth");
        if (groundTruth != null && !groundTruth.isBlank()) {
            sb.append("<GroundTruth>\n").append(groundTruth).append("\n</GroundTruth>\n\n");
        }

        // 3. The agent's output
        sb.append("<Response>\n").append(AgentDocumentUtils.getTextOrEmpty(testCase, "responseText"))
                .append("\n</Response>\n\n");

        JsonNode toolsCalled = testCase.get("toolsCalled");
        sb.append("<ToolsCalled>\n");
        if (toolsCalled != null && toolsCalled.isArray()) {
            for (JsonNode tool : toolsCalled) {
                sb.append("<ToolCall name=\"").append(AgentDocumentUtils.getTextOrEmpty(tool, "name")).append("\">");
                String toolInput = AgentDocumentUtils.getTextOrNull(tool, "input");
                if (toolInput != null && !toolInput.isBlank()) {
                    sb.append("<Input>").append(toolInput).append("</Input>");
                }
                sb.append("</ToolCall>\n");
            }
        }
        sb.append("</ToolsCalled>\n\n");

        // 4. Output contract — LAST, so it cannot be displaced by any prior block or by the evaluator
        sb.append(EvaluationPrompts.EVALUATION_OUTPUT_CONTRACT);

        return sb.toString();
    }

}
