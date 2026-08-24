/**
 * Builds JSON:API error objects (https://jsonapi.org/format/#error-objects).
 */
public class JsonApiError {
  public String status;
  public String code;
  public String title;
  public String detail;
  public String sourcePointer;
  public String sourceParameter;

  public static JsonApiError fromException(JsonApiException ex) {
    JsonApiError err = new JsonApiError();
    err.status = String.valueOf(ex.status);
    err.code = ex.errorCode;
    err.title = ex.title;
    err.detail = ex.getMessage();
    err.sourcePointer = ex.sourcePointer;
    err.sourceParameter = ex.sourceParameter;
    return err;
  }

  public static JsonApiError internal(Exception ex) {
    JsonApiError err = new JsonApiError();
    err.status = '500';
    err.title = 'Internal Server Error';
    err.detail = ex.getMessage();
    return err;
  }

  public Map<String, Object> toMap() {
    Map<String, Object> m = new Map<String, Object>{
      'status' => status,
      'title' => title
    };
    if (detail != null) {
      m.put('detail', detail);
    }
    if (code != null) {
      m.put('code', code);
    }
    Map<String, Object> src = new Map<String, Object>();
    if (sourcePointer != null) {
      src.put('pointer', sourcePointer);
    }
    if (sourceParameter != null) {
      src.put('parameter', sourceParameter);
    }
    if (!src.isEmpty()) {
      m.put('source', src);
    }
    return m;
  }
}
