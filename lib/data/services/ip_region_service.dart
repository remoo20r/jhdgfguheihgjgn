import 'package:dio/dio.dart';

String? _cachedRegion;
bool _fetched = false;

/// Returns the viewer's region (state / province / governorate — NOT the city,
/// which is often the ISP's exit node and misleading). Best-effort over the
/// public ipapi.co service; returns null on any failure so callers can just
/// hide the region. Cached after the first successful lookup.
Future<String?> fetchIpRegion() async {
  if (_fetched) return _cachedRegion;
  try {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 6),
    ));
    final res = await dio.get('https://ipapi.co/json/');
    if (res.statusCode == 200 && res.data is Map) {
      final data = res.data as Map;
      final region = (data['region'] as String?)?.trim();
      final country = (data['country_name'] as String?)?.trim();
      _cachedRegion = (region != null && region.isNotEmpty)
          ? region
          : (country != null && country.isNotEmpty ? country : null);
    }
  } catch (_) {
    _cachedRegion = null;
  }
  _fetched = true;
  return _cachedRegion;
}
