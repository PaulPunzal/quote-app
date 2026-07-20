/// A single reflection as shipped in assets/reflections.json, including
/// its precomputed embedding vector. The embedding is generated offline
/// (see generate_embeddings.py) — nothing in the app ever computes one
/// of these live.
class EmbeddedReflection {
  final String id;
  final String text;
  final List<double> embedding;

  const EmbeddedReflection({
    required this.id,
    required this.text,
    required this.embedding,
  });

  factory EmbeddedReflection.fromJson(Map<String, dynamic> json) {
    return EmbeddedReflection(
      id: json['id'] as String,
      text: json['text'] as String,
      embedding: (json['embedding'] as List<dynamic>)
          .map((e) => (e as num).toDouble())
          .toList(),
    );
  }
}