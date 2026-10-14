import '../st/import_types.dart';

enum ResourceKind { character, preset, worldBook, regex }

/// Source versions are immutable; bindings refer to a specific version ID.
final class LibraryResource extends JsonSource {
  LibraryResource({
    required this.id,
    required this.kind,
    required this.name,
    required this.filename,
    required this.sourceHash,
    required this.createdAt,
    required Map<String, dynamic> data,
    this.parentId,
    this.archived = false,
  }) : super(data);

  /// Metadata listings do not need to decode the resource's full contents.
  LibraryResource.fromStoredJson({
    required this.id,
    required this.kind,
    required this.name,
    required this.filename,
    required this.sourceHash,
    required this.createdAt,
    required String dataJson,
    this.parentId,
    this.archived = false,
  }) : super.encoded(dataJson);

  final String id, name, filename, sourceHash;
  final String? parentId;
  final ResourceKind kind;
  final DateTime createdAt;
  final bool archived;
  Map<String, dynamic> get data => raw;
}
