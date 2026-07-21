import 'package:flutter/material.dart';
import '../models/geocode_result.dart';
import '../services/weather_service.dart';

/// One-time (or change-anytime) setup for the manually-configured city
/// used to fetch weather. No GPS permission anywhere in this flow —
/// type a city, pick the right match from Open-Meteo's geocoding
/// results, done.
class WeatherLocationScreen extends StatefulWidget {
  const WeatherLocationScreen({super.key});

  @override
  State<WeatherLocationScreen> createState() => _WeatherLocationScreenState();
}

class _WeatherLocationScreenState extends State<WeatherLocationScreen> {
  final WeatherService _weatherService = WeatherService();
  final TextEditingController _controller = TextEditingController();

  String? _savedLabel;
  List<GeocodeResult> _results = [];
  bool _searching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final label = await _weatherService.getSavedLocationLabel();
    if (mounted) setState(() => _savedLabel = label);
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _searching = true;
      _error = null;
      _results = [];
    });

    try {
      final results = await _weatherService.searchCity(query);
      if (!mounted) return;
      setState(() {
        _searching = false;
        _results = results;
        if (results.isEmpty) {
          _error = 'No matches found. Try a different spelling.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = 'Could not search right now. Check your connection and try again.';
      });
    }
  }

  Future<void> _select(GeocodeResult result) async {
    await _weatherService.saveLocation(result);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBF3E9),
      appBar: AppBar(
        title: const Text('Weather Location'),
        backgroundColor: const Color(0xFFFBF3E9),
        foregroundColor: const Color(0xFF3B2E28),
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_savedLabel != null) ...[
              Text(
                'Current: $_savedLabel',
                style: const TextStyle(fontSize: 13, color: Color(0xFF8A6F5C)),
              ),
              const SizedBox(height: 16),
            ],
            const Text(
              'Set your city so today\u2019s reflection can reflect the weather outside.',
              style: TextStyle(fontSize: 13, color: Color(0xFF8A6F5C)),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      labelText: 'City name',
                      hintText: 'e.g. San Jose del Monte',
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _searching ? null : _search,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB5651D),
                  ),
                  child: _searching
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Search'),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                itemCount: _results.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final r = _results[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(r.displayLabel),
                    onTap: () => _select(r),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}