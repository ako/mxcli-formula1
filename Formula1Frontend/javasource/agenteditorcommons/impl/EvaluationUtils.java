package agenteditorcommons.impl;

import java.util.Map;
import java.util.regex.Pattern;

import com.fasterxml.jackson.databind.JsonNode;

/**
 * Shared utility methods for the agent evaluation servlets.
 */
final class EvaluationUtils {

    private EvaluationUtils() {}

    // Agent names set on the GenAICommons Request (_AgentName) so the evaluation calls are told
    // apart in the trace overview instead of all showing as a plain LLM call.
    static final String TRACE_NAME_EVALUATION = "Agent evaluation";
    static final String TRACE_NAME_SUGGESTIONS = "Evaluation suggestions";
    static final String TRACE_NAME_TEST_DATA_GENERATOR = "Test case generation";
    static final String TRACE_NAME_PROMPT_OPTIMIZER = "Prompt optimization";

    /**
     * Fills each {{variable}} in an agent prompt with the test case's value for it. A variable the
     * test case leaves empty, or does not supply, becomes empty text, as it is for the agent's run.
     */
    static String fillVariables(String prompt, JsonNode variables) {
        String filled = prompt;
        if (variables != null && variables.isObject()) {
            for (Map.Entry<String, JsonNode> entry : variables.properties()) {
                filled = filled.replace("{{" + entry.getKey() + "}}", entry.getValue().asText(""));
            }
        }
        return VARIABLE_PLACEHOLDER.matcher(filled).replaceAll("");
    }

    // Same pattern the editor uses to find prompt variables.
    private static final Pattern VARIABLE_PLACEHOLDER = Pattern.compile("\\{\\{[^}\\s{]+\\}\\}");

    /**
     * Reads the agent's configured tools and knowledge bases from the document blob and formats
     * them as separate context sections for use in prompts. Returns null when none are configured.
     *
     * @param agentContent    the parsed agent document blob
     * @param includeDisabled when true, both enabled and disabled tools are included with an
     *                        [enabled]/[disabled] label — used by the judge and suggestions prompts
     *                        so they can reason about correct tool usage. When false, only enabled
     *                        tools are included without a label — used by the generator so it
     *                        produces test cases for the agent's active capabilities only.
     */
    static String buildToolsContext(JsonNode agentContent, boolean includeDisabled) {
        JsonNode toolsNode = agentContent.get("tools");
        JsonNode kbToolsNode = agentContent.get("knowledgebaseTools");

        StringBuilder toolList = new StringBuilder();
        if (toolsNode != null && toolsNode.isArray()) {
            for (JsonNode tool : toolsNode) {
                JsonNode enabledNode = tool.get("enabled");
                boolean enabled = enabledNode == null || enabledNode.asBoolean(true);
                if (!includeDisabled && !enabled) continue;

                String name = AgentDocumentUtils.getTextOrEmpty(tool, "name");
                // MCP tools store name as empty — the display name is the local part of the linked document's qualified name
                if (name.isBlank()) {
                    JsonNode documentNode = tool.get("document");
                    if (documentNode != null && documentNode.isObject()) {
                        String qualifiedName = AgentDocumentUtils.getTextOrEmpty(documentNode, "qualifiedName");
                        String[] parts = qualifiedName.split("\\.");
                        name = parts[parts.length - 1];
                    }
                }
                String description = AgentDocumentUtils.getTextOrEmpty(tool, "description");
                String toolType = AgentDocumentUtils.getTextOrEmpty(tool, "toolType");

                toolList.append("  - ").append(name).append(" [").append(toolType);
                if (includeDisabled) {
                    toolList.append(", ").append(enabled ? "enabled" : "disabled");
                }
                toolList.append("]");
                if (!description.isBlank()) {
                    toolList.append(": ").append(description);
                }
                toolList.append("\n");
            }
        }

        StringBuilder kbList = new StringBuilder();
        if (kbToolsNode != null && kbToolsNode.isArray()) {
            for (JsonNode tool : kbToolsNode) {
                JsonNode enabledNode = tool.get("enabled");
                boolean enabled = enabledNode == null || enabledNode.asBoolean(true);
                if (!includeDisabled && !enabled) continue;

                String name = AgentDocumentUtils.getTextOrEmpty(tool, "name");
                String description = AgentDocumentUtils.getTextOrEmpty(tool, "description");

                kbList.append("  - ").append(name);
                if (includeDisabled) {
                    kbList.append(" [").append(enabled ? "enabled" : "disabled").append("]");
                }
                if (!description.isBlank()) {
                    kbList.append(": ").append(description);
                }
                kbList.append("\n");
            }
        }

        if (toolList.isEmpty() && kbList.isEmpty()) {
            return null;
        }

        StringBuilder result = new StringBuilder();
        if (!toolList.isEmpty()) {
            String toolChoice = AgentDocumentUtils.getTextOrEmpty(agentContent, "toolChoice");
            if (toolChoice.isBlank()) toolChoice = "Auto";
            result.append(String.format(EvaluationPrompts.TOOLS_CONTEXT_TEMPLATE, toolChoice, toolList.toString().stripTrailing()));
        }
        if (!kbList.isEmpty()) {
            result.append(String.format(EvaluationPrompts.KB_CONTEXT_TEMPLATE, kbList.toString().stripTrailing()));
        }
        return result.toString();
    }
}
