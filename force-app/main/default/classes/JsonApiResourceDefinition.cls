/**
 * Declarative mapping between a JSON:API resource type and an SObject:
 * which fields are exposed as attributes and which lookups / child
 * relationships are exposed as JSON:API relationships.
 */
public class JsonApiResourceDefinition {
    public String resourceType { get; private set; }
    public String sobjectName { get; private set; }
    /** JSON attribute name -> SObject field API name */
    public Map<String, String> attributes { get; private set; }
    /** relationship name -> definition */
    public Map<String, Rel> relationships { get; private set; }

    private Schema.DescribeSObjectResult describeResult;

    public JsonApiResourceDefinition(String resourceType, String sobjectName) {
        this.resourceType = resourceType;
        this.sobjectName = sobjectName;
        this.attributes = new Map<String, String>();
        this.relationships = new Map<String, Rel>();
    }

    public JsonApiResourceDefinition attribute(String jsonName, String fieldName) {
        attributes.put(jsonName, fieldName);
        return this;
    }

    /** Expose a lookup field as a to-one relationship. */
    public JsonApiResourceDefinition toOne(String relName, String lookupField, String targetType) {
        Rel r = new Rel();
        r.name = relName;
        r.isToMany = false;
        r.field = lookupField;
        r.targetType = targetType;
        relationships.put(relName, r);
        return this;
    }

    /** Expose a child collection as a to-many relationship. `foreignKeyField` is the lookup on the child SObject. */
    public JsonApiResourceDefinition toMany(String relName, String targetType, String foreignKeyField) {
        Rel r = new Rel();
        r.name = relName;
        r.isToMany = true;
        r.field = foreignKeyField;
        r.targetType = targetType;
        relationships.put(relName, r);
        return this;
    }

    /**
     * Expose a deeply nested relationship path under a direct alternative name
     * (https://jsonapi.org/format/#fetching-includes), e.g. exposing
     * contacts.reportsTo as 'contactManagers'. Each path segment must be a
     * direct (toOne/toMany) relationship on the type reached by the previous
     * segment. Cardinality and target type are resolved lazily against the
     * registry on first use; nested relationships are read-only.
     */
    public JsonApiResourceDefinition nested(String relName, List<String> path) {
        Rel r = new Rel();
        r.name = relName;
        r.path = path;
        relationships.put(relName, r);
        return this;
    }

    public Schema.DescribeSObjectResult getDescribe() {
        if (describeResult == null) {
            describeResult = Schema.describeSObjects(new List<String>{ sobjectName })[0];
        }
        return describeResult;
    }

    public Schema.SObjectType getSObjectType() {
        return getDescribe().getSObjectType();
    }

    /** Fields to SELECT: Id, all attribute fields, and all to-one lookup fields. */
    public List<String> getSelectFields() {
        Set<String> fields = new Set<String>{ 'Id' };
        for (String f : attributes.values()) {
            fields.add(f);
        }
        for (Rel r : relationships.values()) {
            if (!r.isNested() && !r.isToMany) {
                fields.add(r.field);
            }
        }
        return new List<String>(fields);
    }

    /** Resolve a JSON attribute name (or "id") to a field API name; null if not exposed. */
    public String fieldFor(String jsonName) {
        if (jsonName == 'id') {
            return 'Id';
        }
        return attributes.get(jsonName);
    }

    public class Rel {
        public String name;
        /** null until resolved for nested relationships (true if any hop in the path is to-many) */
        public Boolean isToMany;
        /** to-one: lookup field on this SObject; to-many: foreign key field on the child SObject; null for nested */
        public String field;
        /** null until resolved for nested relationships (the final hop's target type) */
        public String targetType;
        /** direct relationship names to traverse, in order; non-null only for nested relationships */
        public List<String> path;

        public Boolean isNested() {
            return path != null;
        }
    }
}
