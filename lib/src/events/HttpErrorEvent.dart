part of discord;

/// Sent when a failed HTTP response is received.
class HttpErrorEvent {
  /// The HTTP request;
  HttpRequest request;

  /// The HTTP response.
  w_transport.Response response;

  HttpErrorEvent._new(Client client, this.request, this.response) {
    client._events.onHttpError.add(this);
  }
}