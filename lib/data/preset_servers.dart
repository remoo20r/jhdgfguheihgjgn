/// Built-in Xtream servers the user can pick by name.
///
/// The [host] URL is never shown in the UI: the login screen lists only the
/// [name], and the selected server's host is used behind the scenes when the
/// profile is created. To add or change a server, edit this list only.
class PresetServer {
  const PresetServer({required this.name, required this.host});

  /// Display name shown to the user (e.g. "Bella TV").
  final String name;

  /// Xtream server base URL — hidden from the user.
  final String host;
}

/// The servers offered on the login screen, in display order.
const List<PresetServer> kPresetServers = [
  PresetServer(name: 'Bella TV', host: 'http://arabesktv.com:2095'),
  PresetServer(name: 'Royal TV', host: 'http://mhav56789.com:80'),
  PresetServer(name: 'Tron TV', host: 'http://fgtqsprr.superff.xyz'),
];
