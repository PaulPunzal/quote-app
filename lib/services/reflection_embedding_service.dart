import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import '../models/embedded_reflection.dart';
import '../models/context_option.dart';

/// A ranked result: a reflection paired with its similarity score
/// against whatever context vector it was ranked against.
class ScoredReflection {
  final EmbeddedReflection reflection;
  final double score;

  const ScoredReflection(this.reflection, this.score);
}

/// Loads assets/reflections.json and assets/context_options.json once,
/// and does all similarity math purely on-device — no model, no
/// network, just dot products over precomputed vectors.
///
/// Both JSON files are produced by the Python scripts
/// (generate_embeddings.py / generate_context_embeddings.py) using the
/// SAME embedding model, and both are written with normalized vectors
/// (unit length). That matters for two reasons:
///   1. Dot product == cosine similarity when vectors are normalized,
///      so we never need to divide by magnitudes on-device.
///   2. Averaging a few context vectors together (mood + weather +
///      time) does NOT need to be re-normalized before ranking:
///      the resulting vector's magnitude is just a constant scale
///      factor applied equally to every reflection's score, so it
///      never changes their relative order.
class ReflectionEmbeddingService {
  static const _reflectionsAssetPath = 'assets/reflections.json';
  static const _contextAssetPath = 'assets/context_options.json';

  List<EmbeddedReflection>? _reflections;
  List<ContextOption>? _contextOptions;

  Future<void> _ensureLoaded() async {
    if (_reflections != null && _contextOptions != null) return;

    final reflectionsRaw =
        await rootBundle.loadString(_reflectionsAssetPath);
    final reflectionsDecoded =
        jsonDecode(reflectionsRaw) as Map<String, dynamic>;
    final reflectionsList =
        reflectionsDecoded['reflections'] as List<dynamic>;
    _reflections = reflectionsList
        .map((e) => EmbeddedReflection.fromJson(e as Map<String, dynamic>))
        .toList();

    final contextRaw = await rootBundle.loadString(_contextAssetPath);
    final contextDecoded = jsonDecode(contextRaw) as Map<String, dynamic>;
    final contextList = contextDecoded['context_options'] as List<dynamic>;
    _contextOptions = contextList
        .map((e) => ContextOption.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// All reflections, loaded once and cached.
  Future<List<EmbeddedReflection>> allReflections() async {
    await _ensureLoaded();
    return _reflections!;
  }

  /// All context options, optionally filtered to one category
  /// ('mood' | 'weather' | 'time'). Useful for populating a mood-picker
  /// UI directly from the same data file the matcher uses, so the UI
  /// and the matching logic can never drift out of sync.
  Future<List<ContextOption>> contextOptions({String? category}) async {
    await _ensureLoaded();
    if (category == null) return _contextOptions!;
    return _contextOptions!.where((o) => o.category == category).toList();
  }

  Future<ContextOption> _requireContextOption(String id) async {
    await _ensureLoaded();
    return _contextOptions!.firstWhere(
      (o) => o.id == id,
      orElse: () => throw ArgumentError('Unknown context option id: $id'),
    );
  }

  /// Plain dot product. Safe to use as cosine similarity here because
  /// every vector coming out of the Python pipeline is pre-normalized.
  double _dot(List<double> a, List<double> b) {
    var sum = 0.0;
    for (var i = 0; i < a.length; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }

  /// Averages several vectors element-wise. No renormalization needed —
  /// see the class doc comment for why that's safe for ranking purposes.
  List<double> _average(List<List<double>> vectors) {
    final dim = vectors.first.length;
    final result = List<double>.filled(dim, 0.0);
    for (final v in vectors) {
      for (var i = 0; i < dim; i++) {
        result[i] += v[i];
      }
    }
    for (var i = 0; i < dim; i++) {
      result[i] /= vectors.length;
    }
    return result;
  }

  /// Builds the "current moment" query vector from up to three context
  /// option ids (mood/weather/time — any can be omitted). At least one
  /// id must be provided.
  Future<List<double>> buildContextVector({
    String? moodId,
    String? weatherId,
    String? timeId,
  }) async {
    final ids = [moodId, weatherId, timeId].whereType<String>().toList();
    if (ids.isEmpty) {
      throw ArgumentError(
          'buildContextVector needs at least one of moodId/weatherId/timeId');
    }

    final vectors = <List<double>>[];
    for (final id in ids) {
      final option = await _requireContextOption(id);
      vectors.add(option.embedding);
    }

    return _average(vectors);
  }

  /// Ranks all reflections against [contextVector], highest similarity
  /// first, excluding any id in [excludeIds] (e.g. recently shown).
  Future<List<ScoredReflection>> rank(
    List<double> contextVector, {
    Set<String> excludeIds = const {},
  }) async {
    await _ensureLoaded();

    final candidates = _reflections!
        .where((r) => !excludeIds.contains(r.id))
        .map((r) => ScoredReflection(r, _dot(contextVector, r.embedding)))
        .toList();

    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates;
  }
}