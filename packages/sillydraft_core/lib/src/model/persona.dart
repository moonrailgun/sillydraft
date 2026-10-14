import 'asset.dart';

/// Who `{{user}}` is in a story: [name] fills `{{user}}` and [prompt] fills
/// `{{persona}}`. Appearance and outfit are kept apart so image tools can
/// use them on their own.
final class Persona {
  const Persona({
    required this.id,
    required this.name,
    this.description = '',
    this.appearance = '',
    this.outfit = '',
    this.images = const [],
  });

  factory Persona.fromJson(Map<String, dynamic> json) => Persona(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String? ?? '',
    appearance: json['appearance'] as String? ?? '',
    outfit: json['outfit'] as String? ?? '',
    images: [
      for (final image in json['images'] as List? ?? const [])
        PersonaImage.fromJson(image as Map<String, dynamic>),
    ],
  );

  /// The built-in persona: the reader as “我”, so stories address them in
  /// the first person.
  static const meId = 'me';
  static const me = Persona(id: meId, name: '我');
  static const maxImages = 8;

  final String id, name, description, appearance, outfit;
  final List<PersonaImage> images;

  /// `{{persona}}`: the description, then appearance and outfit lines, each
  /// left out when empty.
  String get prompt => [
    description.trim(),
    if (appearance.trim().isNotEmpty) '外貌：${appearance.trim()}',
    if (outfit.trim().isNotEmpty) '服饰：${outfit.trim()}',
  ].where((s) => s.isNotEmpty).join('\n');

  /// The text fields: what a project export carries, and what makes two
  /// personas the same one.
  Map<String, String> get snapshot => {
    'name': name,
    'description': description,
    'appearance': appearance,
    'outfit': outfit,
  };

  Persona copyWith({
    String? id,
    String? name,
    String? description,
    String? appearance,
    String? outfit,
    List<PersonaImage>? images,
  }) => Persona(
    id: id ?? this.id,
    name: name ?? this.name,
    description: description ?? this.description,
    appearance: appearance ?? this.appearance,
    outfit: outfit ?? this.outfit,
    images: images ?? this.images,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    ...snapshot,
    'images': [for (final image in images) image.toJson()],
  };
}

/// A reference image, stored by content hash like story assets.
final class PersonaImage {
  const PersonaImage({
    required this.hash,
    required this.thumbnailHash,
    required this.width,
    required this.height,
  });

  factory PersonaImage.of(PreparedAsset prepared) => PersonaImage(
    hash: prepared.hash,
    thumbnailHash: prepared.thumbnailHash,
    width: prepared.width,
    height: prepared.height,
  );

  factory PersonaImage.fromJson(Map<String, dynamic> json) => PersonaImage(
    hash: json['hash'] as String,
    thumbnailHash: json['thumbnailHash'] as String,
    width: json['width'] as int,
    height: json['height'] as int,
  );

  final String hash, thumbnailHash;
  final int width, height;

  Map<String, dynamic> toJson() => {
    'hash': hash,
    'thumbnailHash': thumbnailHash,
    'width': width,
    'height': height,
  };
}
