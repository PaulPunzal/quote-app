/// The curated set of categories quotes can be tagged with. Keeping this
/// list centralized — instead of letting free-typed tags pile up as
/// near-duplicates like "care" / "Care" / "caring" — is what keeps
/// categories clean across the whole app. The same list is used both for
/// picking tags when adding a quote and for filtering on the Browse screen.
const List<String> kQuoteCategories = [
  'patience',
  'rest',
  'worth',
  'stillness',
  'attention',
  'memory',
  'movement',
  'ritual',
];

/// Normalizes a raw tag string for storage/comparison: trimmed and
/// lowercased, so "Patience", " patience ", and "patience" are all treated
/// as the same category.
String normalizeCategory(String raw) => raw.trim().toLowerCase();

/// A friendly, capitalized version of a category, for display only.
/// Storage/comparison should always use the normalized (lowercase) form.
String displayCategory(String category) {
  if (category.isEmpty) return category;
  return category[0].toUpperCase() + category.substring(1);
}