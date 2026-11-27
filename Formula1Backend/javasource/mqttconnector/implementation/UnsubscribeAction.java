package mqttconnector.implementation;

import com.mendix.core.CoreException;
import com.mendix.datahub.connector.mqtt.BrokerConnection;
import com.mendix.datahub.connector.mqtt.BrokerConnectionException;
import com.mendix.datahub.connector.mqtt.operation.BrokerSubscriptionException;
import com.mendix.datahub.connector.mqtt.operation.BrokerUnsubscriptionException;
import com.mendix.datahub.connector.mqtt.utils.CryptoException;
import mqttconnector.proxies.ConnectionDetail;

import static mqttconnector.implementation.Commons.*;
import static mqttconnector.implementation.Commons.createCounterEvent;

public class UnsubscribeAction {

    private final String clientIdPrefix;
    private final ConnectionDetail connectionDetail;
    private final String topic;

    public UnsubscribeAction(String clientIdPrefix, mqttconnector.proxies.ConnectionDetail connectionDetail, String topic) {
        this.clientIdPrefix = clientIdPrefix;
        this.connectionDetail = connectionDetail;
        this.topic = topic;
    }

    public Void execute() throws CoreException, BrokerSubscriptionException, BrokerUnsubscriptionException, BrokerConnectionException, CryptoException {
        Boolean valid = validateParameters(connectionDetail, topic);
        if (Boolean.FALSE.equals(valid)) {
            throw new BrokerSubscriptionException("Connection Details Missing or Invalid Host Name provided");
        }

        var brokerConnection = new BrokerConnection(getBrokerConnection(clientIdPrefix, connectionDetail));
        var triggerMetric = !brokerConnection.isConnected();
        brokerConnection.unsubscribe(topic);
        if (triggerMetric && brokerConnection.isConnected()) {
            recordConnectedBrokers(1,connectionDetail);
        }
        createCounterEvent("dnl_connectors_mqtt_unsubscribe_from_topic","topic_name",this.topic);
        return null;
    }

}
