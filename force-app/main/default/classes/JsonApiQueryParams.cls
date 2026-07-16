/**
 * Parses and validates JSON:API query parameters against a resource definition:
 * include, fields[TYPE], sort, page[size]/page[after], filter[ATTR].
 */
public class JsonApiQueryParams {
    public List<String> include = new List<String>();
    /** resource type -> allowed attribute names (sparse fieldsets) */
    public Map<String, Set<String>> sparseFields = new Map<String, Set<String>>();
    public List<SortField> sorts = new List<SortField>();
    /** null means no pagination */
    public Integer pageSize;
    /** cursor: resume after this record Id (keyset pagination, Id ASC order) */
    public Id after;
    /** JSON attribute name -> raw filter value (comma-separated values mean IN) */
    public Map<String, String> filters = new Map<String, String>();

    public static JsonApiQueryParams parse(Map<String, String> params, JsonApiResourceDefinition def) {
        JsonApiQueryParams qp = new JsonApiQueryParams();
        if (params == null) {
            return qp;
        }
        for (String key : params.keySet()) {
            String value = params.get(key);
            if (key == 'include') {
                for (String inc : value.split(',')) {
                    String path = inc.trim();
                    // dot-paths: each segment must be a relationship on the type reached by the previous one
                    JsonApiResourceDefinition currentDef = def;
                    for (String seg : path.split('\\.')) {
                        JsonApiResourceDefinition.Rel rel = currentDef.relationships.get(seg);
                        if (rel == null) {
                            throw JsonApiException.badParameter(
                                'Unknown relationship "' + seg + '" in include path: ' + path,
                                'include'
                            );
                        }
                        JsonApiRegistry.resolveNested(currentDef, rel);
                        currentDef = JsonApiRegistry.get(rel.targetType);
                    }
                    qp.include.add(path);
                }
            } else if (key.startsWith('fields[') && key.endsWith(']')) {
                String resType = key.substring(7, key.length() - 1);
                Set<String> allowed = new Set<String>();
                for (String f : value.split(',')) {
                    allowed.add(f.trim());
                }
                qp.sparseFields.put(resType, allowed);
            } else if (key == 'sort') {
                for (String s : value.split(',')) {
                    SortField sf = new SortField();
                    String name = s.trim();
                    sf.descending = name.startsWith('-');
                    sf.attribute = sf.descending ? name.substring(1) : name;
                    if (def.fieldFor(sf.attribute) == null) {
                        throw JsonApiException.badParameter('Cannot sort by unknown attribute: ' + sf.attribute, 'sort');
                    }
                    qp.sorts.add(sf);
                }
            } else if (key == 'page[number]') {
                throw JsonApiException.badParameter(
                    'Offset pagination is not supported; use page[size] and follow next links (page[after] cursor)',
                    'page[number]'
                );
            } else if (key == 'page[size]') {
                qp.pageSize = toPositiveInt(value, 'page[size]');
            } else if (key == 'page[after]') {
                try {
                    qp.after = Id.valueOf(value);
                } catch (Exception e) {
                    throw JsonApiException.badParameter('Not a valid record Id: ' + value, 'page[after]');
                }
                if (String.valueOf(qp.after.getSobjectType()) != def.sobjectName) {
                    throw JsonApiException.badParameter(
                        'Cursor Id does not belong to ' + def.resourceType + ': ' + value,
                        'page[after]'
                    );
                }
            } else if (key.startsWith('filter[') && key.endsWith(']')) {
                String attr = key.substring(7, key.length() - 1);
                if (def.fieldFor(attr) == null) {
                    throw JsonApiException.badParameter('Cannot filter by unknown attribute: ' + attr, key);
                }
                qp.filters.put(attr, value);
            }
        }
        if (qp.after != null) {
            if (qp.pageSize == null) {
                throw JsonApiException.badParameter('page[after] requires page[size]', 'page[after]');
            }
            if (!qp.sorts.isEmpty()) {
                throw JsonApiException.badParameter('page[after] cannot be combined with sort', 'page[after]');
            }
        }
        return qp;
    }

    public Set<String> sparseFor(String resourceType) {
        return sparseFields.get(resourceType);
    }

    private static Integer toPositiveInt(String value, String param) {
        Integer i;
        try {
            i = Integer.valueOf(value);
        } catch (Exception e) {
            throw JsonApiException.badParameter('Not a valid integer: ' + value, param);
        }
        if (i < 1) {
            throw JsonApiException.badParameter('Must be >= 1: ' + param, param);
        }
        return i;
    }

    public class SortField {
        public String attribute;
        public Boolean descending = false;
    }
}
