package agenteditorcommons.impl;

import static java.util.Objects.requireNonNull;

import java.util.ArrayList;
import java.util.List;
import java.util.NoSuchElementException;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import com.mendix.core.Core;
import com.mendix.extensibility.CustomBlobDocumentInfo;
import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixObject;
import encryption.proxies.constants.Constants;

import agenteditorcommons.proxies.ModelDocument;

public class AgentDocumentUtils {

	private static final MxLogger LOGGER = new MxLogger(AgentDocumentUtils.class);
	private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();
	
	public static final String AGENT_DOCUMENT_TYPE_ID = "agenteditor.agent";
	public static final String MODEL_DOCUMENT_TYPE_ID = "agenteditor.model";
	public static final String KNOWLEDGE_BASE_DOCUMENT_TYPE_ID = "agenteditor.knowledgebase";
	public static final String CONSUMED_MCP_SERVICE_DOCUMENT_TYPE_ID = "agenteditor.consumedMCPService";
	public static final String PUBLISHED_MCP_SERVICE_DOCUMENT_TYPE_ID = "agenteditor.publishedMCPService";

	private AgentDocumentUtils() {
	}

	public static void importModelDocumentsOfType(String documentTypeID, IContext context, String encryptionKey) {
		List<CustomBlobDocumentInfo> customBlobDocumentList = Core.extensibility()
				.getCustomDocumentsOfType(documentTypeID);
		String documentFriendlyName = documentTypeID.substring(documentTypeID.lastIndexOf('.') + 1);
		LOGGER.info(customBlobDocumentList.size() + " " + documentFriendlyName
				+ "s document(s) found in the Mendix Model.");

		boolean requiresEncryptionKey = MODEL_DOCUMENT_TYPE_ID.equals(documentTypeID)
				|| KNOWLEDGE_BASE_DOCUMENT_TYPE_ID.equals(documentTypeID);
		
		if (requiresEncryptionKey && !customBlobDocumentList.isEmpty()) {
			if (encryptionKey == null || encryptionKey.isEmpty()) {
				throw new IllegalStateException("Encryption.EncryptionKey constant is required for " + documentFriendlyName + " documents.");
			}

			if (encryptionKey.length() != 32) {
				throw new IllegalStateException("Encryption.EncryptionKey constant must be 32 characters long.");
			}
		}

		List<ModelDocument> modelDocuments = new ArrayList<>();
		for (CustomBlobDocumentInfo customBlobDocument : customBlobDocumentList) {
			modelDocuments.add(getModelDocument(customBlobDocument, documentTypeID, context));
		}

		boolean isSuccess = false;

		switch (documentTypeID) {
		case MODEL_DOCUMENT_TYPE_ID:
			isSuccess = agenteditorcommons.proxies.microflows.Microflows.deployedModel_CreateUpdate_List(context,
					modelDocuments);
			break;

		case CONSUMED_MCP_SERVICE_DOCUMENT_TYPE_ID:
			isSuccess = agenteditorcommons.proxies.microflows.Microflows.consumedMCPService_CreateUpdate_List(context,
					modelDocuments);
			break;

		case KNOWLEDGE_BASE_DOCUMENT_TYPE_ID:
			isSuccess = agenteditorcommons.proxies.microflows.Microflows.knowledgeBase_CreateUpdate_List(context,
					modelDocuments);
			break;

		case AGENT_DOCUMENT_TYPE_ID:
			isSuccess = agenteditorcommons.proxies.microflows.Microflows.agent_CreateUpdate_List(context,
					modelDocuments);
			break;

		default:
			throw new IllegalArgumentException("Unknown document type: " + documentTypeID);
		}

		if (!isSuccess) {
			throw new IllegalArgumentException(
					"Creating/Updating " + documentFriendlyName + " documents failed due to bad input.");
		}
	}

	private static ModelDocument getModelDocument(CustomBlobDocumentInfo customBlobDocumentInfo, String documentTypeID,
			IContext context) {
		String qualifiedName = customBlobDocumentInfo.qualifiedDocumentName();
		LOGGER.debug("Importing model document with qualified name '" + qualifiedName + "'.");

		String modelDocumentContent = customBlobDocumentInfo.content();

		String documentID = customBlobDocumentInfo.documentID().toString();
		LOGGER.debug(qualifiedName + " - documentID: " + documentID);

		ModelDocument modelDocument = new ModelDocument(context);
		modelDocument.setDocumentID(context, documentID);
		modelDocument.setContent(context, modelDocumentContent);

		// jackson-map content to provider for Model and KB only

		if (documentTypeID == KNOWLEDGE_BASE_DOCUMENT_TYPE_ID || documentTypeID == MODEL_DOCUMENT_TYPE_ID) {
			String provider = getProvider(modelDocumentContent, qualifiedName);
			modelDocument.setProvider(context, provider);
		}

		modelDocument.setQualifiedName(context, qualifiedName);
		return modelDocument;
	}

	private static String getProvider(String modelDocumentContent, String qualifiedName) {
		try {
			JsonNode contentJson = OBJECT_MAPPER.readTree(modelDocumentContent);
			return contentJson.get("provider") == null ? null : contentJson.get("provider").asText();
		}

		catch (Exception e) {
			LOGGER.info("No valid provider was passed for model document with qualified name " + qualifiedName + ".");
			return null;
		}

	}

	public static IMendixObject getAgentObjectFromDocument(String agentName, IContext context) {

		CustomBlobDocumentInfo agentDocument = Core.extensibility().getCustomDocumentByFullName(agentName);
		requireNonNull(agentDocument, "Agent document with name " + agentName + " not found.");

		List<IMendixObject> results = Core.createXPathQuery("//AgentCommons.Agent[ModelDocumentID=$documentID]")
				.setVariable("documentID", agentDocument.documentID().toString()).setAmount(1).execute(context);

		if (results.isEmpty() || results.get(0) == null) {
			throw new NoSuchElementException("Agent object with name " + agentName + " does not exist.");
		}

		return results.get(0);
	}

	public static Boolean importAllModelDocuments(IContext context) {
		try {
			String encryptionKey = Constants.getEncryptionKey();
			AgentDocumentUtils.importModelDocumentsOfType(MODEL_DOCUMENT_TYPE_ID, context, encryptionKey);
			AgentDocumentUtils.importModelDocumentsOfType(CONSUMED_MCP_SERVICE_DOCUMENT_TYPE_ID, context, encryptionKey);
			AgentDocumentUtils.importModelDocumentsOfType(KNOWLEDGE_BASE_DOCUMENT_TYPE_ID, context, encryptionKey);
			AgentDocumentUtils.importModelDocumentsOfType(AGENT_DOCUMENT_TYPE_ID, context, encryptionKey);
		} catch (Exception e) {
			LOGGER.error(e, e.getMessage());
			return false;
		}
			
		AgentDocumentUtils.initPublishedMCPServices(context);

		return true;
	}

	/**
	 * Starts an MCP server for every Published MCP Service document in the Mendix Model.
	 * These documents are not persisted; they only drive runtime server registration.
	 */
	public static void initPublishedMCPServices(IContext context) {
		List<CustomBlobDocumentInfo> documents = Core.extensibility()
				.getCustomDocumentsOfType(PUBLISHED_MCP_SERVICE_DOCUMENT_TYPE_ID);
		LOGGER.info(documents.size() + " publishedMCPService document(s) found in the Mendix Model.");

		for (CustomBlobDocumentInfo document : documents) {
			try {
				initPublishedMCPService(document, context);
			} catch (Exception e) {
				// Non-critical: log and continue so a single bad document does not abort startup.
				LOGGER.error(e, "Failed to initialise Published MCP Service '"
						+ document.qualifiedDocumentName() + "'.");
			}
		}
	}

	private static void initPublishedMCPService(CustomBlobDocumentInfo document, IContext context) throws Exception {
		String qualifiedName = document.qualifiedDocumentName();
		JsonNode content = OBJECT_MAPPER.readTree(document.content());
		String serverName = getTextOrNull(content, "serverName");
		String version = getTextOrNull(content, "version");
		String endpointPath = getTextOrNull(content, "endpointPath");
		String protocolVersion = getTextOrNull(content, "protocolVersion");

		requireNonNull(serverName, "serverName is required for Published MCP Service '" + qualifiedName + "'.");
		requireNonNull(version, "version is required for Published MCP Service '" + qualifiedName + "'.");
		requireNonNull(endpointPath, "endpointPath is required for Published MCP Service '" + qualifiedName + "'.");
		requireNonNull(protocolVersion, "protocolVersion is required for Published MCP Service '" + qualifiedName + "'.");

		String authenticationMicroflow = null;
		String authorizationServerUrl = null;
		String scopes = null;

		if (content.path("authenticationEnabled").asBoolean(false)) {
			authenticationMicroflow = getMicroflowQualifiedName(content.get("authenticationMicroflow"));
			// OAuth settings require an authentication microflow, so they are ignored when authentication is disabled
			authorizationServerUrl = getTextOrNull(content, "authorizationServerUrl");
			scopes = getTextOrNull(content, "scopes");
		}

		IMendixObject mcpServer = Core.userActionCall("MCPServer.CreateMCPServer")
				.withParams(endpointPath, serverName, version, protocolVersion, authenticationMicroflow,
						authorizationServerUrl, scopes)
				.execute(context);
				
		LOGGER.debug("MCP Server started for Published MCP Service document '" + qualifiedName + "'.");

		JsonNode tools = content.get("tools");
		if (tools == null || !tools.isArray()) {
			return;
		}

		for (JsonNode tool : tools) {
			String toolName = getTextOrNull(tool, "name");
			String toolDescription = getTextOrNull(tool, "description");
			String toolMicroflow = getMicroflowQualifiedName(tool.get("sourceMicroflow"));
			String title = getTextOrNull(tool, "title");
			String schema = getTextOrNull(tool, "schema");

			Core.userActionCall("MCPServer.AddTool")
					.withParams(mcpServer, toolName, toolDescription, toolMicroflow, schema, title)
					.execute(context);
			LOGGER.debug("Registered tool '" + toolName + "' on Published MCP Service '" + qualifiedName + "'.");
		}
	}

	private static String getMicroflowQualifiedName(JsonNode modelDocumentNode) {
		if (modelDocumentNode == null || modelDocumentNode.isNull()) {
			return null;
		}
		return getTextOrNull(modelDocumentNode, "qualifiedName");
	}

	public static String getTextOrNull(JsonNode node, String fieldName) {
		JsonNode value = node.get(fieldName);
		return value == null || value.isNull() ? null : value.asText();
	}

	public static String getTextOrEmpty(JsonNode node, String fieldName) {
		String value = getTextOrNull(node, fieldName);
		return value != null ? value : "";
	}
}