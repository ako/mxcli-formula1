package agenteditorcommons.impl;

import static java.util.Objects.requireNonNull;

import java.io.IOException;
import java.io.PrintWriter;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Collectors;

import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mendix.core.Core;
import com.mendix.extensibility.CustomBlobDocumentInfo;
import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixObject;

import agentcommons.proxies.Agent;

/**
 * Base class for the /dev/preview_agent_* development servlets, holding the
 * request-parsing and agent-lookup logic shared by all of them.
 */
public abstract class AbstractAgentDevServlet extends HttpServlet {

    private static final long serialVersionUID = 1L;
    protected static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();

    protected final MxLogger LOGGER;

    protected AbstractAgentDevServlet() {
        this.LOGGER = new MxLogger(getClass());
    }

    protected JsonNode parseRequestBody(HttpServletRequest req) throws IOException {
        String body = req.getReader().lines().collect(Collectors.joining());
        JsonNode requestJson = OBJECT_MAPPER.readTree(body);
        LOGGER.debug("Received request: " + requestJson.toString());
        return requestJson;
    }

    protected JsonNode parsePayload(JsonNode requestJson) throws IOException {
        JsonNode payloadNode = requestJson.get("payload");
        requireNonNull(payloadNode, "Missing required field: payload");
        String payloadJson = payloadNode.isTextual() ? payloadNode.asText() : payloadNode.toString();
        return OBJECT_MAPPER.readTree(payloadJson);
    }

    protected CustomBlobDocumentInfo findAgentDocument(String documentId) {
        UUID documentUUID = UUID.fromString(documentId);
        CustomBlobDocumentInfo customBlobDocument = Core.extensibility().getCustomDocumentById(documentUUID);
        requireNonNull(customBlobDocument, "Agent document not found for ID: " + documentId);
        return customBlobDocument;
    }

    protected Agent findAgentObject(IContext context, CustomBlobDocumentInfo agentCustomDocument) {
        List<IMendixObject> results = Core.createXPathQuery("//AgentCommons.Agent[ModelDocumentID=$documentID]")
                .setVariable("documentID", agentCustomDocument.documentID().toString())
                .setAmount(1)
                .execute(context);

        if (results.isEmpty() || results.get(0) == null) {
            throw new IllegalStateException(
                    "Agent " + agentCustomDocument.qualifiedDocumentName()
                            + " object does not exist in the database. Make sure the agent has been imported first.");
        }
        return Agent.initialize(context, results.get(0));
    }

    /**
     * Writes a JSON response body. Servlets open the writer only here, after their work is done, so
     * that an exception thrown while working leaves the response uncommitted and the error response
     * can still set its status and body.
     */
    protected void writeJson(HttpServletResponse resp, Object body) throws IOException {
        try (PrintWriter out = resp.getWriter()) {
            out.write(OBJECT_MAPPER.writeValueAsString(body));
        }
    }

    /**
     * Logs the failure and writes a standard { status, message } JSON error response with HTTP 500.
     * actionLabel is used both for the log line and as the fallback message text.
     */
    protected void writeErrorResponse(HttpServletResponse resp, Exception e, String actionLabel) throws IOException {
        LOGGER.error(actionLabel + " failed. ", e);
        resp.setStatus(HttpServletResponse.SC_INTERNAL_SERVER_ERROR);
        writeJson(resp, errorBody(e, actionLabel, null));
    }

    /**
     * Writes an expected error the editor acts on, as { status, message, errorCode }. It is sent with
     * HTTP 200 so the editor always receives the body: the editor reads such errors from the
     * response, while a failed preview action call only reaches it as a generic error.
     */
    protected void writeExpectedErrorResponse(HttpServletResponse resp, Exception e, String actionLabel,
            String errorCode) throws IOException {
        LOGGER.warn(actionLabel + " failed: " + e.getMessage());
        resp.setStatus(HttpServletResponse.SC_OK);
        writeJson(resp, errorBody(e, actionLabel, errorCode));
    }

    private static Map<String, String> errorBody(Exception e, String actionLabel, String errorCode) {
        Map<String, String> body = new java.util.HashMap<>();
        body.put("status", "error");
        body.put("message", e.getMessage() != null ? e.getMessage()
                : actionLabel + " failed. Check the runtime logs for details.");
        if (errorCode != null) {
            body.put("errorCode", errorCode);
        }
        return body;
    }
}
