package agenteditorcommons.impl;

import static java.util.Objects.requireNonNull;

import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

import com.fasterxml.jackson.databind.JsonNode;
import com.mendix.core.Core;
import com.mendix.extensibility.CustomBlobDocumentInfo;
import com.mendix.systemwideinterfaces.core.IContext;

import agentcommons.impl.AgentImpl;
import agentcommons.proxies.Agent;
import genaicommons.proxies.DeployedModel;
import genaicommons.proxies.Request;
import genaicommons.proxies.Response;

/**
 * A development servlet registered at /dev/preview_agent_generate_test_data
 * that generates test cases for agent evaluation.
 *
 * Register it at app startup with:
 *   Core.addDevelopmentServlet("preview_agent_generate_test_data", new AgentEditorGenerateTestDataServlet())
 *
 * POST /dev/preview_agent_generate_test_data
 * Body: { "documentId": "<uuid>", "payload": "{\"variables\": [\"var1\"], \"numberOfTestCases\": 5, \"testDataInstructions\": \"optional subject matter\"}" }
 * Response: { "testCases": [ { "name": "...", "description": "...", "variables": { "var1": "value" } } ] }
 */
public class AgentEditorGenerateTestDataServlet extends AbstractAgentDevServlet {

    private static final long serialVersionUID = 1L;
    private static final int MAX_TEST_CASES = 10;

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        resp.setContentType("application/json");
        resp.setCharacterEncoding("UTF-8");

        try {
            JsonNode requestJson = parseRequestBody(req);

            String documentId = AgentDocumentUtils.getTextOrNull(requestJson, "documentId");
            requireNonNull(documentId, "Missing required field: documentId");

            JsonNode payload = parsePayload(requestJson);

            List<String> variables = parseVariableNames(payload);
            if (variables.isEmpty()) {
                throw new IllegalArgumentException("No variables provided. At least one variable name is required.");
            }

            int numberOfTestCases = payload.has("numberOfTestCases")
                    ? Math.min(Math.max(payload.get("numberOfTestCases").asInt(MAX_TEST_CASES), 1), MAX_TEST_CASES)
                    : MAX_TEST_CASES;

            String testDataInstructions = AgentDocumentUtils.getTextOrNull(payload, "testDataInstructions");

            IContext context = Core.createSystemContext();

            CustomBlobDocumentInfo agentCustomDocument = findAgentDocument(documentId);
            Agent agent = findAgentObject(context, agentCustomDocument);
            DeployedModel deployedModel = AgentImpl.getDeployedModel(agent);
            requireNonNull(deployedModel, "Agent does not have a deployed model configured.");

            JsonNode agentContent = OBJECT_MAPPER.readTree(agentCustomDocument.content());
            String agentSystemPrompt = AgentDocumentUtils.getTextOrEmpty(agentContent, "systemPrompt");
            String agentUserPrompt = AgentDocumentUtils.getTextOrEmpty(agentContent, "userPrompt");
            String toolsContext = EvaluationUtils.buildToolsContext(agentContent, false);

            String systemPrompt = String.format(EvaluationPrompts.GENERATOR_SYSTEM_PROMPT_TEMPLATE, numberOfTestCases);
            String userPrompt = buildUserPrompt(agentSystemPrompt, agentUserPrompt, toolsContext, testDataInstructions, numberOfTestCases, variables);

            Request request = new Request(context);
            request.setSystemPrompt(systemPrompt);
            request.set_AgentName(EvaluationUtils.TRACE_NAME_TEST_DATA_GENERATOR);

            List<Map<String, Object>> testCases = generateWithRetry(context, deployedModel, request, userPrompt, variables, numberOfTestCases);

            resp.setStatus(HttpServletResponse.SC_OK);
            writeJson(resp, Map.of("testCases", testCases));

        } catch (Exception e) {
            writeErrorResponse(resp, e, "Generate test data");
        }
    }

    private String buildUserPrompt(String agentSystemPrompt, String agentUserPrompt,
            String toolsContext, String testDataInstructions, int numberOfTestCases, List<String> variables) {
        StringBuilder sb = new StringBuilder();
        sb.append(String.format(EvaluationPrompts.GENERATOR_USER_PROMPT_BASE, agentSystemPrompt, agentUserPrompt));

        if (toolsContext != null && !toolsContext.isBlank()) {
            sb.append(toolsContext);
        }

        if (testDataInstructions != null && !testDataInstructions.isBlank()) {
            sb.append(String.format(EvaluationPrompts.GENERATOR_STEERING_BLOCK, testDataInstructions));
        }

        sb.append(String.format(EvaluationPrompts.GENERATOR_GENERATION_REQUEST,
                numberOfTestCases, String.join(", ", variables)));

        return sb.toString();
    }

    /**
     * Calls the generator model and retries once if the response cannot be parsed.
     */
    private List<Map<String, Object>> generateWithRetry(IContext context, DeployedModel deployedModel,
            Request request, String userPrompt, List<String> variables, int numberOfTestCases) throws Exception {

        String responseText = callModel(context, deployedModel, request, userPrompt);
        List<Map<String, Object>> result = tryParseGeneratedTestCases(responseText, variables, numberOfTestCases);
        if (result != null) {
            return result;
        }

        LOGGER.warn("Generator returned unparseable output on first attempt — retrying once. Raw output: " + responseText);

        Request retryRequest = new Request(context);
        retryRequest.setSystemPrompt(String.format(EvaluationPrompts.GENERATOR_SYSTEM_PROMPT_TEMPLATE, numberOfTestCases));
        retryRequest.set_AgentName(EvaluationUtils.TRACE_NAME_TEST_DATA_GENERATOR);
        String retryResponse = callModel(context, deployedModel, retryRequest, userPrompt);
        result = tryParseGeneratedTestCases(retryResponse, variables, numberOfTestCases);
        if (result != null) {
            return result;
        }

        LOGGER.error("Generator returned unparseable output after retry. Raw output: " + retryResponse);
        throw new IllegalStateException("Generator returned unparseable output after retry. Check the runtime logs.");
    }

    private String callModel(IContext context, DeployedModel deployedModel, Request request, String userPrompt) {
        Response response = genaicommons.proxies.microflows.Microflows.chatCompletions_WithoutHistory(
                context, deployedModel, userPrompt, null, request);
        if (response == null) {
            throw new IllegalStateException("LLM call returned no response.");
        }
        LOGGER.debug("Generated test data response: " + response.getResponseText());
        return response.getResponseText();
    }

    /**
     * Attempts to parse the model's output as a JSON array of test cases.
     * Returns null if the output cannot be parsed rather than throwing.
     */
    private List<Map<String, Object>> tryParseGeneratedTestCases(String responseText,
            List<String> expectedVariables, int numberOfTestCases) {
        try {
            return parseGeneratedTestCases(responseText, expectedVariables, numberOfTestCases);
        } catch (Exception e) {
            return null;
        }
    }

    private List<String> parseVariableNames(JsonNode payload) {
        JsonNode variablesNode = payload.get("variables");
        if (variablesNode == null || variablesNode.isNull() || !variablesNode.isArray()) {
            return List.of();
        }

        List<String> variables = new ArrayList<>();
        for (JsonNode element : variablesNode) {
            variables.add(element.asText());
        }
        return variables;
    }

    private List<Map<String, Object>> parseGeneratedTestCases(String responseText,
            List<String> expectedVariables, int numberOfTestCases) throws IOException {
        String cleaned = responseText.strip();

        if (cleaned.startsWith("```")) {
            cleaned = cleaned.replaceAll("^```[a-zA-Z]*\\n?", "").replaceAll("\\n?```$", "").strip();
        }

        // Extract the JSON array by boundaries in case the model wrapped it in extra text
        int arrayStart = cleaned.indexOf('[');
        int arrayEnd = cleaned.lastIndexOf(']');
        if (arrayStart != -1 && arrayEnd > arrayStart) {
            cleaned = cleaned.substring(arrayStart, arrayEnd + 1);
        }

        JsonNode parsed = OBJECT_MAPPER.readTree(cleaned);
        if (!parsed.isArray()) {
            throw new IllegalStateException("LLM did not return a valid JSON array. Response: " + responseText);
        }

        List<Map<String, Object>> testCases = new ArrayList<>();
        for (JsonNode item : parsed) {
            if (!item.isObject()) {
                continue;
            }

            Map<String, Object> testCase = new HashMap<>();
            testCase.put("name", item.has("name") && !item.get("name").isNull() ? item.get("name").asText() : "");
            testCase.put("description", item.has("description") && !item.get("description").isNull() ? item.get("description").asText() : "");

            Map<String, String> variableValues = new HashMap<>();
            JsonNode variablesNode = item.get("variables");
            if (variablesNode != null && variablesNode.isObject()) {
                for (String key : expectedVariables) {
                    JsonNode value = variablesNode.get(key);
                    variableValues.put(key, value != null && !value.isNull() ? value.asText() : "");
                }
            } else {
                // Flat object fallback: tolerate the old response shape where variables were top-level keys
                for (String key : expectedVariables) {
                    JsonNode value = item.get(key);
                    variableValues.put(key, value != null && !value.isNull() ? value.asText() : "");
                }
            }
            testCase.put("variables", variableValues);

            testCases.add(testCase);

            if (testCases.size() >= numberOfTestCases) {
                break;
            }
        }

        return testCases;
    }
}
