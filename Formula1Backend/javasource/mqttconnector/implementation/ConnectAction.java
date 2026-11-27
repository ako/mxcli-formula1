package mqttconnector.implementation;

import com.mendix.core.CoreException;
import com.mendix.datahub.connector.mqtt.BrokerConnection;
import com.mendix.datahub.connector.mqtt.BrokerConnectionException;
import com.mendix.datahub.connector.mqtt.utils.CryptoException;
import com.mendix.logging.ILogNode;
import mqttconnector.proxies.ConnectionDetail;

import static mqttconnector.implementation.Commons.*;

public class ConnectAction {

    private final String clientIdPrefix;
    private final ConnectionDetail connectionDetail;
    private static final ILogNode log= CoreProxyImpl.getInstance().getLogger();

    public ConnectAction(ConnectionDetail connectionDetail1, String clientIdPrefix)
    {
        this.connectionDetail = connectionDetail1;
        this.clientIdPrefix = clientIdPrefix;
    }

    public Void execute() throws CoreException, BrokerConnectionException, CryptoException {
        Boolean valid = validateConnectionDetails(connectionDetail);
        if (Boolean.FALSE.equals(valid)) {
            throw new BrokerConnectionException("Connection Details Missing or Invalid Host Name provided");
        }
        log.debug("Connecting to host " + connectionDetail.getBrokerHost());
        var brokerConnection = new BrokerConnection(getBrokerConnection(clientIdPrefix, connectionDetail));
        if(!brokerConnection.isConnected()) {
            brokerConnection.connect();
            recordConnectedBrokers(1,connectionDetail);
        }
        boolean useCustomClientId = connectionDetail.getUseCustomClientId() && connectionDetail.getClientId() != null && !connectionDetail.getClientId().isBlank();
        log.debug(String.format("Connected to host %s with %s", connectionDetail.getBrokerHost(),
                useCustomClientId ? "custom client ID " + connectionDetail.getClientId(): "client id prefix as " + clientIdPrefix));
        return null;
    }
}
