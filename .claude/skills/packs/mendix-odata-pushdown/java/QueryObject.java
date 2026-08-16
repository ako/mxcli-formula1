package {{MODULE_PATH}};

import com.mendix.core.Core;
import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixObject;

/**
 * The Mendix binding for {@link ODataQueryParser}.
 *
 * <p>Kept apart from the parser on purpose. The parser is plain Java over
 * strings — it can be exercised from a JUnit test, a {@code main}, or a jshell
 * session with no runtime around it, which is how the grammar in FINDINGS §45
 * was checked term by term. This class is the only part that needs a Mendix
 * context, and all it does is copy fields onto an object.
 */
public final class QueryObject {

    /** The entity this component publishes its answer as. */
    public static final String ENTITY = "ODataPushdown.Query";

    private QueryObject() {
    }

    /**
     * Runs the parse and returns the result as an {@code ODataPushdown.Query}.
     *
     * <p>Non-persistent, so nothing is committed and nothing needs cleaning up;
     * the object lives as long as the microflow that asked for it.
     */
    public static IMendixObject parse(IContext context, String uri, String columns,
                                      String dialect, Long maxTop, Long defaultTop,
                                      String defaultOrderBy, String keyField,
                                      Boolean rejectUnsupported) {
        ODataQueryParser.Result r = ODataQueryParser.parse(
                uri, columns, dialect,
                maxTop == null ? 500L : maxTop,
                defaultTop == null ? 100L : defaultTop,
                defaultOrderBy, keyField);

        if (r.rejected && Boolean.TRUE.equals(rejectUnsupported)) {
            // For a caller that splices, the alternative to throwing is an empty
            // WHERE — every row in the table, under a 200, in answer to a
            // request for a few of them. A 500 is the honest response to a
            // question this cannot read.
            throw new IllegalArgumentException(
                    "cannot translate OData query: " + r.rejectReason);
        }

        IMendixObject o = Core.instantiate(context, ENTITY);
        o.setValue(context, "FilterSql", r.filterSql);
        o.setValue(context, "OrderBySql", r.orderBySql);
        o.setValue(context, "Key", r.key);
        o.setValue(context, "Top", r.top);
        o.setValue(context, "Skip", r.skip);
        o.setValue(context, "WantsCount", r.wantsCount);
        o.setValue(context, "SortColumn1", r.sortColumn1);
        o.setValue(context, "SortDirection1", r.sortDirection1);
        o.setValue(context, "SortColumn2", r.sortColumn2);
        o.setValue(context, "SortDirection2", r.sortDirection2);
        o.setValue(context, "Rejected", r.rejected);
        o.setValue(context, "RejectReason", r.rejectReason);
        return o;
    }
}
