class Quote {
  final String id;
  final String text;
  final String author;
  final List<String> tags;

  const Quote({
    required this.id,
    required this.text,
    required this.author,
    this.tags = const [],
  });

  factory Quote.fromJson(Map<String, dynamic> json) {
    return Quote(
      id: json['id'] as String,
      text: json['text'] as String,
      author: json['author'] as String,
      tags: (json['tags'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'text': text,
      'author': author,
      'tags': tags,
    };
  }

  @override
  String toString() => 'Quote($id, "$text" — $author)';
}
