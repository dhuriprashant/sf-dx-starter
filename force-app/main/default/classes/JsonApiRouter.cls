/**
 * Apex REST entry point for the JSON:API framework.
 *
 * Routes (relative to /services/apexrest/jsonapi):
 *   GET    /                                → registered resource types (meta)
 *   GET    /{type}                          → list (include, fields, sort, page, filter)
 *   GET    /{type}/{id}                     → single resource
 *   GET    /{type}/{id}/{rel}               → related resource(s)
 *   GET    /{type}/{id}/relationships/{rel} → relationship linkage
 *   POST   /{type}                          → create
 *   PATCH  /{type}/{id}                     → update
 *   PATCH  /{type}/{id}/relationships/{rel} → replace to-one linkage
 *   DELETE /{type}/{id}                     → delete
 */
@RestResource(urlMapping='/jsonapi/*')
global with sharing class JsonApiRouter {
    public static final String MEDIA_TYPE = 'application/vnd.api+json';

    @HttpGet
    global static void doGet() {
        handle('GET');
    }

    @HttpPost
    global static void doPost() {
        handle('POST');
    }

    @HttpPatch
    global static void doPatch() {
        handle('PATCH');
    }

    @HttpDelete
    global static void doDelete() {
        handle('DELETE');
    }

    private static void handle(String method) {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', MEDIA_TYPE);
        try {
            JsonApiConfig.registerAll();
            checkHeaders(req, method);
            route(method, req, res);
        } catch (JsonApiException e) {
            writeErrors(res, e.status, new List<JsonApiError>{ JsonApiError.fromException(e) });
        } catch (System.QueryException e) {
            writeErrors(res, 400, new List<JsonApiError>{ JsonApiError.internal(e) });
        } catch (System.DmlException e) {
            JsonApiError err = new JsonApiError();
            err.status = '422';
            err.title = 'Unprocessable Content';
            err.detail = e.getDmlMessage(0);
            err.code = String.valueOf(e.getDmlType(0));
            writeErrors(res, 422, new List<JsonApiError>{ err });
        } catch (Exception e) {
            writeErrors(res, 500, new List<JsonApiError>{ JsonApiError.internal(e) });
        }
    }

    private static void route(String method, RestRequest req, RestResponse res) {
        List<String> seg = pathSegments(req);

        if (seg.isEmpty()) {
            if (method != 'GET') {
                throw JsonApiException.methodNotAllowed(method + ' is not allowed on the API root.');
            }
            writeDocument(res, 200, JsonApiSerializer.document(
                null,
                new Map<String, Object>{ 'self' => JsonApiSerializer.baseUrl() },
                new Map<String, Object>{ 'resourceTypes' => new List<String>(JsonApiRegistry.registeredTypes()) },
                null
            ));
            return;
        }

        JsonApiResourceDefinition def = JsonApiRegistry.get(seg[0]);
        JsonApiQueryParams qp = JsonApiQueryParams.parse(req.params, def);

        if (method == 'GET') {
            if (seg.size() == 1) {
                writeDocument(res, 200, JsonApiService.listResources(def, qp));
            } else if (seg.size() == 2) {
                writeDocument(res, 200, JsonApiService.getResource(def, toId(seg[1]), qp));
            } else if (seg.size() == 3) {
                writeDocument(res, 200, JsonApiService.getRelated(def, toId(seg[1]), seg[2], qp));
            } else if (seg.size() == 4 && seg[2] == 'relationships') {
                writeDocument(res, 200, JsonApiService.getRelationship(def, toId(seg[1]), seg[3]));
            } else {
                throw JsonApiException.notFound('Unrecognized path.');
            }
        } else if (method == 'POST') {
            if (seg.size() != 1) {
                throw JsonApiException.methodNotAllowed('POST is only allowed on collection endpoints.');
            }
            Map<String, Object> doc = JsonApiService.createResource(def, requestBody(req));
            Map<String, Object> created = (Map<String, Object>) doc.get('data');
            res.addHeader('Location', (String) ((Map<String, Object>) created.get('links')).get('self'));
            writeDocument(res, 201, doc);
        } else if (method == 'PATCH') {
            if (seg.size() == 2) {
                writeDocument(res, 200, JsonApiService.updateResource(def, toId(seg[1]), requestBody(req)));
            } else if (seg.size() == 4 && seg[2] == 'relationships') {
                writeDocument(res, 200, JsonApiService.patchRelationship(def, toId(seg[1]), seg[3], requestBody(req)));
            } else {
                throw JsonApiException.methodNotAllowed('PATCH is only allowed on resource or relationship endpoints.');
            }
        } else if (method == 'DELETE') {
            if (seg.size() != 2) {
                throw JsonApiException.methodNotAllowed('DELETE is only allowed on resource endpoints.');
            }
            JsonApiService.deleteResource(def, toId(seg[1]));
            res.statusCode = 204;
        }
    }

    private static List<String> pathSegments(RestRequest req) {
        String uri = req.requestURI == null ? '' : req.requestURI;
        Integer idx = uri.indexOf('/jsonapi');
        String path = idx >= 0 ? uri.substring(idx + 8) : uri;
        path = path.removeStart('/').removeEnd('/');
        List<String> segments = new List<String>();
        if (String.isNotBlank(path)) {
            for (String s : path.split('/')) {
                segments.add(EncodingUtil.urlDecode(s, 'UTF-8'));
            }
        }
        return segments;
    }

    private static Id toId(String raw) {
        try {
            return Id.valueOf(raw);
        } catch (Exception e) {
            throw JsonApiException.notFound('Invalid resource id: ' + raw);
        }
    }

    private static Map<String, Object> requestBody(RestRequest req) {
        if (req.requestBody == null || req.requestBody.size() == 0) {
            throw JsonApiException.badRequest('Request body is required.');
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(req.requestBody.toString());
        } catch (Exception e) {
            throw JsonApiException.badRequest('Request body is not valid JSON: ' + e.getMessage());
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw JsonApiException.badRequest('Request body must be a JSON object.');
        }
        return (Map<String, Object>) parsed;
    }

    private static void checkHeaders(RestRequest req, String method) {
        if (method == 'POST' || method == 'PATCH') {
            String contentType = req.headers.get('Content-Type');
            if (contentType != null && !contentType.contains(MEDIA_TYPE) && !contentType.contains('application/json')) {
                throw JsonApiException.unsupportedMediaType('Content-Type must be ' + MEDIA_TYPE);
            }
        }
        String accept = req.headers.get('Accept');
        if (accept != null) {
            Boolean acceptable = false;
            for (String part : accept.split(',')) {
                String mediaRange = part.trim().split(';')[0].trim();
                if (mediaRange == MEDIA_TYPE || mediaRange == '*/*' || mediaRange == 'application/*' || mediaRange == 'application/json') {
                    acceptable = true;
                    break;
                }
            }
            if (!acceptable) {
                throw JsonApiException.notAcceptable('Accept header must allow ' + MEDIA_TYPE);
            }
        }
    }

    private static void writeDocument(RestResponse res, Integer status, Map<String, Object> doc) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf(JSON.serialize(doc));
    }

    private static void writeErrors(RestResponse res, Integer status, List<JsonApiError> errors) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf(JSON.serialize(JsonApiSerializer.errorDocument(errors)));
    }
}
