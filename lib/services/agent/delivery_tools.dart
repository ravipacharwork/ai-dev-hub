import '../deliverables.dart';
import 'agent_tools.dart';

/// Lets the assistant hand finished work to the user inside the chat:
/// single files, code, web apps (HTML), zip archives, and copies of device files.
class DeliveryToolkit implements Toolkit {
  final DeliveryStore store;
  final bool allowDevicePaths;
  DeliveryToolkit(this.store, {this.allowDevicePaths = false});

  static Map<String, dynamic> _p(String d, [String t = 'string']) => {'type': t, 'description': d};

  @override
  List<Map<String, dynamic>> get schemas => [
        {
          'type': 'function',
          'function': {
            'name': 'deliver_file',
            'description':
                'Give the user a file in the chat: source code, a document, or a complete single-file web app (name it .html and it can be run in the chat). Put the COMPLETE content here instead of pasting long code into your message.',
            'parameters': {
              'type': 'object',
              'properties': {
                'name': _p('File name with extension, e.g. app.html or main.py'),
                'content': _p('Complete file text'),
              },
              'required': ['name', 'content'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'deliver_zip',
            'description':
                'Give the user a .zip containing several text files (e.g. a small project). Use relative paths like src/main.dart.',
            'parameters': {
              'type': 'object',
              'properties': {
                'name': _p('Archive name, e.g. project.zip'),
                'files': {
                  'type': 'array',
                  'description': 'Files to include',
                  'items': {
                    'type': 'object',
                    'properties': {'path': _p('Path inside the zip'), 'content': _p('File text')},
                    'required': ['path', 'content'],
                  },
                },
              },
              'required': ['name', 'files'],
            },
          },
        },
        if (allowDevicePaths)
          {
            'type': 'function',
            'function': {
              'name': 'deliver_path',
              'description':
                  'Give the user an existing file from the device (an APK, zip, image, any file) or a folder (sent as a zip).',
              'parameters': {
                'type': 'object',
                'properties': {'path': _p('Absolute path of the file or folder')},
                'required': ['path'],
              },
            },
          },
      ];

  @override
  String get systemNote =>
      'Delivering results: when you produce something the user should keep or use (code files, a web app, a project, a document), call deliver_file or deliver_zip with the complete content. It appears in the chat as a card the user can preview, run (HTML), share or save. Do not paste long code into your message; deliver it and summarise in a sentence or two.';

  @override
  String label(String name, Map<String, dynamic> args) => switch (name) {
        'deliver_file' => 'Delivering ${args['name'] ?? 'file'}',
        'deliver_zip' => 'Zipping ${args['name'] ?? 'archive'}',
        _ => 'Delivering ${args['path'] ?? 'file'}',
      };

  @override
  ApprovalRequest? approval(String name, Map<String, dynamic> args) => null;

  @override
  Future<ToolResult> run(String name, Map<String, dynamic> args) async {
    try {
      switch (name) {
        case 'deliver_file':
          final content = '${args['content'] ?? ''}';
          if (content.length > DeliveryStore.maxTextBytes) {
            return const ToolResult('Content is over 5 MB.', ok: false);
          }
          final d = await store.saveText('${args['name'] ?? 'file.txt'}', content);
          return _ok(d);
        case 'deliver_zip':
          final list = args['files'];
          if (list is! List || list.isEmpty) {
            return const ToolResult('"files" must be a non-empty array.', ok: false);
          }
          final files = <String, String>{};
          for (final f in list) {
            if (f is Map && f['path'] != null) files['${f['path']}'] = '${f['content'] ?? ''}';
          }
          final d = await store.zipText('${args['name'] ?? 'archive.zip'}', files);
          return _ok(d);
        case 'deliver_path':
          if (!allowDevicePaths) return const ToolResult('Device file access is off.', ok: false);
          final d = await store.adopt('${args['path'] ?? ''}');
          return _ok(d);
      }
      return ToolResult('Unknown tool "$name".', ok: false);
    } catch (e) {
      return ToolResult('Delivery failed: $e', ok: false);
    }
  }

  ToolResult _ok(Deliverable d) => ToolResult(
      'Delivered ${d.name} (${d.sizeLabel}). The user can see it in the chat now.',
      deliverables: [d]);
}
