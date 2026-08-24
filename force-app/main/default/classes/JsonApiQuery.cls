/**
 * Shared SOQL construction and transaction-limit guards for the JSON:API framework.
 * Every query runs in USER_MODE and is capped at the remaining query-row budget so
 * an oversized result surfaces as a clean 400 instead of an uncatchable limit error.
 */
public with sharing class JsonApiQuery {
  /** 'SELECT <definition fields> FROM <sobject>' for a resource definition. */
  public static String selectFrom(JsonApiResourceDefinition def) {
    return selectFrom(def, new Set<String>());
  }

  /** As selectFrom, with extra fields (e.g. a child foreign key) added to the projection. */
  public static String selectFrom(
    JsonApiResourceDefinition def,
    Set<String> extraFields
  ) {
    Set<String> fields = new Set<String>(def.getSelectFields());
    fields.addAll(extraFields);
    return 'SELECT ' +
      String.join(new List<String>(fields), ', ') +
      ' FROM ' +
      def.sobjectName;
  }

  /** One record by Id; empty when it does not exist or is not visible to the user. */
  public static List<SObject> byId(JsonApiResourceDefinition def, Id recordId) {
    return Database.queryWithBinds(
      selectFrom(def) + ' WHERE Id = :jsonApiId LIMIT 1',
      new Map<String, Object>{ 'jsonApiId' => recordId },
      AccessLevel.USER_MODE
    );
  }

  public static List<SObject> byIds(
    JsonApiResourceDefinition def,
    Set<Id> ids
  ) {
    return runCapped(
      selectFrom(def) + ' WHERE Id IN :jsonApiIds',
      new Map<String, Object>{ 'jsonApiIds' => ids }
    );
  }

  /** Bulk child fetch: the child definition's fields plus the foreign key it is filtered on. */
  public static List<SObject> children(
    JsonApiResourceDefinition childDef,
    String fkField,
    Set<Id> parentIds
  ) {
    return runCapped(
      selectFrom(childDef, new Set<String>{ fkField }) +
        ' WHERE ' +
        fkField +
        ' IN :jsonApiParentIds',
      new Map<String, Object>{ 'jsonApiParentIds' => parentIds }
    );
  }

  /**
   * Run a query capped at the remaining row budget. Filling the cap is treated as
   * truncation, since the rows beyond it would silently go missing.
   */
  public static List<SObject> runCapped(
    String soql,
    Map<String, Object> binds
  ) {
    Integer budget = rowBudget();
    List<SObject> recs = queryWithLimit(soql, binds, 'jsonApiBudget', budget);
    if (recs.size() >= budget) {
      throw resultSetTooLarge();
    }
    checkHeapHeadroom();
    return recs;
  }

  /** Run a query with an explicit row limit, which must fit in the remaining budget. */
  public static List<SObject> runLimited(
    String soql,
    Map<String, Object> binds,
    Integer rowLimit
  ) {
    if (rowLimit > rowBudget()) {
      throw resultSetTooLarge();
    }
    List<SObject> recs = queryWithLimit(soql, binds, 'jsonApiLimit', rowLimit);
    checkHeapHeadroom();
    return recs;
  }

  private static List<SObject> queryWithLimit(
    String soql,
    Map<String, Object> binds,
    String limitBind,
    Integer rowLimit
  ) {
    Map<String, Object> allBinds = new Map<String, Object>(binds);
    allBinds.put(limitBind, rowLimit);
    return Database.queryWithBinds(
      soql + ' LIMIT :' + limitBind,
      allBinds,
      AccessLevel.USER_MODE
    );
  }

  /** Remaining query-row budget; throws if already exhausted. */
  private static Integer rowBudget() {
    Integer budget = Limits.getLimitQueryRows() - Limits.getQueryRows();
    if (budget <= 0) {
      throw resultSetTooLarge();
    }
    return budget;
  }

  private static JsonApiException resultSetTooLarge() {
    return JsonApiException.of(
      400,
      'Result Set Too Large',
      'Matching records exceed the transaction query row limit; narrow the result with filter[...], request a smaller page[size], or reduce ?include.'
    );
  }

  /**
   * Serializing roughly triples the records' footprint (SObjects, document maps,
   * JSON string), so require that headroom now and fail with a clean 400 while
   * the error document can still be built — a heap LimitException is uncatchable.
   */
  private static void checkHeapHeadroom() {
    if (Limits.getHeapSize() * 3 > Limits.getLimitHeapSize()) {
      throw JsonApiException.of(
        400,
        'Response Too Large',
        'The response would exceed the transaction heap limit; narrow the result with filter[...], request a smaller page[size], or reduce ?include.'
      );
    }
  }
}
