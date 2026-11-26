package agenteditorcommons.impl;

import java.util.List;
import java.util.UUID;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mendix.core.Core;
import com.mendix.core.CoreException;
import com.mendix.extensibility.CustomBlobDocumentInfo;
import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixObject;

import agentcommons.impl.AgentImpl;
import agentcommons.proxies.Agent;
import genaicommons.proxies.DeployedModel;

/**
 * Resolves the evaluator an evaluation call uses: the judge criteria and the model that does the
 * evaluation work (judging, improvement suggestions and prompt optimization).
 *
 * With no evaluator document id the default evaluator is used: the default criteria and the
 * agent's own deployed model. Otherwise the evaluator document is read from the running app's model
 * and its model resource and version are resolved to an imported DeployedModel.
 */
final class EvaluatorUtils {

    /** Error code returned to the editor when the run's evaluator or its model cannot be loaded. */
    static final String EVALUATOR_UNAVAILABLE_ERROR_CODE = "EVALUATOR_UNAVAILABLE";

    /** The evaluator type whose prompt holds the judge criteria and whose model judges. */
    private static final String LLM_AS_JUDGE_TYPE = "LLMAsJudge";

    private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();

    private EvaluatorUtils() {
    }

    /** The judge criteria and the model of the evaluator a call uses. */
    record ResolvedEvaluator(String criteria, DeployedModel deployedModel) {
    }

    /** The run's evaluator document or its model could not be loaded by the running app. */
    static final class EvaluatorUnavailableException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        EvaluatorUnavailableException(String message) {
            super(message);
        }
    }

    static ResolvedEvaluator resolve(IContext context, String evaluatorDocumentId, Agent agent) throws CoreException {
        if (evaluatorDocumentId == null || evaluatorDocumentId.isBlank()) {
            DeployedModel agentModel = AgentImpl.getDeployedModel(agent);
            if (agentModel == null) {
                throw new IllegalStateException("Agent does not have a deployed model configured.");
            }
            return new ResolvedEvaluator(EvaluationPrompts.DEFAULT_EVALUATION_CRITERIA, agentModel);
        }

        CustomBlobDocumentInfo evaluatorDocument = findEvaluatorDocument(evaluatorDocumentId);
        String evaluatorName = evaluatorDocument.qualifiedDocumentName();

        JsonNode content;
        try {
            content = OBJECT_MAPPER.readTree(evaluatorDocument.content());
        } catch (Exception e) {
            throw new EvaluatorUnavailableException("Evaluator " + evaluatorName + " could not be read.");
        }

        // Other evaluator types need their own execution, so only the type this runtime knows is run.
        String type = AgentDocumentUtils.getTextOrNull(content, "type");
        if (type == null || type.isBlank()) {
            throw new EvaluatorUnavailableException("Evaluator " + evaluatorName + " has no type.");
        }
        if (!LLM_AS_JUDGE_TYPE.equals(type)) {
            throw new EvaluatorUnavailableException(
                    "Evaluator " + evaluatorName + " has an unsupported type: " + type + ".");
        }

        String prompt = AgentDocumentUtils.getTextOrNull(content, "prompt");
        if (prompt == null || prompt.isBlank()) {
            throw new EvaluatorUnavailableException("Evaluator " + evaluatorName + " has no prompt.");
        }

        return new ResolvedEvaluator(prompt, findDeployedModel(context, evaluatorName, content));
    }

    private static CustomBlobDocumentInfo findEvaluatorDocument(String evaluatorDocumentId) {
        CustomBlobDocumentInfo evaluatorDocument;
        try {
            evaluatorDocument = Core.extensibility().getCustomDocumentById(UUID.fromString(evaluatorDocumentId));
        } catch (IllegalArgumentException e) {
            evaluatorDocument = null;
        }
        if (evaluatorDocument == null) {
            throw new EvaluatorUnavailableException("The evaluator of this test set could not be found in the "
                    + "running app. Sync the app and try again.");
        }
        return evaluatorDocument;
    }

    /**
     * Finds the DeployedModel imported for the evaluator's model resource and model version. Model
     * documents are imported into DeployedModels at startup and on sync, whether or not an agent uses
     * them, so the evaluator's model is found even when no agent uses it.
     */
    private static DeployedModel findDeployedModel(IContext context, String evaluatorName, JsonNode content) {
        String modelDocumentId = AgentDocumentUtils.getTextOrNull(content.path("model"), "documentId");
        String selectedModelId = AgentDocumentUtils.getTextOrNull(content.path("selectedModel"), "id");
        if (modelDocumentId == null || selectedModelId == null) {
            throw new EvaluatorUnavailableException(
                    "Evaluator " + evaluatorName + " has no model resource or model version selected.");
        }

        List<IMendixObject> results = Core
                .createXPathQuery("//GenAICommons.DeployedModel[ModelDocumentID=$modelDocumentID][Model=$model]")
                .setVariable("modelDocumentID", modelDocumentId)
                .setVariable("model", selectedModelId)
                .setAmount(1)
                .execute(context);

        if (results.isEmpty() || results.get(0) == null) {
            throw new EvaluatorUnavailableException("The model of evaluator " + evaluatorName
                    + " could not be found in the running app. Sync the app and try again.");
        }
        return DeployedModel.initialize(context, results.get(0));
    }
}
