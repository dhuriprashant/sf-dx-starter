/**
 * Generic SObject-backed engine behind the JSON:API router. All queries and DML
 * run in USER_MODE so object/field-level security and sharing are enforced.
 */
public with sharing class JsonApiService {
    // ---------- Collection: GET /{type} ----------

    public static Map<String, Object> listResources(JsonApiResourceDefinition def, JsonApiQueryParams qp) {
        Map<String, Object> binds = new Map<String, Object>();
        String whereClause = buildWhere(def, qp, binds);

        Integer total = Database.countQueryWithBinds(
            'SELECT COUNT() FROM ' + def.sobjectName + whereClause,
            binds,
            AccessLevel.USER_MODE
        );

        binds.put('jsonApiLimit', qp.pageSize);
        binds.put('jsonApiOffset', (qp.pageNumber - 1) * qp.pageSize);
        String soql =
            'SELECT ' + String.join(def.getSelectFields(), ', ') +
            ' FROM ' + def.sobjectName +
            whereClause +
            buildOrderBy(def, qp) +
            ' LIMIT :jsonApiLimit OFFSET :jsonApiOffset';
        List<SObject> records = Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);

        Compound comp = buildCompound(records, def, qp);
        List<Map<String, Object>> data = new List<Map<String, Object>>();
        for (SObject rec : records) {
            data.add(JsonApiSerializer.resource(rec, def, qp, comp.toManyData));
        }
        return JsonApiSerializer.document(data, pageLinks(def, qp, total), pageMeta(qp, total), comp.included);
    }

    // ---------- Single resource: GET /{type}/{id} ----------

    public static Map<String, Object> getResource(JsonApiResourceDefinition def, Id recordId, JsonApiQueryParams qp) {
        SObject rec = fetchById(def, recordId);
        Compound comp = buildCompound(new List<SObject>{ rec }, def, qp);
        return JsonApiSerializer.document(
            JsonApiSerializer.resource(rec, def, qp, comp.toManyData),
            new Map<String, Object>{ 'self' => JsonApiSerializer.resourceUrl(def.resourceType, recordId) },
            null,
            comp.included
        );
    }

    // ---------- Create: POST /{type} ----------

    public static Map<String, Object> createResource(JsonApiResourceDefinition def, Map<String, Object> body) {
        Map<String, Object> data = primaryData(body);
        validateType(def, data);
        if (data.containsKey('id') && data.get('id') != null) {
            throw JsonApiException.forbidden('Client-generated IDs are not supported.');
        }
        SObject rec = def.getSObjectType().newSObject();
        applyAttributes(def, rec, data);
        applyToOneRelationships(def, rec, data);
        Database.insert(rec, AccessLevel.USER_MODE);
        return getResource(def, rec.Id, new JsonApiQueryParams());
    }

    // ---------- Update: PATCH /{type}/{id} ----------

    public static Map<String, Object> updateResource(
        JsonApiResourceDefinition def,
        Id recordId,
        Map<String, Object> body
    ) {
        Map<String, Object> data = primaryData(body);
        validateType(def, data);
        String bodyId = (String) data.get('id');
        if (bodyId != null && bodyId != String.valueOf(recordId)) {
            throw JsonApiException.conflict('Resource id in body does not match URL.');
        }
        fetchById(def, recordId); // 404 if missing or inaccessible
        SObject rec = def.getSObjectType().newSObject(recordId);
        applyAttributes(def, rec, data);
        applyToOneRelationships(def, rec, data);
        Database.update(rec, AccessLevel.USER_MODE);
        return getResource(def, recordId, new JsonApiQueryParams());
    }

    // ---------- Delete: DELETE /{type}/{id} ----------

    public static void deleteResource(JsonApiResourceDefinition def, Id recordId) {
        fetchById(def, recordId);
        Database.delete(recordId, AccessLevel.USER_MODE);
    }

    // ---------- Related resources: GET /{type}/{id}/{rel} ----------

    public static Map<String, Object> getRelated(
        JsonApiResourceDefinition def,
        Id recordId,
        String relName,
        JsonApiQueryParams qp
    ) {
        JsonApiResourceDefinition.Rel rel = requireRel(def, relName);
        SObject parent = fetchById(def, recordId);

        if (rel.isNested()) {
            NestedResult nr = traverseNested(def, rel, new List<SObject>{ parent });
            if (rel.isToMany) {
                List<Map<String, Object>> nestedData = new List<Map<String, Object>>();
                for (SObject fin : nr.finalsById.values()) {
                    nestedData.add(JsonApiSerializer.resource(fin, nr.finalDef, qp, null));
                }
                return JsonApiSerializer.document(nestedData, relatedLinks(def, recordId, relName), null, null);
            }
            Object nestedOne = nr.finalsById.isEmpty()
                ? null
                : JsonApiSerializer.resource(nr.finalsById.values()[0], nr.finalDef, qp, null);
            return JsonApiSerializer.document(nestedOne, relatedLinks(def, recordId, relName), null, null);
        }

        JsonApiResourceDefinition targetDef = JsonApiRegistry.get(rel.targetType);
        if (rel.isToMany) {
            List<SObject> children = queryChildren(targetDef, rel.field, new Set<Id>{ recordId });
            List<Map<String, Object>> data = new List<Map<String, Object>>();
            for (SObject child : children) {
                data.add(JsonApiSerializer.resource(child, targetDef, qp, null));
            }
            return JsonApiSerializer.document(data, relatedLinks(def, recordId, relName), null, null);
        }
        Id targetId = (Id) parent.get(rel.field);
        Object data = targetId == null
            ? null
            : JsonApiSerializer.resource(fetchById(targetDef, targetId), targetDef, qp, null);
        return JsonApiSerializer.document(data, relatedLinks(def, recordId, relName), null, null);
    }

    // ---------- Relationship linkage: GET /{type}/{id}/relationships/{rel} ----------

    public static Map<String, Object> getRelationship(JsonApiResourceDefinition def, Id recordId, String relName) {
        JsonApiResourceDefinition.Rel rel = requireRel(def, relName);
        SObject parent = fetchById(def, recordId);
        Object data;
        if (rel.isNested()) {
            NestedResult nr = traverseNested(def, rel, new List<SObject>{ parent });
            List<Map<String, Object>> identifiers = nr.linkage.containsKey(recordId)
                ? nr.linkage.get(recordId)
                : new List<Map<String, Object>>();
            data = rel.isToMany ? (Object) identifiers : (identifiers.isEmpty() ? null : (Object) identifiers[0]);
        } else if (rel.isToMany) {
            JsonApiResourceDefinition targetDef = JsonApiRegistry.get(rel.targetType);
            List<Map<String, Object>> identifiers = new List<Map<String, Object>>();
            for (SObject child : queryChildren(targetDef, rel.field, new Set<Id>{ recordId })) {
                identifiers.add(JsonApiSerializer.identifier(rel.targetType, child.Id));
            }
            data = identifiers;
        } else {
            Id targetId = (Id) parent.get(rel.field);
            data = targetId == null ? null : JsonApiSerializer.identifier(rel.targetType, targetId);
        }
        return JsonApiSerializer.document(data, relationshipLinks(def, recordId, relName), null, null);
    }

    // ---------- Update to-one linkage: PATCH /{type}/{id}/relationships/{rel} ----------

    public static Map<String, Object> patchRelationship(
        JsonApiResourceDefinition def,
        Id recordId,
        String relName,
        Map<String, Object> body
    ) {
        JsonApiResourceDefinition.Rel rel = requireRel(def, relName);
        if (rel.isNested()) {
            throw JsonApiException.forbidden('Nested relationship "' + relName + '" is read-only.');
        }
        if (rel.isToMany) {
            throw JsonApiException.forbidden('Updating to-many relationship linkage is not supported.');
        }
        if (body == null || !body.containsKey('data')) {
            throw JsonApiException.badRequest('Relationship update requires a "data" member.').withPointer('/data');
        }
        fetchById(def, recordId);
        Object linkage = body.get('data');
        Id targetId = null;
        if (linkage != null) {
            Map<String, Object> identifier = (Map<String, Object>) linkage;
            if ((String) identifier.get('type') != rel.targetType) {
                throw JsonApiException.conflict('Expected resource identifier of type "' + rel.targetType + '".');
            }
            targetId = Id.valueOf((String) identifier.get('id'));
        }
        SObject rec = def.getSObjectType().newSObject(recordId);
        rec.put(rel.field, targetId);
        Database.update(rec, AccessLevel.USER_MODE);
        return getRelationship(def, recordId, relName);
    }

    // ---------- Internals ----------

    private class Compound {
        List<Map<String, Object>> included = new List<Map<String, Object>>();
        Map<String, Map<Id, List<Map<String, Object>>>> toManyData = new Map<String, Map<Id, List<Map<String, Object>>>>();
    }

    /** One expanded level of an include path: the records reached and their definition. */
    private class Level {
        JsonApiResourceDefinition def;
        List<SObject> records = new List<SObject>();
    }

    private class PendingInclude {
        SObject rec;
        JsonApiResourceDefinition def;
    }

    /**
     * Resolve ?include (relationship names or dot-paths): fetch related records
     * level by level, build the included array and relationship linkage.
     * Per the spec, dot-paths include the intermediate resources along with the
     * leaf nodes, and serialization is deferred until all linkage is known so
     * included intermediates carry full linkage for the next path segment.
     */
    private static Compound buildCompound(
        List<SObject> records,
        JsonApiResourceDefinition def,
        JsonApiQueryParams qp
    ) {
        Compound comp = new Compound();
        if (qp == null || qp.include.isEmpty() || records.isEmpty()) {
            return comp;
        }
        Set<String> seen = new Set<String>();
        for (SObject rec : records) {
            seen.add(def.resourceType + ':' + rec.Id); // primary data must not be duplicated in included
        }
        List<PendingInclude> pending = new List<PendingInclude>();
        Map<String, Level> levelCache = new Map<String, Level>(); // path prefix -> expanded level

        for (String includePath : qp.include) {
            Level current = new Level();
            current.def = def;
            current.records = records;
            String prefix = '';
            for (String segName : includePath.split('\\.')) {
                prefix = prefix == '' ? segName : prefix + '.' + segName;
                if (levelCache.containsKey(prefix)) {
                    current = levelCache.get(prefix);
                } else {
                    current = expandRelationship(comp, current, segName);
                    levelCache.put(prefix, current);
                    for (SObject rec : current.records) {
                        String key = current.def.resourceType + ':' + rec.Id;
                        if (!seen.contains(key)) {
                            seen.add(key);
                            PendingInclude pi = new PendingInclude();
                            pi.rec = rec;
                            pi.def = current.def;
                            pending.add(pi);
                        }
                    }
                }
                if (current.records.isEmpty()) {
                    break;
                }
            }
        }

        for (PendingInclude pi : pending) {
            comp.included.add(JsonApiSerializer.resource(pi.rec, pi.def, qp, comp.toManyData));
        }
        return comp;
    }

    /** Fetch one relationship level for the given parents and merge its linkage into the compound. */
    private static Level expandRelationship(Compound comp, Level parents, String relName) {
        JsonApiResourceDefinition.Rel rel = parents.def.relationships.get(relName);
        Level next = new Level();
        if (rel.isNested()) {
            NestedResult nr = traverseNested(parents.def, rel, parents.records);
            next.def = nr.finalDef;
            next.records = nr.finalsById.values();
            mergeLinkage(comp, rel.name, nr.linkage);
            return next;
        }
        JsonApiResourceDefinition targetDef = JsonApiRegistry.get(rel.targetType);
        next.def = targetDef;
        if (rel.isToMany) {
            Set<Id> parentIds = new Map<Id, SObject>(parents.records).keySet();
            Map<Id, List<Map<String, Object>>> linkage = new Map<Id, List<Map<String, Object>>>();
            for (SObject child : queryChildren(targetDef, rel.field, parentIds)) {
                Id parentId = (Id) child.get(rel.field);
                if (!linkage.containsKey(parentId)) {
                    linkage.put(parentId, new List<Map<String, Object>>());
                }
                linkage.get(parentId).add(JsonApiSerializer.identifier(rel.targetType, child.Id));
                next.records.add(child);
            }
            mergeLinkage(comp, rel.name, linkage);
        } else {
            // to-one linkage is read straight off the parent record at serialization time
            Set<Id> targetIds = new Set<Id>();
            for (SObject rec : parents.records) {
                Id targetId = (Id) rec.get(rel.field);
                if (targetId != null) {
                    targetIds.add(targetId);
                }
            }
            if (!targetIds.isEmpty()) {
                next.records = queryByIds(targetDef, targetIds);
            }
        }
        return next;
    }

    private static void mergeLinkage(Compound comp, String relName, Map<Id, List<Map<String, Object>>> linkage) {
        if (!comp.toManyData.containsKey(relName)) {
            comp.toManyData.put(relName, new Map<Id, List<Map<String, Object>>>());
        }
        comp.toManyData.get(relName).putAll(linkage);
    }

    private class NestedResult {
        JsonApiResourceDefinition finalDef;
        Map<Id, SObject> finalsById = new Map<Id, SObject>();
        /** root record Id -> resource identifiers of the final-hop records it reaches (deduplicated) */
        Map<Id, List<Map<String, Object>>> linkage = new Map<Id, List<Map<String, Object>>>();
    }

    /**
     * Walk a nested relationship path hop by hop (one bulk query per hop),
     * returning only the final-hop records plus root->final linkage.
     * Intermediate records are queried but never serialized.
     */
    private static NestedResult traverseNested(
        JsonApiResourceDefinition def,
        JsonApiResourceDefinition.Rel rel,
        List<SObject> roots
    ) {
        JsonApiRegistry.resolveNested(def, rel);
        JsonApiResourceDefinition currentDef = def;
        Map<Id, SObject> current = new Map<Id, SObject>(roots);
        Map<Id, Set<Id>> rootsOf = new Map<Id, Set<Id>>(); // current record Id -> root Ids that reach it
        for (Id rootId : current.keySet()) {
            rootsOf.put(rootId, new Set<Id>{ rootId });
        }

        for (String hopName : rel.path) {
            JsonApiResourceDefinition.Rel hop = currentDef.relationships.get(hopName);
            JsonApiResourceDefinition targetDef = JsonApiRegistry.get(hop.targetType);
            Map<Id, SObject> next = new Map<Id, SObject>();
            Map<Id, Set<Id>> nextRootsOf = new Map<Id, Set<Id>>();
            if (!current.isEmpty()) {
                if (hop.isToMany) {
                    for (SObject child : queryChildren(targetDef, hop.field, current.keySet())) {
                        Id parentId = (Id) child.get(hop.field);
                        next.put(child.Id, child);
                        if (!nextRootsOf.containsKey(child.Id)) {
                            nextRootsOf.put(child.Id, new Set<Id>());
                        }
                        nextRootsOf.get(child.Id).addAll(rootsOf.get(parentId));
                    }
                } else {
                    Map<Id, Set<Id>> wanted = new Map<Id, Set<Id>>(); // target Id -> root Ids
                    for (SObject rec : current.values()) {
                        Id targetId = (Id) rec.get(hop.field);
                        if (targetId == null) {
                            continue;
                        }
                        if (!wanted.containsKey(targetId)) {
                            wanted.put(targetId, new Set<Id>());
                        }
                        wanted.get(targetId).addAll(rootsOf.get(rec.Id));
                    }
                    if (!wanted.isEmpty()) {
                        for (SObject target : queryByIds(targetDef, wanted.keySet())) {
                            next.put(target.Id, target);
                            nextRootsOf.put(target.Id, wanted.get(target.Id));
                        }
                    }
                }
            }
            current = next;
            rootsOf = nextRootsOf;
            currentDef = targetDef;
        }

        NestedResult result = new NestedResult();
        result.finalDef = currentDef;
        result.finalsById = current;
        for (Id finalId : current.keySet()) {
            for (Id rootId : rootsOf.get(finalId)) {
                if (!result.linkage.containsKey(rootId)) {
                    result.linkage.put(rootId, new List<Map<String, Object>>());
                }
                result.linkage.get(rootId).add(JsonApiSerializer.identifier(currentDef.resourceType, finalId));
            }
        }
        return result;
    }

    private static SObject fetchById(JsonApiResourceDefinition def, Id recordId) {
        Map<String, Object> binds = new Map<String, Object>{ 'jsonApiId' => recordId };
        List<SObject> recs = Database.queryWithBinds(
            'SELECT ' + String.join(def.getSelectFields(), ', ') +
                ' FROM ' + def.sobjectName + ' WHERE Id = :jsonApiId',
            binds,
            AccessLevel.USER_MODE
        );
        if (recs.isEmpty()) {
            throw JsonApiException.notFound('No ' + def.resourceType + ' resource with id ' + recordId);
        }
        return recs[0];
    }

    private static List<SObject> queryByIds(JsonApiResourceDefinition def, Set<Id> ids) {
        return Database.queryWithBinds(
            'SELECT ' + String.join(def.getSelectFields(), ', ') +
                ' FROM ' + def.sobjectName + ' WHERE Id IN :jsonApiIds',
            new Map<String, Object>{ 'jsonApiIds' => ids },
            AccessLevel.USER_MODE
        );
    }

    private static List<SObject> queryChildren(JsonApiResourceDefinition childDef, String fkField, Set<Id> parentIds) {
        Set<String> fields = new Set<String>(childDef.getSelectFields());
        fields.add(fkField);
        return Database.queryWithBinds(
            'SELECT ' + String.join(new List<String>(fields), ', ') +
                ' FROM ' + childDef.sobjectName + ' WHERE ' + fkField + ' IN :jsonApiParentIds',
            new Map<String, Object>{ 'jsonApiParentIds' => parentIds },
            AccessLevel.USER_MODE
        );
    }

    private static String buildWhere(JsonApiResourceDefinition def, JsonApiQueryParams qp, Map<String, Object> binds) {
        if (qp.filters.isEmpty()) {
            return '';
        }
        List<String> clauses = new List<String>();
        Integer i = 0;
        for (String attr : qp.filters.keySet()) {
            String fieldName = def.fieldFor(attr);
            Schema.DescribeFieldResult fd = describeField(def, fieldName);
            String bindName = 'jsonApiFilter' + i;
            binds.put(bindName, typedFilterValues(fd, qp.filters.get(attr).split(',')));
            clauses.add(fieldName + ' IN :' + bindName);
            i++;
        }
        return ' WHERE ' + String.join(clauses, ' AND ');
    }

    /** SOQL rejects List<Object> binds ("Invalid bind expression type of ANY"), so build a typed list per field type. */
    private static Object typedFilterValues(Schema.DescribeFieldResult fd, List<String> raws) {
        switch on fd.getType() {
            when DATE {
                List<Date> vals = new List<Date>();
                for (String raw : raws) {
                    vals.add((Date) coerce(fd, raw.trim()));
                }
                return vals;
            }
            when DATETIME {
                List<Datetime> vals = new List<Datetime>();
                for (String raw : raws) {
                    vals.add((Datetime) coerce(fd, raw.trim()));
                }
                return vals;
            }
            when INTEGER, DOUBLE, CURRENCY, PERCENT {
                List<Decimal> vals = new List<Decimal>();
                for (String raw : raws) {
                    try {
                        vals.add(Decimal.valueOf(raw.trim()));
                    } catch (Exception e) {
                        throw JsonApiException.badRequest('Invalid numeric filter value: ' + raw.trim());
                    }
                }
                return vals;
            }
            when BOOLEAN {
                List<Boolean> vals = new List<Boolean>();
                for (String raw : raws) {
                    vals.add((Boolean) coerce(fd, raw.trim()));
                }
                return vals;
            }
            when else {
                List<String> vals = new List<String>();
                for (String raw : raws) {
                    vals.add(raw.trim());
                }
                return vals;
            }
        }
    }

    private static String buildOrderBy(JsonApiResourceDefinition def, JsonApiQueryParams qp) {
        List<String> parts = new List<String>();
        for (JsonApiQueryParams.SortField sf : qp.sorts) {
            parts.add(def.fieldFor(sf.attribute) + (sf.descending ? ' DESC NULLS LAST' : ' ASC NULLS FIRST'));
        }
        if (parts.isEmpty()) {
            parts.add('Id ASC'); // stable default ordering for pagination
        }
        return ' ORDER BY ' + String.join(parts, ', ');
    }

    private static Map<String, Object> pageLinks(JsonApiResourceDefinition def, JsonApiQueryParams qp, Integer total) {
        String base = JsonApiSerializer.baseUrl() + '/' + def.resourceType + '?page%5Bsize%5D=' + qp.pageSize + '&page%5Bnumber%5D=';
        Integer lastPage = Math.max(1, (Integer) Math.ceil((Decimal) total / qp.pageSize));
        Map<String, Object> links = new Map<String, Object>{
            'self' => base + qp.pageNumber,
            'first' => base + 1,
            'last' => base + lastPage
        };
        if (qp.pageNumber > 1) {
            links.put('prev', base + (qp.pageNumber - 1));
        }
        if (qp.pageNumber < lastPage) {
            links.put('next', base + (qp.pageNumber + 1));
        }
        return links;
    }

    private static Map<String, Object> pageMeta(JsonApiQueryParams qp, Integer total) {
        return new Map<String, Object>{
            'totalResources' => total,
            'pageNumber' => qp.pageNumber,
            'pageSize' => qp.pageSize
        };
    }

    private static Map<String, Object> relatedLinks(JsonApiResourceDefinition def, Id recordId, String relName) {
        return new Map<String, Object>{ 'self' => JsonApiSerializer.resourceUrl(def.resourceType, recordId) + '/' + relName };
    }

    private static Map<String, Object> relationshipLinks(JsonApiResourceDefinition def, Id recordId, String relName) {
        String resUrl = JsonApiSerializer.resourceUrl(def.resourceType, recordId);
        return new Map<String, Object>{
            'self' => resUrl + '/relationships/' + relName,
            'related' => resUrl + '/' + relName
        };
    }

    private static JsonApiResourceDefinition.Rel requireRel(JsonApiResourceDefinition def, String relName) {
        JsonApiResourceDefinition.Rel rel = def.relationships.get(relName);
        if (rel == null) {
            throw JsonApiException.notFound('Unknown relationship "' + relName + '" on type ' + def.resourceType);
        }
        return rel;
    }

    private static Map<String, Object> primaryData(Map<String, Object> body) {
        if (body == null || !(body.get('data') instanceof Map<String, Object>)) {
            throw JsonApiException.badRequest('Request document must contain a "data" object.').withPointer('/data');
        }
        return (Map<String, Object>) body.get('data');
    }

    private static void validateType(JsonApiResourceDefinition def, Map<String, Object> data) {
        if ((String) data.get('type') != def.resourceType) {
            throw JsonApiException.conflict('Resource type must be "' + def.resourceType + '".').withPointer('/data/type');
        }
    }

    private static void applyAttributes(JsonApiResourceDefinition def, SObject rec, Map<String, Object> data) {
        if (!(data.get('attributes') instanceof Map<String, Object>)) {
            return;
        }
        Map<String, Object> attrs = (Map<String, Object>) data.get('attributes');
        for (String jsonName : attrs.keySet()) {
            String fieldName = def.attributes.get(jsonName);
            if (fieldName == null) {
                throw JsonApiException.badRequest('Unknown attribute: ' + jsonName)
                    .withPointer('/data/attributes/' + jsonName);
            }
            rec.put(fieldName, coerce(describeField(def, fieldName), attrs.get(jsonName)));
        }
    }

    private static void applyToOneRelationships(JsonApiResourceDefinition def, SObject rec, Map<String, Object> data) {
        if (!(data.get('relationships') instanceof Map<String, Object>)) {
            return;
        }
        Map<String, Object> rels = (Map<String, Object>) data.get('relationships');
        for (String relName : rels.keySet()) {
            JsonApiResourceDefinition.Rel rel = def.relationships.get(relName);
            if (rel == null || rel.isNested() || rel.isToMany) {
                throw JsonApiException.badRequest('Relationship "' + relName + '" cannot be written on this resource.')
                    .withPointer('/data/relationships/' + relName);
            }
            Map<String, Object> relObj = (Map<String, Object>) rels.get(relName);
            Object linkage = relObj == null ? null : relObj.get('data');
            if (linkage == null) {
                rec.put(rel.field, null);
            } else {
                Map<String, Object> identifier = (Map<String, Object>) linkage;
                if ((String) identifier.get('type') != rel.targetType) {
                    throw JsonApiException.conflict('Relationship "' + relName + '" expects type "' + rel.targetType + '".')
                        .withPointer('/data/relationships/' + relName + '/data/type');
                }
                rec.put(rel.field, Id.valueOf((String) identifier.get('id')));
            }
        }
    }

    private static Schema.DescribeFieldResult describeField(JsonApiResourceDefinition def, String fieldName) {
        Schema.SObjectField field = def.getDescribe().fields.getMap().get(fieldName);
        if (field == null) {
            throw JsonApiException.of(500, 'Configuration Error', 'Field not found: ' + def.sobjectName + '.' + fieldName);
        }
        return field.getDescribe();
    }

    /** Coerce a JSON value (String/Decimal/Boolean) to the Apex type the field expects. */
    private static Object coerce(Schema.DescribeFieldResult fd, Object value) {
        if (value == null) {
            return null;
        }
        try {
            switch on fd.getType() {
                when DATE {
                    return value instanceof Date ? value : Date.valueOf(String.valueOf(value));
                }
                when DATETIME {
                    if (value instanceof Datetime) {
                        return value;
                    }
                    return (Datetime) JSON.deserialize('"' + String.valueOf(value) + '"', Datetime.class);
                }
                when INTEGER {
                    if (value instanceof Integer) {
                        return value;
                    }
                    if (value instanceof Decimal) {
                        return ((Decimal) value).intValue();
                    }
                    return Integer.valueOf(String.valueOf(value));
                }
                when DOUBLE, CURRENCY, PERCENT {
                    return value instanceof Decimal ? value : Decimal.valueOf(String.valueOf(value));
                }
                when BOOLEAN {
                    return value instanceof Boolean ? value : Boolean.valueOf(String.valueOf(value));
                }
                when else {
                    return value;
                }
            }
        } catch (JsonApiException je) {
            throw je;
        } catch (Exception e) {
            throw JsonApiException.badRequest(
                'Invalid value for field type ' + fd.getType() + ': ' + String.valueOf(value)
            );
        }
    }
}
