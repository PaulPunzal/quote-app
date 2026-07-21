import 'package:flutter/material.dart';
import '../../../services/weather_service.dart';

/// The small "22°C, Hot in Marilao" line shown under the tab bar,
/// summarizing whatever weather reading last informed a pick.
///
/// [snapshot.locationLabel] is just the city name (see
/// WeatherService.saveLocation) — the fuller "city, region, country"
/// string is only ever shown in the search results when you're
/// disambiguating which city you meant, not here.
class WeatherStrip extends StatelessWidget {
  final WeatherSnapshot snapshot;

  const WeatherStrip({super.key, required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final tempPart =
        snapshot.tempC != null ? '${snapshot.tempC!.round()}\u00B0C, ' : '';
    final stalePart = snapshot.isFromCache ? ' \u00B7 last known' : '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '$tempPart${snapshot.conditionLabel} in ${snapshot.locationLabel}$stalePart',
          style: const TextStyle(fontSize: 11, color: Color(0xFF8A6F5C)),
        ),
      ),
    );
  }
}
