class VaultFolder {
  const VaultFolder({
    required this.id,
    required this.name,
    this.parentId = 'root',
  });
  final String id;
  final String name;
  final String parentId;

  Map<String, String> toJson() => {
    'id': id,
    'name': name,
    'parentId': parentId,
  };
  factory VaultFolder.fromJson(Map<String, dynamic> json) => VaultFolder(
    id: json['id']! as String,
    name: json['name']! as String,
    parentId: json['parentId'] as String? ?? 'root',
  );
}
