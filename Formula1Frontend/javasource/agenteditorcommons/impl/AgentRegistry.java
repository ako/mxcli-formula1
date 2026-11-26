package agenteditorcommons.impl;

import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.mendix.core.Core;
import com.mendix.extensibility.CustomBlobDocumentInfo;

public class AgentRegistry {

	private static final MxLogger LOGGER = new MxLogger(AgentRegistry.class);
	private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();
	private static final String REGISTRATION_API = "/rest/registrationservice/v1/assets/";
	
	private static final String AGENT_REGISTRY_MODULE_NAME = "AgentRegistry";
	private static final String ENDPOINT_CONSTANT_NAME = AGENT_REGISTRY_MODULE_NAME + ".Endpoint";
	private static final String PAT_WRITE_CONSTANT_NAME = AGENT_REGISTRY_MODULE_NAME + ".PAT_Write";
	private static final String ENABLE_REGISTRATION_CONSTANT_NAME = AGENT_REGISTRY_MODULE_NAME + ".EnableRegistation";

	private AgentRegistry() {
	}

	public static void registerAssets() {
		try {
			// Check if both required constants exist.
			Object registerAssetsValue;
			Object endpointValue;
			Object patValue;
			try {
				registerAssetsValue = Core.getConfiguration().getConstantValue(ENABLE_REGISTRATION_CONSTANT_NAME);
				endpointValue = Core.getConfiguration().getConstantValue(ENDPOINT_CONSTANT_NAME);
				patValue = Core.getConfiguration().getConstantValue(PAT_WRITE_CONSTANT_NAME);
			} catch (Exception e) {
				LOGGER.debug("Required " + AGENT_REGISTRY_MODULE_NAME + " constants not found. Skipping asset registration in Agent Registry.");
				return;
			}

			Boolean registerAssets = registerAssetsValue != null ? Boolean.valueOf(registerAssetsValue.toString()) : false;
			String endpoint = endpointValue != null ? endpointValue.toString() : null;
			String writePAT = patValue != null ? patValue.toString() : null;
			
			if (!registerAssets) {
				LOGGER.debug("Asset registration disabled.");
				return;
			}
			
			if (endpoint == null || endpoint.isBlank()
					|| writePAT == null || writePAT.isBlank()) {
				LOGGER.warn(ENDPOINT_CONSTANT_NAME + " or " + PAT_WRITE_CONSTANT_NAME + " not configured. "
						+ "Skipping asset registration in Agent Registry.");
				return;
			}

			String environment = System.getenv("ENVIRONMENT");
			
			if (environment == null || environment.isBlank()) {
				LOGGER.warn("Environment ID not found. Assets can only be registered on cloud deloyment. " 
						+ "Skipping asset registration in Agent Registry.");
				return;
			}
			
			String applicationUrl = Core.getConfiguration().getApplicationRootUrl();

			// Published MCP service registration.
			List<CustomBlobDocumentInfo> publishedMCPServiceList = Core.extensibility()
					.getCustomDocumentsOfType(AgentDocumentUtils.PUBLISHED_MCP_SERVICE_DOCUMENT_TYPE_ID);
			List<ObjectNode> mcpServerPayloads = new ArrayList<>();

			for (CustomBlobDocumentInfo publishedMCPService : publishedMCPServiceList) {
				ObjectNode payload = buildRegistrationPayloadPublishedMCPService(publishedMCPService,
						applicationUrl);
				if (payload != null) {
					mcpServerPayloads.add(payload);
				}
			}

			if (!mcpServerPayloads.isEmpty()) {
				ObjectNode rootObject = buildRootObject(environment, applicationUrl, mcpServerPayloads);
				String registrationApiUrl = normalizeUrl(endpoint, true) + REGISTRATION_API + "mcp";
				sendRegistrationRequest(rootObject.toString(), registrationApiUrl, writePAT);
			}

			// Agent registration.
			List<CustomBlobDocumentInfo> agentDocumentList = Core.extensibility()
					.getCustomDocumentsOfType(AgentDocumentUtils.AGENT_DOCUMENT_TYPE_ID);
			List<ObjectNode> agentPayloads = new ArrayList<>();

			for (CustomBlobDocumentInfo agentDocument : agentDocumentList) {
				ObjectNode payload = buildRegistrationPayloadAgent(agentDocument, applicationUrl);
				if (payload != null) {
					agentPayloads.add(payload);
				}
			}

			if (!agentPayloads.isEmpty()) {
				ObjectNode rootObject = buildRootObject(environment, applicationUrl, agentPayloads);
				String registrationApiUrl = normalizeUrl(endpoint, true) + REGISTRATION_API + "agent";
				sendRegistrationRequest(rootObject.toString(), registrationApiUrl, writePAT);
			}
		} catch (Exception e) {
			LOGGER.error("Error during asset registration: ", e);
		}
	}
	
	private static ObjectNode buildRegistrationPayloadPublishedMCPService(CustomBlobDocumentInfo publishedMCPService, String applicationUrl) {
		try {
			JsonNode contentJson = OBJECT_MAPPER.readTree(publishedMCPService.content());
			String endpointPath = contentJson.path("endpointPath").asText("");
			String version = contentJson.path("version").asText("");
			String protocolVersion = contentJson.path("protocolVersion").asText("");
			String documentation = contentJson.path("documentation").asText("");
			String identifier = buildIdentifier(publishedMCPService, "mcpserver");
			String authenticationEnabled = contentJson.path("authenticationEnabled").asText("");

			ObjectNode publishedMCPServiceObject = OBJECT_MAPPER.createObjectNode();
			publishedMCPServiceObject.put("server_name", publishedMCPService.qualifiedDocumentName());
			publishedMCPServiceObject.put("transport", "http");
			publishedMCPServiceObject.put("url", getMCPEndpoint(applicationUrl, endpointPath));

			publishedMCPServiceObject.set("headers", OBJECT_MAPPER.createObjectNode());

			ObjectNode metadata = OBJECT_MAPPER.createObjectNode();
			addMetadataValue(metadata, "identifier", identifier);
			addMetadataValue(metadata, "modelDocumentID", publishedMCPService.documentID().toString());
			addMetadataValue(metadata, "version", version);
			addMetadataValue(metadata, "protocolVersion", protocolVersion);
			addMetadataValue(metadata, "documentation", documentation);
			addPublishedMcpToolsMetadata(metadata, contentJson.get("tools"));
			addMetadataValue(metadata, "authenticationEnabled", authenticationEnabled);
			addMetadataValue(metadata, "assetType", "mcpserver");
			
			publishedMCPServiceObject.set("metadata", metadata);

			return publishedMCPServiceObject;
		} catch (Exception e) {
			LOGGER.warn("Failed to build payload for published MCP service '" + publishedMCPService.qualifiedDocumentName()
					+ "'. Skipping this document.", e);
			return null;
		}
	}

	private static ObjectNode buildRegistrationPayloadAgent(CustomBlobDocumentInfo agentDocument, String applicationUrl) {
		try {
			JsonNode contentJson = OBJECT_MAPPER.readTree(agentDocument.content());
			String identifier = buildIdentifier(agentDocument, "agent");

			ObjectNode payload = OBJECT_MAPPER.createObjectNode();
			payload.put("server_name", agentDocument.qualifiedDocumentName());
			payload.put("transport", "http");
			payload.put("url", normalizeUrl(applicationUrl));
			payload.set("headers", OBJECT_MAPPER.createObjectNode());

			ObjectNode metadata = OBJECT_MAPPER.createObjectNode();
			addMetadataValue(metadata, "identifier", identifier);
			addMetadataValue(metadata, "modelDocumentID", agentDocument.documentID().toString());
			addMetadataValue(metadata, "description", contentJson.path("description").asText(""));
			addMetadataValue(metadata, "usageType", contentJson.path("usageType").asText(""));
			addMetadataValue(metadata, "assetType", "agent");

			payload.set("metadata", metadata);
			return payload;
		} catch (Exception e) {
			LOGGER.warn("Failed to build payload for agent document '" + agentDocument.qualifiedDocumentName()
					+ "'. Skipping this document.", e);
			return null;
		}
	}

	private static void addMetadataValue(ObjectNode metadata, String key, String value) {
		if (value == null || value.isBlank()) {
			return;
		}
		metadata.set(key, toSingleValueArray(value));
	}

	private static void addMetadataValues(ObjectNode metadata, String key, List<String> values) {
		ArrayNode arrayNode = OBJECT_MAPPER.createArrayNode();
		if (values != null) {
			for (String value : values) {
				arrayNode.add(value != null ? value : "");
			}
		}
		metadata.set(key, arrayNode);
	}

	private static void addPublishedMcpToolsMetadata(ObjectNode metadata, JsonNode toolsNode) {
		if (toolsNode == null || toolsNode.isNull()) {
			return;
		}

		List<String> projectedToolValues = new ArrayList<>();
		if (toolsNode.isArray()) {
			for (JsonNode toolNode : toolsNode) {
				ObjectNode projectedTool = OBJECT_MAPPER.createObjectNode();
				projectedTool.put("uuid", toolNode.path("uuid").asText(""));
				projectedTool.put("name", toolNode.path("name").asText(""));
				projectedTool.put("description", toolNode.path("description").asText(""));
				projectedToolValues.add(projectedTool.toString());
			}
		}

		addMetadataValues(metadata, "tools", projectedToolValues);
	}
	
	private static ArrayNode toSingleValueArray(String value) {
		ArrayNode arrayNode = OBJECT_MAPPER.createArrayNode();
		arrayNode.add(value != null ? value : "");
		return arrayNode;
	}

	private static String getMCPEndpoint(String applicationURL, String endpointPath) {
		String url;
		String normalizedApplicationUrl = normalizeUrl(applicationURL);

		if (endpointPath == null || endpointPath.isBlank()) {
			url = normalizedApplicationUrl;
		} else {
			String normalizedBase = normalizeUrl(normalizedApplicationUrl, true); // Remove trailing slash
			String normalizedPath = endpointPath.startsWith("/") ? endpointPath : "/" + endpointPath;
			url = normalizedBase + normalizedPath;
		}

		if (url == null || url.isBlank()) {
			return url;
		}

		url = normalizeUrl(url, true); // Remove trailing slash
		return url.endsWith("/mcp") ? url : url + "/mcp";
	}

	private static String normalizeUrl(String url) {
		return normalizeUrl(url, false);
	}

	private static String normalizeUrl(String url, boolean removeTrailingSlash) {
		if (url == null || url.isBlank()) {
			return url;
		}

		String normalizedUrl = url.trim();
		if (!normalizedUrl.startsWith("http://") && !normalizedUrl.startsWith("https://")) {
			normalizedUrl = "https://" + normalizedUrl;
		}

		if (removeTrailingSlash && normalizedUrl.endsWith("/")) {
			normalizedUrl = normalizedUrl.substring(0, normalizedUrl.length() - 1);
		}

		return normalizedUrl;
	}

	private static String buildIdentifier(CustomBlobDocumentInfo documentInfo, String namespace) {
		//urn:air:agentic.mendix.com:mcpserver|agent:<documentId>
		String domain = "agentic.mendix.com";

		return String.format("urn:air:%s:%s:%s", domain, namespace, documentInfo.documentID());
	}

	private static ObjectNode buildRootObject(String environment, String applicationUrl, List<ObjectNode> payloads) {
		ObjectNode rootObject = OBJECT_MAPPER.createObjectNode();
		rootObject.put("environment", environment);
		rootObject.put("applicationUrl", applicationUrl);
		
		ArrayNode dataArray = OBJECT_MAPPER.createArrayNode();
		for (ObjectNode payload : payloads) {
			dataArray.add(payload);
		}
		rootObject.set("data", dataArray);
		
		return rootObject;
	}
	
	private static void sendRegistrationRequest(String payload, String registrationApiUrl, String authToken) {
		HttpURLConnection connection = null;
		try {
			URL url = new URL(registrationApiUrl);
			connection = (HttpURLConnection) url.openConnection();
			connection.setRequestMethod("POST");
			connection.setRequestProperty("Content-Type", "application/json");
			connection.setRequestProperty("Accept", "application/json");
			connection.setRequestProperty("Authorization", "MxToken " + authToken);
			connection.setDoOutput(true);

			try (OutputStream os = connection.getOutputStream()) {
				byte[] input = payload.getBytes(StandardCharsets.UTF_8);
				os.write(input, 0, input.length);
			}

			int responseCode = connection.getResponseCode();
			if (responseCode == HttpURLConnection.HTTP_OK || responseCode == HttpURLConnection.HTTP_CREATED) {
				LOGGER.info("Registration request sent successfully to: " + registrationApiUrl);
			} else {
				LOGGER.warn("Failed to send registration request to: " + registrationApiUrl + ". Error: " + responseCode + " - " + connection.getResponseMessage());
			}
		} catch (Exception e) {
			LOGGER.error("Error sending registration request: ", e);
		} finally {
			if (connection != null) {
				connection.disconnect();
			}
		}
	}
}