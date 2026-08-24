/**
 * Turns SObjects into JSON:API resource objects and assembles top-level documents
 * (https://jsonapi.org/format/#document-structure).
 */
public class JsonApiSerializer {
  public static String baseUrl() {
    return URL.getOrgDomainUrl().toExternalForm() +
      '/services/apexrest/jsonapi';
  }

  public static String collectionUrl(String resourceType) {
    return baseUrl() + '/' + resourceType;
  }

  public static String resourceUrl(String resourceType, Id recordId) {
    return collectionUrl(resourceType) + '/' + recordId;
  }

  public static Map<String, Object> selfLink(String url) {
    return new Map<String, Object>{ 'self' => url };
  }

  /** Links of a related-resource endpoint: /{type}/{id}/{rel}. */
  public static Map<String, Object> relatedLinks(
    String resourceType,
    Id recordId,
    String relName
  ) {
    return selfLink(resourceUrl(resourceType, recordId) + '/' + relName);
  }

  /** Links of a relationship object: its own linkage endpoint plus the related-resource endpoint. */
  public static Map<String, Object> relationshipLinks(
    String resourceType,
    Id recordId,
    String relName
  ) {
    String resUrl = resourceUrl(resourceType, recordId);
    return new Map<String, Object>{
      'self' => resUrl +
      '/relationships/' +
      relName,
      'related' => resUrl +
      '/' +
      relName
    };
  }

  /**
   * Serialize one record as a JSON:API resource object.
   * toManyData: relationship name -> (parent record Id -> resource identifiers),
   * populated only for relationships that were requested via ?include.
   */
  public static Map<String, Object> resource(
    SObject rec,
    JsonApiResourceDefinition def,
    JsonApiQueryParams qp,
    Map<String, Map<Id, List<Map<String, Object>>>> toManyData
  ) {
    Set<String> sparse = qp == null ? null : qp.sparseFor(def.resourceType);
    Map<String, Object> attrs = new Map<String, Object>();
    for (String jsonName : def.attributes.keySet()) {
      if (sparse != null && !sparse.contains(jsonName)) {
        continue;
      }
      attrs.put(jsonName, rec.get(def.attributes.get(jsonName)));
    }

    Map<String, Object> rels = new Map<String, Object>();
    for (String relName : def.relationships.keySet()) {
      if (sparse != null && !sparse.contains(relName)) {
        continue;
      }
      JsonApiResourceDefinition.Rel rel = def.relationships.get(relName);
      Map<String, Object> relObj = new Map<String, Object>{
        'links' => relationshipLinks(def.resourceType, rec.Id, relName)
      };
      if (!rel.isNested() && !rel.isToMany) {
        Id targetId = (Id) rec.get(rel.field);
        relObj.put(
          'data',
          targetId == null ? null : identifier(rel.targetType, targetId)
        );
      } else if (toManyData != null && toManyData.containsKey(relName)) {
        // direct to-many, or nested (linkage computed only when ?include'd)
        List<Map<String, Object>> linkage = toManyData.get(relName).get(rec.Id);
        if (linkage == null) {
          linkage = new List<Map<String, Object>>();
        }
        if (rel.isToMany == true) {
          relObj.put('data', linkage);
        } else {
          // nested path of only to-one hops resolves to to-one linkage
          relObj.put('data', linkage.isEmpty() ? null : linkage[0]);
        }
      }
      rels.put(relName, relObj);
    }

    Map<String, Object> res = new Map<String, Object>{
      'type' => def.resourceType,
      'id' => String.valueOf(rec.Id),
      'attributes' => attrs,
      'links' => selfLink(resourceUrl(def.resourceType, rec.Id))
    };
    if (!rels.isEmpty()) {
      res.put('relationships', rels);
    }
    return res;
  }

  /** Serialize a batch of records of the same type. */
  public static List<Map<String, Object>> resources(
    List<SObject> records,
    JsonApiResourceDefinition def,
    JsonApiQueryParams qp,
    Map<String, Map<Id, List<Map<String, Object>>>> toManyData
  ) {
    List<Map<String, Object>> data = new List<Map<String, Object>>();
    for (SObject rec : records) {
      data.add(resource(rec, def, qp, toManyData));
    }
    return data;
  }

  public static Map<String, Object> identifier(
    String resourceType,
    Id recordId
  ) {
    return new Map<String, Object>{
      'type' => resourceType,
      'id' => String.valueOf(recordId)
    };
  }

  /** Top-level document with data (and optionally links/meta/included). */
  public static Map<String, Object> document(
    Object data,
    Map<String, Object> links,
    Map<String, Object> meta,
    List<Map<String, Object>> included
  ) {
    Map<String, Object> doc = envelope();
    doc.put('data', data);
    if (links != null && !links.isEmpty()) {
      doc.put('links', links);
    }
    if (meta != null && !meta.isEmpty()) {
      doc.put('meta', meta);
    }
    if (included != null && !included.isEmpty()) {
      doc.put('included', included);
    }
    return doc;
  }

  /** Top-level error document. */
  public static Map<String, Object> errorDocument(List<JsonApiError> errors) {
    List<Map<String, Object>> errList = new List<Map<String, Object>>();
    for (JsonApiError e : errors) {
      errList.add(e.toMap());
    }
    Map<String, Object> doc = envelope();
    doc.put('errors', errList);
    return doc;
  }

  /** Top-level members every document carries. */
  private static Map<String, Object> envelope() {
    return new Map<String, Object>{
      'jsonapi' => new Map<String, Object>{ 'version' => '1.1' }
    };
  }
}
