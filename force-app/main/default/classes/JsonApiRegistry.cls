/**
 * In-memory registry of JSON:API resource definitions, keyed by resource type.
 * Populated once per transaction by JsonApiConfig.registerAll().
 */
public class JsonApiRegistry {
  private static final Map<String, JsonApiResourceDefinition> BY_TYPE = new Map<String, JsonApiResourceDefinition>();

  public static void register(JsonApiResourceDefinition def) {
    BY_TYPE.put(def.resourceType, def);
  }

  public static Boolean isRegistered(String resourceType) {
    return BY_TYPE.containsKey(resourceType);
  }

  public static JsonApiResourceDefinition get(String resourceType) {
    JsonApiResourceDefinition def = BY_TYPE.get(resourceType);
    if (def == null) {
      throw JsonApiException.notFound('Unknown resource type: ' + resourceType);
    }
    return def;
  }

  public static Set<String> registeredTypes() {
    return BY_TYPE.keySet();
  }

  /**
   * Validate a nested relationship's path and cache the resolved
   * cardinality/target on the Rel (to-many if any hop is to-many).
   * No-op for direct or already-resolved relationships.
   */
  public static void resolveNested(
    JsonApiResourceDefinition def,
    JsonApiResourceDefinition.Rel rel
  ) {
    if (rel.targetType != null) {
      return;
    }
    JsonApiResourceDefinition currentDef = def;
    Boolean toMany = false;
    for (String hopName : rel.path) {
      JsonApiResourceDefinition.Rel hop = currentDef.relationships.get(hopName);
      if (hop == null || hop.isNested()) {
        throw JsonApiException.of(
          500,
          'Configuration Error',
          'Nested relationship "' +
            rel.name +
            '" on ' +
            def.resourceType +
            ' requires a direct relationship "' +
            hopName +
            '" on ' +
            currentDef.resourceType +
            '.'
        );
      }
      toMany = toMany || hop.isToMany;
      currentDef = get(hop.targetType);
    }
    rel.isToMany = toMany;
    rel.targetType = currentDef.resourceType;
  }

  public static void clear() {
    BY_TYPE.clear();
  }
}
