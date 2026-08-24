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

  public static JsonApiQueryParams parse(
    Map<String, String> params,
    JsonApiResourceDefinition def
  ) {
    JsonApiQueryParams qp = new JsonApiQueryParams();
    if (params == null) {
      return qp;
    }
    for (String key : params.keySet()) {
      String value = params.get(key);
      String fieldsType = bracketArg(key, 'fields');
      String filterAttr = bracketArg(key, 'filter');
      if (key == 'include') {
        for (String path : splitCsv(value)) {
          // dot-paths: each segment must be a relationship on the type reached by the previous one
          JsonApiResourceDefinition currentDef = def;
          for (String seg : path.split('\\.')) {
            JsonApiResourceDefinition.Rel rel = currentDef.relationships.get(
              seg
            );
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
      } else if (fieldsType != null) {
        qp.sparseFields.put(fieldsType, new Set<String>(splitCsv(value)));
      } else if (key == 'sort') {
        for (String name : splitCsv(value)) {
          SortField sf = new SortField();
          sf.descending = name.startsWith('-');
          sf.attribute = sf.descending ? name.substring(1) : name;
          if (def.fieldFor(sf.attribute) == null) {
            throw JsonApiException.badParameter(
              'Cannot sort by unknown attribute: ' + sf.attribute,
              'sort'
            );
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
          throw JsonApiException.badParameter(
            'Not a valid record Id: ' + value,
            'page[after]'
          );
        }
        if (String.valueOf(qp.after.getSobjectType()) != def.sobjectName) {
          throw JsonApiException.badParameter(
            'Cursor Id does not belong to ' + def.resourceType + ': ' + value,
            'page[after]'
          );
        }
      } else if (filterAttr != null) {
        if (def.fieldFor(filterAttr) == null) {
          throw JsonApiException.badParameter(
            'Cannot filter by unknown attribute: ' + filterAttr,
            key
          );
        }
        qp.filters.put(filterAttr, value);
      }
    }
    if (qp.after != null) {
      if (qp.pageSize == null) {
        throw JsonApiException.badParameter(
          'page[after] requires page[size]',
          'page[after]'
        );
      }
      if (!qp.sorts.isEmpty()) {
        throw JsonApiException.badParameter(
          'page[after] cannot be combined with sort',
          'page[after]'
        );
      }
    }
    return qp;
  }

  public Set<String> sparseFor(String resourceType) {
    return sparseFields.get(resourceType);
  }

  /** Split a comma-separated parameter value into trimmed parts. */
  public static List<String> splitCsv(String value) {
    List<String> parts = new List<String>();
    for (String part : value.split(',')) {
      parts.add(part.trim());
    }
    return parts;
  }

  /** Argument of a bracketed key, e.g. 'accounts' from 'fields[accounts]'; null if the key does not match. */
  private static String bracketArg(String key, String param) {
    if (!key.startsWith(param + '[') || !key.endsWith(']')) {
      return null;
    }
    return key.substring(param.length() + 1, key.length() - 1);
  }

  private static Integer toPositiveInt(String value, String param) {
    Integer i;
    try {
      i = Integer.valueOf(value);
    } catch (Exception e) {
      throw JsonApiException.badParameter(
        'Not a valid integer: ' + value,
        param
      );
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
