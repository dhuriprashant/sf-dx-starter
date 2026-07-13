/**
 * Parses and validates JSON:API query parameters against a resource definition:
 * include, fields[TYPE], sort, page[number]/page[size], filter[ATTR].
 */
public class JsonApiQueryParams {
    public static final Integer DEFAULT_PAGE_SIZE = 20;
    public static final Integer MAX_PAGE_SIZE = 200;

    public List<String> include = new List<String>();
    /** resource type -> allowed attribute names (sparse fieldsets) */
    public Map<String, Set<String>> sparseFields = new Map<String, Set<String>>();
    public List<SortField> sorts = new List<SortField>();
    public Integer pageNumber = 1;
    public Integer pageSize = DEFAULT_PAGE_SIZE;
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
                    String name = inc.trim();
                    if (!def.relationships.containsKey(name)) {
                        throw JsonApiException.badParameter('Unknown relationship in include: ' + name, 'include');
                    }
                    qp.include.add(name);
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
                qp.pageNumber = toPositiveInt(value, 'page[number]');
            } else if (key == 'page[size]') {
                qp.pageSize = Math.min(toPositiveInt(value, 'page[size]'), MAX_PAGE_SIZE);
            } else if (key.startsWith('filter[') && key.endsWith(']')) {
                String attr = key.substring(7, key.length() - 1);
                if (def.fieldFor(attr) == null) {
                    throw JsonApiException.badParameter('Cannot filter by unknown attribute: ' + attr, key);
                }
                qp.filters.put(attr, value);
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
