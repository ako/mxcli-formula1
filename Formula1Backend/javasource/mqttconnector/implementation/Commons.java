package mqttconnector.implementation;

import com.mendix.core.Core;
import com.mendix.core.CoreException;
import com.mendix.datahub.connector.mqtt.BrokerConnectionException;
import com.mendix.datahub.connector.mqtt.Connection;
import com.mendix.datahub.connector.mqtt.utils.CryptoException;
import com.mendix.datahub.connector.mqtt.utils.CryptoHelper;
import mqttconnector.proxies.ConnectionDetail;
import mqttconnector.proxies.QoS;
import mqttconnector.proxies.constants.Constants;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import static com.mendix.datahub.connector.mqtt.utils.Constants.PAYLOAD_CHARSET_UTF_8;


public class Commons {
    private Commons() {

    }

    public static Boolean validateParameters(ConnectionDetail detail, String topic) {
        return (detail != null && (detail.getBrokerHost() != null && !detail.getBrokerHost().isEmpty()) && (topic != null && !topic.isEmpty()));
    }

    public static Boolean validateConnectionDetails(ConnectionDetail detail) {
        return (detail != null && (detail.getBrokerHost() != null && !detail.getBrokerHost().isEmpty()));
    }

    public static int getQoS(mqttconnector.proxies.QoS qos) {
        if (qos == null)
            return 0;
        if (qos.name().equals("AtleastOnce"))
            return 1;
        else if (qos.name().equals("ExactlyOnce"))
            return 2;
        else
            return 0;
    }

    public static Connection getBrokerConnection(String clientIdPrefix, ConnectionDetail connectionDetail) throws CoreException, BrokerConnectionException, CryptoException {

        String host = connectionDetail.getBrokerHost();
        boolean matches = host.startsWith("tcp://")
                || host.startsWith("ssl://")
                || host.startsWith("ws://")
                || host.startsWith("wss://");
        if (!matches) {
            host = connectionDetail.getSSL() ? "ssl://" + host : "tcp://" + host;
        }
        var connection = new Connection(clientIdPrefix, host, connectionDetail.getBrokerPort());

        String customClientId = connectionDetail.getClientId();
        if (connectionDetail.getUseCustomClientId() && customClientId != null && !customClientId.isBlank()) {
            connection.setClientId(customClientId.trim());
        }

        if (connectionDetail.getSSL()) {
            setCertificate(connectionDetail, connection);
        }
        setConnectionOptions(connectionDetail, connection);
        return connection;
    }

    private static void setConnectionOptions(ConnectionDetail connectionDetail, Connection connection) throws CoreException, CryptoException {
        connection.setConnectionTimeout(connectionDetail.getTimeOut());
        connection.setAutomaticReconnect(connectionDetail.getAutoReconnect());
        connection.setCleanSession(connectionDetail.getCleanSession());
        connection.setKeepAliveInterval(connectionDetail.getKeepAliveTime());
        connection.setAuthenticationMethod(getAuthenticationMethod(connectionDetail));
        connection.setHostnameVerification(connectionDetail.getHostnameVerification() == null || connectionDetail.getHostnameVerification());
        connection.setMaxInFlight(connectionDetail.getMaxInFlight() == null ? Connection.MAX_INFLIGHT : connectionDetail.getMaxInFlight());
        connection.setMaxReconnectDelay(connectionDetail.getMaxReconnectDelay() == null ? Connection.MAX_RECONNECT_DELAY : connectionDetail.getMaxReconnectDelay());
        connection.setTimeToWait(connectionDetail.getOperationTimeout()== null ? Connection.OPERATION_TIMEOUT : connectionDetail.getOperationTimeout());
        setWillProperties(connectionDetail, connection);

        if (connectionDetail.getUserName() != null && !connectionDetail.getUserName().isBlank()) {
            connection.setHostUserName(connectionDetail.getUserName());
        }
        if (connectionDetail.getPassword() != null && !connectionDetail.getPassword().isBlank()) {
            new CryptoHelper().inputAndKeyValidation(connectionDetail.getPassword(), Constants.getEncryptionKey());
            connection.setHostPassword(new CryptoHelper().decrypt(connectionDetail.getPassword(), Constants.getEncryptionKey()));
        }
    }

    private static void setWillProperties(ConnectionDetail connectionDetail, Connection connection) {
        connection.setSetWill(connectionDetail.getSetWill() != null && connectionDetail.getSetWill());
        connection.setWillTopic(connectionDetail.getWillTopic());
        connection.setWillQoS(getQoS(connectionDetail.getWillQoS()== null ? QoS.AtleastOnce : connectionDetail.getWillQoS()));

        if(connectionDetail.getWillPayLoad() !=null && !connectionDetail.getWillPayLoad().isBlank()){
          connection.setWillPayLoad(connectionDetail.getWillPayLoad().getBytes(PAYLOAD_CHARSET_UTF_8));
         }
        connection.setWillRetain(connectionDetail.getWillRetain() != null && connectionDetail.getWillRetain());
    }

    private static void setCertificate(ConnectionDetail connectionDetail, Connection connection) throws CryptoException {
        String ca = connectionDetail.getCA();
        if (ca != null && !ca.isBlank()) {
            InputStream caInput = new ByteArrayInputStream(ca.getBytes(PAYLOAD_CHARSET_UTF_8));
            connection.setCaFile(caInput);
        }

        String clientKey = connectionDetail.getClientKey();
        if (clientKey != null && !clientKey.isBlank()) {
            InputStream clientKeyInput = new ByteArrayInputStream(clientKey.getBytes(PAYLOAD_CHARSET_UTF_8));
            connection.setClientKey(clientKeyInput);
        }

        String clientCertificate = connectionDetail.getClientCertificate();
        if (clientCertificate != null && !clientCertificate.isBlank()) {
            InputStream clientCertificateInput =new ByteArrayInputStream(clientCertificate.getBytes(PAYLOAD_CHARSET_UTF_8));
            connection.setClientCertificate(clientCertificateInput);
        }
        if (connectionDetail.getCertificatePassword() != null && !connectionDetail.getCertificatePassword().isBlank()) {
            new CryptoHelper().inputAndKeyValidation(connectionDetail.getCertificatePassword(), Constants.getEncryptionKey());
            connection.setPassword(new CryptoHelper().decrypt(connectionDetail.getCertificatePassword(), Constants.getEncryptionKey()));
        }
    }

    private static Connection.AuthenticationMethod getAuthenticationMethod(ConnectionDetail connectionDetail) throws CoreException {
        if (connectionDetail.getAuthenticationMethod() == null)
            return Connection.AuthenticationMethod.NONE;
        switch (connectionDetail.getAuthenticationMethod()) {
            case NONE:
                return Connection.AuthenticationMethod.NONE;
            case BASIC:
                return Connection.AuthenticationMethod.BASIC;
            default:
                throw new CoreException("Unknown authentication method provided.");
        }
    }


    public static void recordConnectedBrokers(int value, ConnectionDetail connectionDetail) {

      Core.metrics().createGauge("dnl_connectors_mqtt_connected_brokers")
          .withTag("authentication_provider", String.valueOf(connectionDetail.getAuthenticationMethod()))
          .build().recordDelta(value);

    }

    public static void createCounterEvent(String eventName) {

        Core.metrics().createCounter(eventName).build().increment();

    }

    public static void createCounterEvent(String eventName, String tagName, String tagValue) {

        Core.metrics().createCounter(eventName).withTag(tagName, tagValue).build().increment();

    }
}
