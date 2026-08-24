/**
 * Exception type carrying JSON:API error semantics (HTTP status, title, source pointer).
 * Use the static factories so errors render correctly in the error document.
 */
public class JsonApiException extends Exception {
  public Integer status = 500;
  public String title = 'Internal Server Error';
  public String errorCode;
  public String sourcePointer;
  public String sourceParameter;

  public static JsonApiException of(
    Integer status,
    String title,
    String detail
  ) {
    JsonApiException e = new JsonApiException(detail);
    e.status = status;
    e.title = title;
    return e;
  }

  public static JsonApiException badRequest(String detail) {
    return of(400, 'Bad Request', detail);
  }

  public static JsonApiException badParameter(String detail, String parameter) {
    JsonApiException e = of(400, 'Invalid Query Parameter', detail);
    e.sourceParameter = parameter;
    return e;
  }

  public static JsonApiException notFound(String detail) {
    return of(404, 'Not Found', detail);
  }

  public static JsonApiException conflict(String detail) {
    return of(409, 'Conflict', detail);
  }

  public static JsonApiException forbidden(String detail) {
    return of(403, 'Forbidden', detail);
  }

  public static JsonApiException unsupportedMediaType(String detail) {
    return of(415, 'Unsupported Media Type', detail);
  }

  public static JsonApiException notAcceptable(String detail) {
    return of(406, 'Not Acceptable', detail);
  }

  public static JsonApiException methodNotAllowed(String detail) {
    return of(405, 'Method Not Allowed', detail);
  }

  public JsonApiException withPointer(String pointer) {
    this.sourcePointer = pointer;
    return this;
  }
}
