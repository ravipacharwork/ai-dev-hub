import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/haptics.dart';
import '../../core/theme.dart';
import '../../services/proxy_controller.dart';
import '../../services/proxy_server.dart';

class ProxyScreen extends StatefulWidget {
  final ProxyController controller;
  const ProxyScreen({super.key, required this.controller});

  @override
  State<ProxyScreen> createState() => _ProxyScreenState();
}

class _ProxyScreenState extends State<ProxyScreen> {
  ProxyController get c => widget.controller;
  final _port = TextEditingController(text: '8080');
  List<String> _ips = [];
  bool _showToken = false, _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _port.text = '${c.port}';
    c.loadToken().then((_) => mounted ? setState(() {}) : null);
    _refreshIps();
  }

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  Future<void> _refreshIps() async {
    final ips = await ProxyServer.lanAddresses();
    if (mounted) setState(() => _ips = ips);
  }

  Future<void> _apply(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      Haptics.toggle();
    } catch (e) {
      Haptics.error();
      _error = e.toString().contains('Address already in use')
          ? 'Port ${c.port} is already in use. Try another.'
          : '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _toggleServer(bool on) async {
    final p = int.tryParse(_port.text.trim());
    if (p == null || p < 1024 || p > 65535) {
      setState(() => _error = 'Port must be 1024–65535');
      return;
    }
    c.port = p;
    await _apply(() => on ? c.start() : c.stop());
  }

  Future<void> _toggleLan(bool on) async {
    if (on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Share on Wi-Fi?'),
          content: const Text(
              'Anyone on this network who has your token can use your provider keys and quota. '
              'Traffic is plain HTTP. Use only on networks you trust.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enable')),
          ],
        ),
      );
      if (ok != true) return;
    }
    c.lan = on;
    setState(() {});
    if (c.server.running) await _apply(() async {
      await c.stop();
      await c.start();
    });
  }

  void _copy(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    Haptics.copy();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$label copied'), duration: const Duration(milliseconds: 900)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = c.server.running;
    final token = c.server.bearerToken;
    final urls = [
      'http://127.0.0.1:${c.port}/v1',
      if (c.lan) ..._ips.map((ip) => 'http://$ip:${c.port}/v1'),
    ];
    final exampleBase = urls.last;

    return Scaffold(
      appBar: AppBar(title: const Text('Local proxy')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Glass(
          child: Column(children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Server'),
              subtitle: Text(running ? 'Running' : 'Stopped'),
              value: running,
              onChanged: _busy ? null : _toggleServer,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Share on Wi-Fi'),
              subtitle: Text(c.lan
                  ? 'Reachable by other devices on this network'
                  : 'This phone only (localhost)'),
              value: c.lan,
              onChanged: _busy ? null : _toggleLan,
            ),
            TextField(
              controller: _port,
              enabled: !running,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
              ),
          ]),
        ),
        const SizedBox(height: 12),
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Base URL', style: Theme.of(context).textTheme.titleSmall),
            for (final u in urls)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(u, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                trailing: IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: () => _copy(u, 'URL')),
              ),
            if (c.lan && _ips.isEmpty)
              const Text('No Wi-Fi address found. Connect to a network.'),
          ]),
        ),
        const SizedBox(height: 12),
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Bearer token', style: Theme.of(context).textTheme.titleSmall),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                _showToken ? token : '•' * 24,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                    icon: Icon(_showToken ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                        size: 18),
                    onPressed: () => setState(() => _showToken = !_showToken)),
                IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: () => _copy(token, 'Token')),
              ]),
            ),
            TextButton.icon(
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Regenerate (disconnects other devices)'),
              onPressed: () async {
                await c.regenerateToken();
                Haptics.toggle();
                if (mounted) setState(() {});
              },
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Test from another device', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            SelectableText(
              'curl $exampleBase/chat/completions \\\n'
              '  -H "Authorization: Bearer <token>" \\\n'
              '  -H "Content-Type: application/json" \\\n'
              '  -d \'{"model":"auto","messages":[{"role":"user","content":"hi"}]}\'',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            TextButton(
              onPressed: () => _copy(
                  'curl $exampleBase/chat/completions -H "Authorization: Bearer $token" '
                  '-H "Content-Type: application/json" '
                  '-d \'{"model":"auto","messages":[{"role":"user","content":"hi"}]}\'',
                  'Command'),
              child: const Text('Copy with token'),
            ),
          ]),
        ),
      ]),
    );
  }
}
