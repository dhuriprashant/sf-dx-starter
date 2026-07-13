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

    public static void clear() {
        BY_TYPE.clear();
    }
}
