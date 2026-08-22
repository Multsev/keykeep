enum CustomFieldType { text, protected }

class CustomField {
  const CustomField({
    required this.name,
    required this.value,
    required this.type,
  });
  final String name;
  final String value;
  final CustomFieldType type;

  Map<String, String> toJson() => {
    'name': name,
    'value': value,
    'type': type.name,
  };
  factory CustomField.fromJson(Map<String, dynamic> json) => CustomField(
    name: json['name']! as String,
    value: json['value']! as String,
    type: CustomFieldType.values.byName(json['type'] as String? ?? 'text'),
  );
}

class PasswordEntry {
  const PasswordEntry({
    required this.id,
    required this.title,
    required this.username,
    required this.password,
    required this.website,
    required this.note,
    required this.updatedAt,
    this.folderId = 'root',
    this.customFields = const [],
  });

  final String id;
  final String title;
  final String username;
  final String password;
  final String website;
  final String note;
  final DateTime updatedAt;
  final String folderId;
  final List<CustomField> customFields;

  PasswordEntry copyWith({
    String? title,
    String? username,
    String? password,
    String? website,
    String? note,
    String? folderId,
    List<CustomField>? customFields,
  }) => PasswordEntry(
    id: id,
    title: title ?? this.title,
    username: username ?? this.username,
    password: password ?? this.password,
    website: website ?? this.website,
    note: note ?? this.note,
    updatedAt: DateTime.now(),
    folderId: folderId ?? this.folderId,
    customFields: customFields ?? this.customFields,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'username': username,
    'password': password,
    'website': website,
    'note': note,
    'updatedAt': updatedAt.toIso8601String(),
    'folderId': folderId,
    'customFields': customFields.map((field) => field.toJson()).toList(),
  };

  factory PasswordEntry.fromJson(Map<String, dynamic> json) => PasswordEntry(
    id: json['id']! as String,
    title: json['title']! as String,
    username: json['username']! as String,
    password: json['password']! as String,
    website: json['website']! as String? ?? '',
    note: json['note']! as String? ?? '',
    updatedAt: DateTime.parse(json['updatedAt']! as String),
    folderId: json['folderId'] as String? ?? 'root',
    customFields: (json['customFields'] as List<dynamic>? ?? [])
        .map((value) => CustomField.fromJson(value as Map<String, dynamic>))
        .toList(),
  );
}
