import 'dart:convert';
import 'dart:math';
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

  /// Weighted element-wise average. Still no renormalization needed —
  /// see the class doc comment: a weighted sum of unit vectors is just
  /// a different fixed linear combination, and since the *same*
  /// resulting vector is compared against every reflection, its scale
  /// never changes their relative ranking either.
  List<double> _weightedAverage(
      List<MapEntry<List<double>, double>> weightedVectors) {
    final dim = weightedVectors.first.key.length;
    final result = List<double>.filled(dim, 0.0);
    var totalWeight = 0.0;

    for (final entry in weightedVectors) {
      final vector = entry.key;
      final weight = entry.value;
      for (var i = 0; i < dim; i++) {
        result[i] += vector[i] * weight;
      }
      totalWeight += weight;
    }

    for (var i = 0; i < dim; i++) {
      result[i] /= totalWeight;
    }
    return result;
  }

  /// Builds the "current moment" query vector from up to three context
  /// option ids (mood/weather/time — any can be omitted). At least one
  /// id must be provided.
  ///
  /// [moodWeight], [weatherWeight], and [timeWeight] control how much
  /// each contributes to the final vector. They default to giving
  /// time-of-day more pull than weather: for the ambient Morning/Evening
  /// slots (which only ever pass weather + time, no mood), an equal
  /// average let weather -- which barely changes within a single day --
  /// wash out the one signal that's actually supposed to tell those two
  /// slots apart. Weighing time higher makes Morning and Evening
  /// meaningfully diverge instead of converging on nearly the same
  /// top matches.
  Future<List<double>> buildContextVector({
    String? moodId,
    String? weatherId,
    String? timeId,
    double moodWeight = 1.0,
    double weatherWeight = 0.6,
    double timeWeight = 1.6,
  }) async {
    final weighted = <MapEntry<List<double>, double>>[];

    if (moodId != null) {
      final option = await _requireContextOption(moodId);
      weighted.add(MapEntry(option.embedding, moodWeight));
    }
    if (weatherId != null) {
      final option = await _requireContextOption(weatherId);
      weighted.add(MapEntry(option.embedding, weatherWeight));
    }
    if (timeId != null) {
      final option = await _requireContextOption(timeId);
      weighted.add(MapEntry(option.embedding, timeWeight));
    }

    if (weighted.isEmpty) {
      throw ArgumentError(
          'buildContextVector needs at least one of moodId/weatherId/timeId');
    }

    return _weightedAverage(weighted);
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

  /// Narrows an already-[rank]ed list down to reflections that are
  /// genuinely close to the top match, rather than an arbitrary fixed
  /// count.
  ///
  /// A flat "take the top N" cutoff has two failure modes on a modest
  /// corpus: N is small enough to exhaust in a few swipes, and/or N is
  /// large enough relative to the corpus that it stops meaning
  /// "similar" and starts meaning "most of everything" — which reads
  /// as unrelated even though it's technically top-ranked.
  ///
  /// [margin] is the max score gap (dot product, since vectors are
  /// normalized -- see class doc) below the top score that still
  /// counts as "similar enough". [minPoolSize] guarantees Explore
  /// always has *something* to shuffle even on a day where nothing is
  /// within [margin] (falls back to the closest few regardless of
  /// margin). [maxPoolSize] caps it the other direction so a very
  /// generic context (matching almost everything closely) doesn't
  /// hand back the whole corpus.
  List<ScoredReflection> similarBand(
    List<ScoredReflection> ranked, {
    double margin = 0.08,
    int minPoolSize = 5,
    int maxPoolSize = 20,
  }) {
    if (ranked.isEmpty) return ranked;

    final topScore = ranked.first.score;
    final band =
        ranked.where((r) => topScore - r.score <= margin).toList();

    if (band.length >= minPoolSize) {
      return band.take(maxPoolSize).toList();
    }

    // Not enough genuinely-close matches -- fall back to the closest
    // few available so Explore still has something, rather than
    // returning an under-filled pool.
    return ranked.take(min(minPoolSize, ranked.length)).toList();
  }
}