package mqttconnector.implementation;

import com.mendix.core.CoreException;
import com.mendix.datahub.connector.mqtt.BrokerConnection;
import com.mendix.datahub.connector.mqtt.BrokerConnectionException;
import com.mendix.datahub.connector.mqtt.operation.BrokerPublishException;
import com.mendix.datahub.connector.mqtt.utils.CryptoException;
import mqttconnector.proxies.ConnectionDetail;
import mqttconnector.proxies.QoS;

import static mqttconnector.implementation.Commons.*;

public class PublishAction {

    private final String clientIdPrefix;
    private final ConnectionDetail connectionDetail;
    private final String topic;
    private final String payload;
    private final QoS qoS;
    private final boolean retained;


    public PublishAction(String clientIdPrefix, ConnectionDetail connectionDetail1, String topic, String payload, QoS qoS, boolean retained) {

        this.clientIdPrefix = clientIdPrefix;
        this.connectionDetail = connectionDetail1;
        this.topic = topic;
        this.payload = payload;
        this.qoS = qoS;
        this.retained = retained;
    }

    public Void execute() throws CoreException, BrokerPublishException, BrokerConnectionException, CryptoException {
        Boolean valid = validateParameters(connectionDetail, topic);
        if (Boolean.FALSE.equals(valid)) {
            throw new BrokerPublishException("Connection Details Missing or Invalid Host Name provided");
        }
        var brokerConnection = new BrokerConnection(getBrokerConnection(clientIdPrefix, connectionDetail));
        var triggerMetric = !brokerConnection.isConnected();
        brokerConnection.publish(topic, payload, getQoS(qoS), retained);
        if (triggerMetric && brokerConnection.isConnected()) {
            recordConnectedBrokers(1,connectionDetail);
        }
        createCounterEvent("dnl_connectors_mqtt_publish_to_topic");
        return null;
    }

}
