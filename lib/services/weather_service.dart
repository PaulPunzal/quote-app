import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/geocode_result.dart';

/// A single "what's it like right now" reading, ready to show in the UI
/// and to feed into ReflectionEmbeddingService as a weather context id.
///
/// [isFromCache] is true whenever this reading did NOT come from a
/// fresh network call this time (i.e. we're offline or the request
/// failed and fell back to the last successful reading) — surface this
/// in the UI if you want to be upfront that it might be stale, but it's
/// still the most honest answer we have.
class WeatherSnapshot {
  final String conditionId; // matches a 'weather_*' id in context_options.json
  final String conditionLabel; // e.g. 'Rainy'
  final double? tempC;
  final String locationLabel;
  final bool isFromCache;

  const WeatherSnapshot({
    required this.conditionId,
    required this.conditionLabel,
    required this.tempC,
    required this.locationLabel,
    required this.isFromCache,
  });
}

/// Fetches current weather from Open-Meteo (free, no API key) for a
/// manually-configured city, maps it onto one of this app's precomputed
/// 'weather_*' context ids, and caches the last successful reading so
/// the app still has *something* to go on when offline.
///
/// This mirrors the rest of the app's storage pattern: everything lives
/// under a few SharedPreferences keys, no server, no account.
///
/// Location is set once (or changed anytime) via WeatherLocationScreen,
/// which resolves a typed city name to lat/lon using Open-Meteo's
/// geocoding endpoint — no GPS permission is ever requested.
class WeatherService {
  static const _keyLabel = 'weather_location_label';
  static const _keyLat = 'weather_location_lat';
  static const _keyLon = 'weather_location_lon';
  static const _keyLastConditionId = 'weather_last_condition_id';
  static const _keyLastTempC = 'weather_last_temp_c';
  static const _keyLastFetchedAt = 'weather_last_fetched_at';

  static const Map<String, String> _labels = {
    'weather_rainy': 'Rainy',
    'weather_clear': 'Clear',
    'weather_cloudy': 'Cloudy',
    'weather_cold': 'Cold',
    'weather_hot': 'Hot',
    'weather_stormy': 'Stormy',
  };

  final http.Client _client;

  WeatherService({http.Client? client}) : _client = client ?? http.Client();

  // ---------------------------------------------------------------------
  // Location setup
  // ---------------------------------------------------------------------

  /// Searches Open-Meteo's geocoding API for city name matches. Throws
  /// on network failure — let the settings screen show its own error,
  /// since silently returning [] there would look like "no matches"
  /// rather than "couldn't reach the network".
  Future<List<GeocodeResult>> searchCity(String query) async {
    final uri = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
      'name': query,
      'count': '5',
      'language': 'en',
      'format': 'json',
    });

    final response = await _client.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return const [];

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final results = decoded['results'] as List<dynamic>?;
    if (results == null) return const [];

    return results
        .map((e) => GeocodeResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveLocation(GeocodeResult result) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLabel, result.displayLabel);
    await prefs.setDouble(_keyLat, result.latitude);
    await prefs.setDouble(_keyLon, result.longitude);
    // The cached reading described the OLD location -- keep it around
    // is wrong, since it'd silently misattribute weather to a place
    // that's no longer configured. Clear it so the next fetch starts
    // fresh (and offline-before-first-fetch just means no weather
    // context yet, same as it is today).
    await prefs.remove(_keyLastConditionId);
    await prefs.remove(_keyLastTempC);
    await prefs.remove(_keyLastFetchedAt);
  }

  Future<String?> getSavedLocationLabel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyLabel);
  }

  Future<bool> hasLocationConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyLat) != null && prefs.getDouble(_keyLon) != null;
  }

  // ---------------------------------------------------------------------
  // Current weather
  // ---------------------------------------------------------------------

  /// Convenience for callers that only need the context id (e.g.
  /// ReflectionDailyService's weatherId parameter).
  Future<String?> currentConditionId() async {
    final snapshot = await currentSnapshot();
    return snapshot?.conditionId;
  }

  /// Tries a fresh network fetch; on any failure (offline, timeout,
  /// non-200, unexpected shape) falls back to the last successful
  /// reading cached on-device. Returns null only if there's no
  /// configured location, or there's no cached reading AND the network
  /// call also failed (e.g. first-ever launch with no connectivity).
  Future<WeatherSnapshot?> currentSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble(_keyLat);
    final lon = prefs.getDouble(_keyLon);
    final label = prefs.getString(_keyLabel);
    if (lat == null || lon == null || label == null) return null;

    String? conditionId;
    double? tempC;

    try {
      final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': '$lat',
        'longitude': '$lon',
        'current_weather': 'true',
      });
      final response =
          await _client.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final current = decoded['current_weather'] as Map<String, dynamic>?;
        if (current != null) {
          tempC = (current['temperature'] as num).toDouble();
          final code = (current['weathercode'] as num).toInt();
          conditionId = _mapToContextId(code, tempC);

          await prefs.setString(_keyLastConditionId, conditionId);
          await prefs.setDouble(_keyLastTempC, tempC);
          await prefs.setString(
              _keyLastFetchedAt, DateTime.now().toIso8601String());
        }
      }
    } catch (_) {
      // Offline, timed out, or the API hiccupped -- fall through to
      // whatever we last cached below rather than surfacing an error.
    }

    var isFromCache = false;
    if (conditionId == null) {
      conditionId = prefs.getString(_keyLastConditionId);
      tempC = prefs.getDouble(_keyLastTempC);
      isFromCache = true;
    }

    if (conditionId == null) return null;

    return WeatherSnapshot(
      conditionId: conditionId,
      conditionLabel: _labels[conditionId] ?? conditionId,
      tempC: tempC,
      locationLabel: label,
      isFromCache: isFromCache,
    );
  }

  /// Maps an Open-Meteo WMO weather code + temperature (°C) onto one of
  /// this app's precomputed 'weather_*' context ids. Precipitation/storm
  /// codes take priority over temperature (a rainy 32°C day is "rainy",
  /// not "hot"); for anything else, temperature can push clear/cloudy
  /// conditions into 'hot' or 'cold' at the extremes.
  static String _mapToContextId(int code, double tempC) {
    // Thunderstorm
    if (code == 95 || code == 96 || code == 99) return 'weather_stormy';
    // Snow / snow showers
    if ((code >= 71 && code <= 77) || code == 85 || code == 86) {
      return 'weather_cold';
    }
    // Drizzle, rain, rain showers
    if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) {
      return 'weather_rainy';
    }
    // Fog
    if (code == 45 || code == 48) return 'weather_cloudy';

    // Clear (0), mainly clear (1), partly cloudy (2), overcast (3) --
    // temperature extremes override the sky description.
    if (tempC >= 32) return 'weather_hot';
    if (tempC <= 10) return 'weather_cold';
    if (code == 0 || code == 1) return 'weather_clear';
    return 'weather_cloudy';
  }
}