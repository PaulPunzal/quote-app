/// One precomputed context anchor from assets/context_options.json —
/// e.g. the mood "Tired", or the weather "Rainy". These are embedded
/// offline (see generate_context_embeddings.py) using short natural-
/// language phrases, using the SAME model as the reflections. The app
/// never embeds anything live; it only ever looks these up.
class ContextOption {
  final String id;
  final String category; // 'mood' | 'weather' | 'time'
  final String label;
  final List<double> embedding;

  const ContextOption({
    required this.id,
    required this.category,
    required this.label,
    required this.embedding,
  });

  factory ContextOption.fromJson(Map<String, dynamic> json) {
    return ContextOption(
      id: json['id'] as String,
      category: json['category'] as String,
      label: json['label'] as String,
      embedding: (json['embedding'] as List<dynamic>)
          .map((e) => (e as num).toDouble())
          .toList(),
    );
  }
}