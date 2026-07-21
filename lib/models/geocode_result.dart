/// One candidate returned by Open-Meteo's geocoding search — used only
/// during the one-time (or change-anytime) "set my city" flow in
/// WeatherLocationScreen. Once picked, only its label/lat/lon get
/// persisted; this class itself is never stored.
class GeocodeResult {
  final String name;
  final String? admin1; // state/province/region, when Open-Meteo has one
  final String? country;
  final double latitude;
  final double longitude;

  const GeocodeResult({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.admin1,
    this.country,
  });

  factory GeocodeResult.fromJson(Map<String, dynamic> json) {
    return GeocodeResult(
      name: json['name'] as String,
      admin1: json['admin1'] as String?,
      country: json['country'] as String?,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
    );
  }

  /// Human-readable label, e.g. "San Jose del Monte, Central Luzon,
  /// Philippines" — used both in the picker list and as the saved
  /// location label shown elsewhere in the app.
  String get displayLabel {
    final parts = [name, if (admin1 != null) admin1!, if (country != null) country!];
    return parts.join(', ');
  }
}