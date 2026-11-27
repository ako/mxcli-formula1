package mqttconnector.implementation;

import com.mendix.datahub.connector.mqtt.mendixapi.IMendixCoreLogger;
import com.mendix.logging.ILogNode;

public class MendixCoreLoggerImpl implements IMendixCoreLogger
{
    public static final ILogNode logNode = CoreProxyImpl.getInstance().getLogger();
    public void info(String message)
    {
        logNode.info(message);
    }

    public void trace(String message) {
        logNode.trace(message);
    }

    public void debug(String message) { logNode.debug(message); }

    public void error(String message, Throwable throwable) {
        logNode.error(message, throwable);
    }

    @Override
    public void warn(String message) {
        logNode.warn(message);
    }
}
