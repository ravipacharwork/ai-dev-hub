import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../services/openai_compatible_client.dart';
import '../../services/router_service.dart';
import '../../services/secure_store.dart';

class ProvidersScreen extends StatelessWidget {
  final List<ProviderDef> providers;
  final SecureStore store;
  final OpenAICompatibleClient client;
  final Map<String, ProviderStats> Function() stats;
  final Future<void> Function()? onChanged;
  const ProvidersScreen({super.key, required this.providers, required this.store, required this.client, required this.stats, this.onChanged});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Provider keys')),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          Glass(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.hub_rounded, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 8),
            const Text('OmniRoute is the built-in gateway. It can route across multiple keys for the same provider, with independent fallback and rate-limit cooldowns.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.dashboard_customize_rounded),
              label: const Text('Open OmniRoute key panel'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => OmniRouteKeysScreen(providers: providers, store: store, onChanged: onChanged))),
            ),
          ])),
          const SizedBox(height: 12),
          for (final p in providers)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: _ProviderTile(def: p, store: store, client: client, stats: () => stats()[p.id])),
        ],
      );
}

class OmniRouteKeysScreen extends StatefulWidget {
  final List<ProviderDef> providers;
  final SecureStore store;
  final Future<void> Function()? onChanged;
  const OmniRouteKeysScreen({super.key, required this.providers, required this.store, this.onChanged});
  @override State<OmniRouteKeysScreen> createState() => _OmniRouteKeysScreenState();
}

class _OmniRouteKeysScreenState extends State<OmniRouteKeysScreen> {
  final _input = TextEditingController();
  final _keys = <String>[];
  String? _providerId;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    () async { _providerId = widget.providers.isEmpty ? null : widget.providers.first.id; await _loadKeys(); if (mounted) setState(() => _ready = true); }();
  }
  @override void dispose() { _input.dispose(); super.dispose(); }
  Future<void> _loadKeys() async { _keys..clear()..addAll(_providerId == null ? const [] : await widget.store.apiKeys(_providerId!)); }
  Future<void> _save() async { if (_providerId != null) { await widget.store.setApiKeys(_providerId!, _keys); await widget.onChanged?.call(); } }
  Future<void> _changeProvider(String? id) async { if (id == null || id == _providerId) return; setState(() { _providerId = id; _ready = false; }); await _loadKeys(); if (mounted) setState(() => _ready = true); }
  Future<void> _add() async {
    final value = _input.text.trim();
    if (value.isEmpty || _keys.contains(value)) return;
    setState(() { _keys.add(value); _input.clear(); });
    await _save();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('OmniRoute key panel')),
        body: !_ready ? const Center(child: CircularProgressIndicator()) : ListView(padding: const EdgeInsets.all(12), children: [
          Glass(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Provider key pool', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(value: _providerId, decoration: const InputDecoration(labelText: 'Provider'), items: [for (final p in widget.providers) DropdownMenuItem(value: p.id, child: Text(p.name))], onChanged: _changeProvider),
            const SizedBox(height: 6),
            const Text('Keys are stored in encrypted device storage. OmniRoute tries healthy keys independently and cools down only the key that failed.'),
            const SizedBox(height: 14),
            TextField(controller: _input, obscureText: true, autocorrect: false, enableSuggestions: false,
              decoration: InputDecoration(labelText: 'Add API key', suffixIcon: IconButton(icon: const Icon(Icons.add_rounded), onPressed: _add)),
              onSubmitted: (_) => _add()),
            const SizedBox(height: 12),
            if (_keys.isEmpty) const Text('No keys added yet. Add one or more provider keys above.')
            else for (var i = 0; i < _keys.length; i++) ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(child: Text('${i + 1}')),
              title: Text('••••••••${_keys[i].length > 6 ? _keys[i].substring(_keys[i].length - 6) : ''}'),
              subtitle: Text('Fallback slot ${i + 1}'),
              trailing: IconButton(icon: const Icon(Icons.delete_outline_rounded), onPressed: () async { setState(() => _keys.removeAt(i)); await _save(); }),
            ),
          ])),
        ]),
      );
}

class _ProviderTile extends StatefulWidget {
  final ProviderDef def; final SecureStore store; final OpenAICompatibleClient client; final ProviderStats? Function() stats;
  const _ProviderTile({required this.def, required this.store, required this.client, required this.stats});
  @override State<_ProviderTile> createState() => _ProviderTileState();
}

class _ProviderTileState extends State<_ProviderTile> {
  final _key = TextEditingController(); final _base = TextEditingController();
  bool _show = false, _testing = false, _loaded = false; String? _result; bool _ok = false;
  bool get _isCustom => widget.def.id == 'custom';
  @override void initState() { super.initState(); () async { final keys = await widget.store.apiKeys(widget.def.id); _key.text = keys.isEmpty ? '' : keys.first; _base.text = await widget.store.baseUrl(widget.def.id) ?? widget.def.baseUrl; if (mounted) setState(() => _loaded = true); }(); }
  @override void dispose() { _key.dispose(); _base.dispose(); super.dispose(); }
  Future<void> _save() async { await widget.store.setApiKeys(widget.def.id, _key.text.trim().isEmpty ? [] : [_key.text.trim()]); if (_isCustom) await widget.store.setBaseUrl(widget.def.id, _base.text.trim()); }
  Future<void> _test() async {
    Haptics.toggle(); setState(() { _testing = true; _result = null; }); await _save();
    final base = _base.text.trim(); if (base.isEmpty) { setState(() { _testing = false; _ok = false; _result = 'Enter a base URL'; }); return; }
    try { final sw = Stopwatch()..start(); final models = await widget.client.listModels(Endpoint(providerId: widget.def.id, baseUrl: base, apiKey: _key.text.trim(), model: 'test')); _ok = true; _result = '${sw.elapsedMilliseconds} ms · ${models.length} models'; Haptics.copy(); }
    on LlmError catch (e) { _ok = false; _result = e.status == 401 || e.status == 403 ? 'Invalid key (${e.status})' : e.message; Haptics.error(); }
    catch (e) { _ok = false; _result = '$e'; Haptics.error(); }
    if (mounted) setState(() => _testing = false);
  }
  @override
  Widget build(BuildContext context) {
    final st = widget.stats();
    return Glass(child: !_loaded ? const SizedBox(height: 48) : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(widget.def.name, style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 8),
      if (_isCustom) ...[TextField(controller: _base, keyboardType: TextInputType.url, autocorrect: false, decoration: const InputDecoration(labelText: 'Base URL', hintText: 'http://192.168.1.10:20128/v1')), const SizedBox(height: 8)],
      TextField(controller: _key, obscureText: !_show, autocorrect: false, enableSuggestions: false, decoration: InputDecoration(labelText: widget.def.requiresKey ? 'API key' : 'API key (optional)', suffixIcon: IconButton(icon: Icon(_show ? Icons.visibility_off_rounded : Icons.visibility_rounded), onPressed: () => setState(() => _show = !_show))), onEditingComplete: _save),
      const SizedBox(height: 10), Row(children: [FilledButton.tonal(onPressed: _testing ? null : _test, child: _testing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Test connection')), const SizedBox(width: 10), if (_result != null) Expanded(child: Text(_ok ? '✓ $_result' : '✗ $_result', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: _ok ? Colors.green : Theme.of(context).colorScheme.error, fontSize: 12))) ]),
      if (st != null && st.requests + st.errors > 0) ...[const Divider(height: 20), Wrap(spacing: 14, runSpacing: 4, children: [_stat(context, 'Latency', '${st.lastLatencyMs} ms'), _stat(context, 'Requests', '${st.requests}'), _stat(context, 'Errors', '${st.errors}'), _stat(context, 'Tokens in', '${st.promptTokens}'), _stat(context, 'Tokens out', '${st.completionTokens}')])],
    ]));
  }
  Widget _stat(BuildContext c, String k, String v) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [Text(k, style: Theme.of(c).textTheme.labelSmall?.copyWith(color: Theme.of(c).hintColor)), Text(v, style: Theme.of(c).textTheme.titleSmall)]);
}
