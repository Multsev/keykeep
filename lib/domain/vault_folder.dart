class VaultFolder {
  const VaultFolder({required this.id, required this.name});
  final String id;
  final String name;

  Map<String, String> toJson() => {'id': id, 'name': name};
  factory VaultFolder.fromJson(Map<String, dynamic> json) =>
      VaultFolder(id: json['id']! as String, name: json['name']! as String);
}
