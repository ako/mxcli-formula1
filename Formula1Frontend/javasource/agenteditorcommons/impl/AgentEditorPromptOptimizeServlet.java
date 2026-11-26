package agenteditorcommons.impl;

import static java.util.Objects.requireNonNull;

import java.io.IOException;
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
 * A development servlet registered at /dev/preview_agent_optimize that rewrites
 * an agent's system prompt based on a selected subset of evaluation suggestions.
 *
 * Register it at app startup with:
 *   Core.addDevelopmentServlet("preview_agent_optimize", new AgentEditorPromptOptimizeServlet())
 *
 * POST /dev/preview_agent_optimize
 * Body: { "documentId": "<uuid>", "systemPrompt": "...", "suggestions": "[\"...\", \"...\"]",
 *         "evaluatorDocumentId": "<uuid>" (optional) }
 * Response: { "systemPrompt": "..." }
 *
 * The rewrite uses the model of the evaluator given, or the agent's own model when none is given.
 * An evaluator that cannot be loaded is reported as { status: "error", errorCode:
 * "EVALUATOR_UNAVAILABLE", message } with HTTP 200.
 */
public class AgentEditorPromptOptimizeServlet extends AbstractAgentDevServlet {

    private static final long serialVersionUID = 1L;

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        resp.setContentType("application/json");
        resp.setCharacterEncoding("UTF-8");

        try {
            JsonNode requestJson = parseRequestBody(req);

            String documentId = AgentDocumentUtils.getTextOrNull(requestJson, "documentId");
            requireNonNull(documentId, "Missing required field: documentId");

            String currentSystemPrompt = AgentDocumentUtils.getTextOrNull(requestJson, "systemPrompt");
            if (currentSystemPrompt == null) currentSystemPrompt = "";

            String suggestionsJson = AgentDocumentUtils.getTextOrNull(requestJson, "suggestions");
            requireNonNull(suggestionsJson, "Missing required field: suggestions");

            JsonNode suggestionsArray = OBJECT_MAPPER.readTree(suggestionsJson);
            if (!suggestionsArray.isArray() || suggestionsArray.isEmpty()) {
                throw new IllegalArgumentException("suggestions must be a non-empty JSON array.");
            }

            StringBuilder suggestionsList = new StringBuilder();
            int index = 1;
            for (JsonNode suggestion : suggestionsArray) {
                suggestionsList.append(index).append(". ").append(suggestion.asText()).append("\n");
                index++;
            }

            String evaluatorDocumentId = AgentDocumentUtils.getTextOrNull(requestJson, "evaluatorDocumentId");

            IContext context = Core.createSystemContext();

            CustomBlobDocumentInfo agentCustomDocument = findAgentDocument(documentId);
            Agent agent = findAgentObject(context, agentCustomDocument);
            // The rewrite comes from the model of the evaluator selected when Optimize was pressed.
            DeployedModel deployedModel = EvaluatorUtils.resolve(context, evaluatorDocumentId, agent).deployedModel();

            JsonNode agentContent = OBJECT_MAPPER.readTree(agentCustomDocument.content());
            String toolsContext = EvaluationUtils.buildToolsContext(agentContent, false);
            String toolsSection = toolsContext != null ? toolsContext : "";

            boolean hasExistingPrompt = !currentSystemPrompt.isBlank();
            String systemPrompt = hasExistingPrompt
                    ? EvaluationPrompts.OPTIMIZE_SYSTEM_PROMPT
                    : EvaluationPrompts.OPTIMIZE_SYSTEM_PROMPT_CREATE;
            String userPrompt = hasExistingPrompt
                    ? String.format(EvaluationPrompts.OPTIMIZE_USER_PROMPT_TEMPLATE, currentSystemPrompt, toolsSection, suggestionsList.toString())
                    : String.format(EvaluationPrompts.OPTIMIZE_USER_PROMPT_CREATE, toolsSection, suggestionsList.toString());

            Request request = new Request(context);
            request.setSystemPrompt(systemPrompt);
            request.set_AgentName(EvaluationUtils.TRACE_NAME_PROMPT_OPTIMIZER);

            Response response = genaicommons.proxies.microflows.Microflows.chatCompletions_WithoutHistory(
                    context, deployedModel, userPrompt, null, request);

            if (response == null) {
                throw new IllegalStateException("LLM call returned no response.");
            }

            String optimizedPrompt = response.getResponseText().strip();
            LOGGER.debug("Optimized system prompt: " + optimizedPrompt);

            resp.setStatus(HttpServletResponse.SC_OK);
            writeJson(resp, Map.of("systemPrompt", optimizedPrompt));

        } catch (EvaluatorUtils.EvaluatorUnavailableException e) {
            writeExpectedErrorResponse(resp, e, "Prompt optimization", EvaluatorUtils.EVALUATOR_UNAVAILABLE_ERROR_CODE);
        } catch (Exception e) {
            writeErrorResponse(resp, e, "Prompt optimization");
        }
    }

}
