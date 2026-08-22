class PasswordEntry {
  const PasswordEntry({
    required this.id,
    required this.title,
    required this.username,
    required this.password,
    required this.website,
    required this.note,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String username;
  final String password;
  final String website;
  final String note;
  final DateTime updatedAt;

  PasswordEntry copyWith({
    String? title,
    String? username,
    String? password,
    String? website,
    String? note,
  }) => PasswordEntry(
    id: id,
    title: title ?? this.title,
    username: username ?? this.username,
    password: password ?? this.password,
    website: website ?? this.website,
    note: note ?? this.note,
    updatedAt: DateTime.now(),
  );

  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'username': username,
    'password': password,
    'website': website,
    'note': note,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory PasswordEntry.fromJson(Map<String, dynamic> json) => PasswordEntry(
    id: json['id']! as String,
    title: json['title']! as String,
    username: json['username']! as String,
    password: json['password']! as String,
    website: json['website']! as String? ?? '',
    note: json['note']! as String? ?? '',
    updatedAt: DateTime.parse(json['updatedAt']! as String),
  );
}
