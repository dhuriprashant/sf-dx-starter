@IsTest
private class JsonApiRouterTest {
  private static RestResponse invoke(
    String method,
    String path,
    String body,
    Map<String, String> params
  ) {
    RestRequest req = new RestRequest();
    req.requestURI = '/services/apexrest/jsonapi' + path;
    req.httpMethod = method;
    req.headers.put('Content-Type', 'application/vnd.api+json');
    if (body != null) {
      req.requestBody = Blob.valueOf(body);
    }
    if (params != null) {
      req.params.putAll(params);
    }
    RestContext.request = req;
    RestContext.response = new RestResponse();
    if (method == 'GET') {
      JsonApiRouter.doGet();
    } else if (method == 'POST') {
      JsonApiRouter.doPost();
    } else if (method == 'PATCH') {
      JsonApiRouter.doPatch();
    } else if (method == 'DELETE') {
      JsonApiRouter.doDelete();
    }
    return RestContext.response;
  }

  private static Map<String, Object> parse(RestResponse res) {
    return (Map<String, Object>) JSON.deserializeUntyped(
      res.responseBody.toString()
    );
  }

  private static Account makeAccount(String name) {
    return new Account(Name = name);
  }

  @IsTest
  static void listsResourcesWithPaginationAndSort() {
    insert new List<Account>{
      makeAccount('Alpha'),
      makeAccount('Bravo'),
      makeAccount('Charlie')
    };

    RestResponse res = invoke(
      'GET',
      '/accounts',
      null,
      new Map<String, String>{ 'page[size]' => '2', 'sort' => '-name' }
    );

    Assert.areEqual(200, res.statusCode);
    Map<String, Object> doc = parse(res);
    List<Object> data = (List<Object>) doc.get('data');
    Assert.areEqual(2, data.size(), 'page size should be applied');
    Map<String, Object> first = (Map<String, Object>) data[0];
    Assert.areEqual('accounts', first.get('type'));
    Assert.areEqual(
      'Charlie',
      ((Map<String, Object>) first.get('attributes')).get('name')
    );
    Map<String, Object> meta = (Map<String, Object>) doc.get('meta');
    Assert.isFalse(
      meta.containsKey('totalResources'),
      'paginated responses carry no totals'
    );
    Assert.areEqual(2, meta.get('pageSize'));
    Map<String, Object> links = (Map<String, Object>) doc.get('links');
    Assert.isFalse(
      links.containsKey('next'),
      'sorted pages are not walkable: no next link'
    );
    Assert.isFalse(links.containsKey('last'), 'last link requires a total');
  }

  @IsTest
  static void rejectsPageNumber() {
    RestResponse res = invoke(
      'GET',
      '/accounts',
      null,
      new Map<String, String>{ 'page[size]' => '2', 'page[number]' => '2' }
    );

    Assert.areEqual(400, res.statusCode, 'offset pagination is not supported');
  }

  @IsTest
  static void cursorPaginationWalksCollection() {
    insert new List<Account>{
      makeAccount('Alpha'),
      makeAccount('Bravo'),
      makeAccount('Charlie')
    };

    RestResponse res = invoke(
      'GET',
      '/accounts',
      null,
      new Map<String, String>{ 'page[size]' => '2' }
    );

    Assert.areEqual(200, res.statusCode);
    Map<String, Object> doc = parse(res);
    List<Object> data = (List<Object>) doc.get('data');
    Assert.areEqual(2, data.size());
    Map<String, Object> links = (Map<String, Object>) doc.get('links');
    String next = (String) links.get('next');
    String lastId = (String) ((Map<String, Object>) data[1]).get('id');
    Assert.isTrue(
      next.contains('page%5Bafter%5D=' + lastId),
      'next link should carry the last record Id as cursor'
    );

    res = invoke(
      'GET',
      '/accounts',
      null,
      new Map<String, String>{ 'page[size]' => '2', 'page[after]' => lastId }
    );

    Assert.areEqual(200, res.statusCode);
    doc = parse(res);
    data = (List<Object>) doc.get('data');
    Assert.areEqual(
      1,
      data.size(),
      'cursor should resume after the last seen record'
    );
    Assert.isTrue(
      String.valueOf(((Map<String, Object>) data[0]).get('id')) > lastId,
      'walk must be strictly forward by Id'
    );
    links = (Map<String, Object>) doc.get('links');
    Assert.isFalse(
      links.containsKey('next'),
      'no next link at the end of the walk'
    );
    Map<String, Object> meta = (Map<String, Object>) doc.get('meta');
    Assert.isFalse(
      meta.containsKey('pageNumber'),
      'cursor pages carry no page number'
    );
  }

  @IsTest
  static void rejectsCursorCombinedWithSort() {
    RestResponse res = invoke(
      'GET',
      '/accounts',
      null,
      new Map<String, String>{
        'page[size]' => '2',
        'page[after]' => '001000000000001AAA',
        'sort' => 'name'
      }
    );

    Assert.areEqual(400, res.statusCode);
  }

  @IsTest
  static void getsSingleResourceWithInclude() {
    Account acc = makeAccount('Acme');
    insert acc;
    insert new List<Contact>{
      new Contact(LastName = 'One', AccountId = acc.Id),
      new Contact(LastName = 'Two', AccountId = acc.Id)
    };

    RestResponse res = invoke(
      'GET',
      '/accounts/' + acc.Id,
      null,
      new Map<String, String>{ 'include' => 'contacts' }
    );

    Assert.areEqual(200, res.statusCode);
    Map<String, Object> doc = parse(res);
    Map<String, Object> data = (Map<String, Object>) doc.get('data');
    Assert.areEqual(String.valueOf(acc.Id), data.get('id'));
    List<Object> included = (List<Object>) doc.get('included');
    Assert.areEqual(2, included.size(), 'both contacts should be included');
    Map<String, Object> rels = (Map<String, Object>) data.get('relationships');
    Map<String, Object> contactsRel = (Map<String, Object>) rels.get(
      'contacts'
    );
    Assert.areEqual(
      2,
      ((List<Object>) contactsRel.get('data')).size(),
      'to-many linkage expected when included'
    );
  }

  @IsTest
  static void filtersAndSparseFieldsets() {
    insert new List<Account>{ makeAccount('Acme'), makeAccount('Globex') };

    RestResponse res = invoke(
      'GET',
      '/accounts',
      null,
      new Map<String, String>{
        'filter[name]' => 'Acme',
        'fields[accounts]' => 'name'
      }
    );

    Map<String, Object> doc = parse(res);
    List<Object> data = (List<Object>) doc.get('data');
    Assert.areEqual(1, data.size());
    Map<String, Object> attrs = (Map<String, Object>) ((Map<String, Object>) data[0])
      .get('attributes');
    Assert.areEqual('Acme', attrs.get('name'));
    Assert.isFalse(
      attrs.containsKey('industry'),
      'sparse fieldset should drop industry'
    );
  }

  @IsTest
  static void createsResourceWithRelationship() {
    Account acc = makeAccount('Acme');
    insert acc;
    String body = JSON.serialize(
      new Map<String, Object>{
        'data' => new Map<String, Object>{
          'type' => 'contacts',
          'attributes' => new Map<String, Object>{
            'firstName' => 'Ada',
            'lastName' => 'Lovelace'
          },
          'relationships' => new Map<String, Object>{
            'account' => new Map<String, Object>{
              'data' => new Map<String, Object>{
                'type' => 'accounts',
                'id' => String.valueOf(acc.Id)
              }
            }
          }
        }
      }
    );

    RestResponse res = invoke('POST', '/contacts', body, null);

    Assert.areEqual(201, res.statusCode);
    Assert.isNotNull(
      res.headers.get('Location'),
      'Location header expected on create'
    );
    Map<String, Object> data = (Map<String, Object>) parse(res).get('data');
    Contact created = [
      SELECT LastName, AccountId
      FROM Contact
      WHERE Id = :(String) data.get('id')
    ];
    Assert.areEqual('Lovelace', created.LastName);
    Assert.areEqual(acc.Id, created.AccountId);
  }

  @IsTest
  static void updatesAndDeletesResource() {
    Account acc = makeAccount('Before');
    insert acc;
    String body = JSON.serialize(
      new Map<String, Object>{
        'data' => new Map<String, Object>{
          'type' => 'accounts',
          'id' => String.valueOf(acc.Id),
          'attributes' => new Map<String, Object>{ 'name' => 'After' }
        }
      }
    );

    RestResponse res = invoke('PATCH', '/accounts/' + acc.Id, body, null);
    Assert.areEqual(200, res.statusCode);
    Assert.areEqual(
      'After',
      [SELECT Name FROM Account WHERE Id = :acc.Id].Name
    );

    res = invoke('DELETE', '/accounts/' + acc.Id, null, null);
    Assert.areEqual(204, res.statusCode);
    Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Id = :acc.Id]);
  }

  @IsTest
  static void servesRelationshipEndpoints() {
    Account acc = makeAccount('Acme');
    insert acc;
    Contact con = new Contact(LastName = 'One', AccountId = acc.Id);
    insert con;

    RestResponse res = invoke(
      'GET',
      '/accounts/' + acc.Id + '/relationships/contacts',
      null,
      null
    );
    Assert.areEqual(200, res.statusCode);
    List<Object> linkage = (List<Object>) parse(res).get('data');
    Assert.areEqual(1, linkage.size());
    Assert.areEqual('contacts', ((Map<String, Object>) linkage[0]).get('type'));

    res = invoke('GET', '/accounts/' + acc.Id + '/contacts', null, null);
    Assert.areEqual(200, res.statusCode);
    Assert.areEqual(1, ((List<Object>) parse(res).get('data')).size());

    // clear the to-one linkage from the contact side
    String body = JSON.serialize(new Map<String, Object>{ 'data' => null });
    res = invoke(
      'PATCH',
      '/contacts/' + con.Id + '/relationships/account',
      body,
      null
    );
    Assert.areEqual(200, res.statusCode);
    Assert.isNull([SELECT AccountId FROM Contact WHERE Id = :con.Id].AccountId);
  }

  @IsTest
  static void includesNestedRelationshipWithoutIntermediates() {
    Account acc = makeAccount('Acme');
    Account other = makeAccount('Globex');
    insert new List<Account>{ acc, other };
    Contact manager = new Contact(LastName = 'Manager', AccountId = other.Id);
    insert manager;
    insert new List<Contact>{
      new Contact(
        LastName = 'ReportOne',
        AccountId = acc.Id,
        ReportsToId = manager.Id
      ),
      new Contact(
        LastName = 'ReportTwo',
        AccountId = acc.Id,
        ReportsToId = manager.Id
      )
    };

    RestResponse res = invoke(
      'GET',
      '/accounts/' + acc.Id,
      null,
      new Map<String, String>{ 'include' => 'contactManagers' }
    );

    Assert.areEqual(200, res.statusCode);
    Map<String, Object> doc = parse(res);
    List<Object> included = (List<Object>) doc.get('included');
    Assert.areEqual(
      1,
      included.size(),
      'only the final-hop manager should be included, not the intermediate contacts'
    );
    Map<String, Object> managerRes = (Map<String, Object>) included[0];
    Assert.areEqual(String.valueOf(manager.Id), managerRes.get('id'));
    Assert.areEqual(
      'Manager',
      ((Map<String, Object>) managerRes.get('attributes')).get('lastName')
    );

    Map<String, Object> data = (Map<String, Object>) doc.get('data');
    Map<String, Object> rels = (Map<String, Object>) data.get('relationships');
    Map<String, Object> nestedRel = (Map<String, Object>) rels.get(
      'contactManagers'
    );
    List<Object> linkage = (List<Object>) nestedRel.get('data');
    Assert.areEqual(
      1,
      linkage.size(),
      'the shared manager should be linked once'
    );
    Assert.areEqual(
      String.valueOf(manager.Id),
      ((Map<String, Object>) linkage[0]).get('id')
    );
  }

  @IsTest
  static void servesNestedRelationshipEndpoints() {
    Account acc = makeAccount('Acme');
    insert acc;
    Contact manager = new Contact(LastName = 'Manager');
    insert manager;
    insert new Contact(
      LastName = 'Report',
      AccountId = acc.Id,
      ReportsToId = manager.Id
    );

    RestResponse res = invoke(
      'GET',
      '/accounts/' + acc.Id + '/contactManagers',
      null,
      null
    );
    Assert.areEqual(200, res.statusCode);
    List<Object> related = (List<Object>) parse(res).get('data');
    Assert.areEqual(1, related.size());
    Assert.areEqual(
      String.valueOf(manager.Id),
      ((Map<String, Object>) related[0]).get('id')
    );

    res = invoke(
      'GET',
      '/accounts/' + acc.Id + '/relationships/contactManagers',
      null,
      null
    );
    Assert.areEqual(200, res.statusCode);
    List<Object> linkage = (List<Object>) parse(res).get('data');
    Assert.areEqual(1, linkage.size());
    Assert.areEqual('contacts', ((Map<String, Object>) linkage[0]).get('type'));

    String body = JSON.serialize(new Map<String, Object>{ 'data' => null });
    res = invoke(
      'PATCH',
      '/accounts/' + acc.Id + '/relationships/contactManagers',
      body,
      null
    );
    Assert.areEqual(403, res.statusCode, 'nested relationships are read-only');
  }

  @IsTest
  static void includesDotPathWithIntermediates() {
    Account acc = makeAccount('Acme');
    insert acc;
    Contact manager = new Contact(LastName = 'Manager');
    insert manager;
    Contact report = new Contact(
      LastName = 'Report',
      AccountId = acc.Id,
      ReportsToId = manager.Id
    );
    insert report;

    RestResponse res = invoke(
      'GET',
      '/accounts/' + acc.Id,
      null,
      new Map<String, String>{ 'include' => 'contacts.reportsTo' }
    );

    Assert.areEqual(200, res.statusCode);
    Map<String, Object> doc = parse(res);
    List<Object> included = (List<Object>) doc.get('included');
    Assert.areEqual(
      2,
      included.size(),
      'intermediate contact and leaf manager should both be included'
    );
    Set<String> includedIds = new Set<String>();
    for (Object o : included) {
      Map<String, Object> resc = (Map<String, Object>) o;
      includedIds.add((String) resc.get('id'));
      if (resc.get('id') == String.valueOf(report.Id)) {
        // full linkage: the intermediate contact links to its manager
        Map<String, Object> rels = (Map<String, Object>) resc.get(
          'relationships'
        );
        Map<String, Object> linkage = (Map<String, Object>) ((Map<String, Object>) rels.get(
            'reportsTo'
          ))
          .get('data');
        Assert.areEqual(String.valueOf(manager.Id), linkage.get('id'));
      }
    }
    Assert.isTrue(includedIds.contains(String.valueOf(report.Id)));
    Assert.isTrue(includedIds.contains(String.valueOf(manager.Id)));
  }

  @IsTest
  static void dotPathEmitsToManyLinkageOnIncludedIntermediates() {
    Account acc = makeAccount('Acme');
    insert acc;
    Contact con = new Contact(LastName = 'One', AccountId = acc.Id);
    insert con;

    RestResponse res = invoke(
      'GET',
      '/contacts/' + con.Id,
      null,
      new Map<String, String>{ 'include' => 'account.contacts' }
    );

    Assert.areEqual(200, res.statusCode);
    Map<String, Object> doc = parse(res);
    List<Object> included = (List<Object>) doc.get('included');
    Assert.areEqual(
      1,
      included.size(),
      'the account is included; the primary contact must not be duplicated'
    );
    Map<String, Object> accRes = (Map<String, Object>) included[0];
    Assert.areEqual(String.valueOf(acc.Id), accRes.get('id'));
    Map<String, Object> rels = (Map<String, Object>) accRes.get(
      'relationships'
    );
    List<Object> linkage = (List<Object>) ((Map<String, Object>) rels.get(
        'contacts'
      ))
      .get('data');
    Assert.areEqual(
      1,
      linkage.size(),
      'included account should carry full to-many linkage'
    );
    Assert.areEqual(
      String.valueOf(con.Id),
      ((Map<String, Object>) linkage[0]).get('id')
    );
  }

  @IsTest
  static void returnsJsonApiErrors() {
    RestResponse res = invoke('GET', '/widgets', null, null);
    Assert.areEqual(404, res.statusCode);
    List<Object> errors = (List<Object>) parse(res).get('errors');
    Assert.areEqual('404', ((Map<String, Object>) errors[0]).get('status'));

    res = invoke(
      'GET',
      '/accounts',
      null,
      new Map<String, String>{ 'include' => 'nope' }
    );
    Assert.areEqual(400, res.statusCode);

    res = invoke(
      'GET',
      '/accounts',
      null,
      new Map<String, String>{ 'include' => 'contacts.nope' }
    );
    Assert.areEqual(
      400,
      res.statusCode,
      'unknown segment inside a dot-path should be rejected'
    );

    Account acc = makeAccount('Acme');
    insert acc;
    String mismatched = JSON.serialize(
      new Map<String, Object>{
        'data' => new Map<String, Object>{
          'type' => 'contacts',
          'attributes' => new Map<String, Object>{ 'lastName' => 'X' }
        }
      }
    );
    res = invoke('POST', '/accounts', mismatched, null);
    Assert.areEqual(409, res.statusCode, 'type mismatch should conflict');
  }

  @IsTest
  static void rejectsUnsupportedContentType() {
    RestRequest req = new RestRequest();
    req.requestURI = '/services/apexrest/jsonapi/accounts';
    req.httpMethod = 'POST';
    req.headers.put('Content-Type', 'text/plain');
    req.requestBody = Blob.valueOf('{}');
    RestContext.request = req;
    RestContext.response = new RestResponse();

    JsonApiRouter.doPost();

    Assert.areEqual(415, RestContext.response.statusCode);
  }

  @IsTest
  static void listsRegisteredTypesAtRoot() {
    RestResponse res = invoke('GET', '', null, null);
    Assert.areEqual(200, res.statusCode);
    Map<String, Object> meta = (Map<String, Object>) parse(res).get('meta');
    List<Object> types = (List<Object>) meta.get('resourceTypes');
    Assert.isTrue(types.contains('accounts'));
    Assert.isTrue(types.contains('contacts'));
  }
}
