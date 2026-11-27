package mqttconnector.implementation;


/**
 *
 * @author reinout
 */
public class CoreProxyImpl implements CoreProxy {

	private static CoreProxy instance;

	private CoreProxyImpl() {
	} //Not implemented

	public static CoreProxy getInstance() {
		if (instance == null) {
			instance = new CoreProxyImpl();
		}
		return instance;
	}
}
