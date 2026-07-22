import 'package:dio/dio.dart';

/// Shared Italian message for a failed panel HTTP call (was duplicated in
/// XtreamSession and XtreamApiService).
String messageForDioError(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return 'Timeout: the server did not respond in time.';
    case DioExceptionType.connectionError:
      // Surface the underlying reason: on Android the same panel can fail for
      // DNS/refused/TLS reasons that a generic message would hide, making it
      // impossible to tell a network issue from an old-device cert issue.
      return 'Impossibile raggiungere il server. ${describeConnectionError(e)}';
    case DioExceptionType.badResponse:
      return 'Il server ha risposto con un errore (${e.response?.statusCode ?? '?'}).';
    default:
      return 'Connection error: ${e.message ?? describeConnectionError(e)}';
  }
}

/// Turns the opaque underlying error of a Dio [DioException] (usually a
/// SocketException / HandshakeException / OS error) into a short, actionable
/// Italian hint plus the raw detail.
///
/// This matters most on Android: the same panel that works on Windows can fail
/// for DNS, refused-connection or TLS-certificate reasons, and the generic
/// "Impossibile raggiungere il server" hides which one it is. Showing the real
/// cause is the difference between "wrong link", "wrong network", and
/// "certificato non valido su un device vecchio".
String describeConnectionError(DioException e) {
  final raw = (e.error?.toString() ?? e.message ?? '').trim();
  final lower = raw.toLowerCase();

  String hint;
  if (lower.contains('cleartext')) {
    hint = 'HTTP in chiaro bloccato dal sistema.';
  } else if (lower.contains('failed host lookup') ||
      lower.contains('nodename') ||
      lower.contains('no address associated') ||
      lower.contains('name or service not known')) {
    hint = 'Host non risolto (DNS): link errato o rete senza DNS.';
  } else if (lower.contains('connection refused')) {
    hint = 'Connection refused: port closed or wrong host/port.';
  } else if (lower.contains('network is unreachable') ||
      lower.contains('no route to host')) {
    hint = 'Network unreachable from this device.';
  } else if (lower.contains('connection reset') ||
      lower.contains('connection closed') ||
      lower.contains('connection terminated')) {
    hint = 'Connection interrupted by the server or network.';
  } else if (lower.contains('handshake') ||
      lower.contains('certificate') ||
      lower.contains('tls') ||
      lower.contains('ssl')) {
    hint = 'Invalid TLS certificate on this device '
        '(https panel on old Android?).';
  } else if (lower.contains('timed out') || lower.contains('timeout')) {
    hint = 'The server did not respond in time.';
  } else {
    hint = 'Check the link, port and network.';
  }

  // Keep the raw reason visible (trimmed) so a real device can report the exact
  // cause back to us.
  final detail = raw.isEmpty
      ? ''
      : ' [${raw.length > 160 ? '${raw.substring(0, 160)}…' : raw}]';
  return '$hint$detail';
}
