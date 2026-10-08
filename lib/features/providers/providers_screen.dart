import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/haptics.dart';
import '../../core/ios_widgets.dart';
import '../../core/models.dart';
import '../../services/openai_compatible_client.dart';
import '../../services/router_service.dart';
import '../../services/secure_store.dart';

/// API keys and providers, in Apple's inset-grouped style.
class ProvidersScreen extends StatelessWidget {
  final List<ProviderDef> providers;
  final SecureStore store;
  final OpenAICompatibleClient client;
  final Map<String, ProviderStats> Function() stats;
  final Future<void> Function()? onChanged;
  const ProvidersScreen({
    super.key,
    required this.providers,
    required this.store,
    required this.client,
    required this.stats,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) => IosPage(
        title: 'API Keys',
        onBack: () => Navigator.of(context).maybePop(),
        onClose: () => Navigator.of(context).maybePop(),
        children: [
          IosSection(
            footer:
                'OmniRoute picks the fastest healthy provider and cools down only the key that failed. Keys stay in encrypted device storage.',
            children: [
              IosTile(
                icon: Icons.key_rounded,
                iconColor: IosColors.purple,
                title: 'Key pools',
                subtitle: 'Add many keys per provider',
                chevron: true,
                onTap: () => Navigator.of(context).push(CupertinoPageRoute(
                    builder: (_) => OmniRouteKeysScreen(
                        providers: providers, store: store, client: client, onChanged: onChanged))),
              ),
            ],
          ),
          for (final p in providers)
            RepaintBoundary(
              child: _ProviderSection(
                def: p,
                store: store,
                client: client,
                stats: () => stats()[p.id],
                onChanged: onChanged,
              ),
            ),
        ],
      );
}

class OmniRouteKeysScreen extends StatefulWidget {
  final List<ProviderDef> providers;
  final SecureStore store;
  final OpenAICompatibleClient client;
  final Future<void> Function()? onChanged;
  const OmniRouteKeysScreen({
    super.key,
    required this.providers,
    required this.store,
    required this.client,
    this.onChanged,
  });
  @override
  State<OmniRouteKeysScreen> createState() => _OmniRouteKeysScreenState();
}

class _OmniRouteKeysScreenState extends State<OmniRouteKeysScreen> {
  final _input = TextEditingController();
  final _keys = <String>[];
  String? _providerId;
  bool _ready = false;
  bool _testing = false;
  final _health = <String, String>{};

  @override
  void initState() {
    super.initState();
    () async {
      _providerId = widget.providers.isEmpty ? null : widget.providers.first.id;
      await _loadKeys();
      if (mounted) setState(() => _ready = true);
    }();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  ProviderDef? get _def {
    final m = widget.providers.where((p) => p.id == _providerId).toList();
    return m.isEmpty ? null : m.first;
  }

  Future<void> _loadKeys() async {
    _keys
      ..clear()
      ..addAll(_providerId == null ? const [] : await widget.store.apiKeys(_providerId!));
  }

  Future<void> _save() async {
    if (_providerId != null) {
      await widget.store.setApiKeys(_providerId!, _keys);
      await widget.onChanged?.call();
    }
  }

  Future<void> _changeProvider(String id) async {
    if (id == _providerId) return;
    setState(() {
      _providerId = id;
      _ready = false;
      _health.clear();
    });
    await _loadKeys();
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _testAll() async {
    final def = _def;
    if (def == null || _keys.isEmpty || _testing) return;
    setState(() {
      _testing = true;
      _health.clear();
    });
    for (final key in List<String>.from(_keys)) {
      try {
        final sw = Stopwatch()..start();
        await widget.client.listModels(
            Endpoint(providerId: def.id, baseUrl: def.baseUrl, apiKey: key, model: def.models.first));
        _health[key] = 'Online · ${sw.elapsedMilliseconds} ms';
      } catch (e) {
        _health[key] = 'Unavailable';
      }
      if (mounted) setState(() {});
    }
    if (mounted) setState(() => _testing = false);
  }

  Future<void> _add() async {
    final value = _input.text.trim();
    if (value.isEmpty || _keys.contains(value)) return;
    Haptics.copy();
    setState(() {
      _keys.add(value);
      _input.clear();
    });
    await _save();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final value = data?.text?.trim();
    if (value == null || value.isEmpty) return;
    _input.text = value;
    _input.selection = TextSelection.collapsed(offset: value.length);
    Haptics.copy();
  }

  void _pickProvider() {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Provider'),
        actions: [
          for (final p in widget.providers)
            CupertinoActionSheetAction(
              isDefaultAction: p.id == _providerId,
              onPressed: () {
                Navigator.pop(ctx);
                _changeProvider(p.id);
              },
              child: Text(p.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return IosPage(title: 'Key Pool', onBack: () => Navigator.of(context).maybePop(), onClose: () => Navigator.of(context).maybePop(), children: const [
        Padding(padding: EdgeInsets.only(top: 80), child: Center(child: CupertinoActivityIndicator(radius: 14))),
      ]);
    }
    return IosPage(
      title: 'Key Pool',
      onBack: () => Navigator.of(context).maybePop(),
      onClose: () => Navigator.of(context).maybePop(),
      children: [
        IosSection(header: 'Provider', children: [
          IosTile(
            icon: Icons.cloud_sync_rounded,
            iconColor: IosColors.blue,
            title: 'Provider',
            value: _def?.name ?? 'None',
            chevron: true,
            onTap: _pickProvider,
          ),
        ]),
        IosSection(
          header: 'Add key',
          footer: 'No limit per provider. Keys are tried independently, so one rate-limited key never blocks the rest.',
          children: [
            IosField(
              controller: _input,
              placeholder: 'Paste API key',
              obscure: true,
              mono: true,
              suffix: Row(mainAxisSize: MainAxisSize.min, children: [
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minSize: 34,
                  onPressed: _paste,
                  child: const Icon(Icons.content_paste_rounded, size: 20),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.only(right: 12),
                  minSize: 30,
                  onPressed: _add,
                  child: const Icon(Icons.add_circle_rounded, size: 25),
                ),
              ]),
              onChanged: null,
            ),
          ],
        ),
        IosSection(
          header: '${_keys.length} key${_keys.length == 1 ? '' : 's'}',
          children: _keys.isEmpty
              ? [const IosTile(title: 'No keys yet', subtitle: 'Add one above to get started')]
              : [
                  for (var i = 0; i < _keys.length; i++)
                    IosTile(
                      icon: Icons.lock_rounded,
                      iconColor: _health[_keys[i]] == null
                          ? IosColors.gray
                          : (_health[_keys[i]]!.startsWith('Online') ? IosColors.green : IosColors.red),
                      title: '••••••••${_keys[i].length > 6 ? _keys[i].substring(_keys[i].length - 6) : ''}',
                      subtitle: _health[_keys[i]] ?? 'Slot ${i + 1}',
                      trailing: CupertinoButton(
                        padding: EdgeInsets.zero,
                        minSize: 30,
                        onPressed: () async {
                          Haptics.toggle();
                          setState(() => _keys.removeAt(i));
                          await _save();
                        },
                        child: const Icon(Icons.remove_circle_rounded, color: IosColors.red, size: 24),
                      ),
                    ),
                ],
        ),
        IosButton(_testing ? 'Testing…' : 'Test all keys',
            icon: Icons.monitor_heart_rounded,
            tinted: true,
            onPressed: _testing || _keys.isEmpty ? null : _testAll),
      ],
    );
  }
}

class _ProviderSection extends StatefulWidget {
  final ProviderDef def;
  final SecureStore store;
  final OpenAICompatibleClient client;
  final ProviderStats? Function() stats;
  final Future<void> Function()? onChanged;
  const _ProviderSection({required this.def, required this.store, required this.client, required this.stats, this.onChanged});
  @override
  State<_ProviderSection> createState() => _ProviderSectionState();
}

class _ProviderSectionState extends State<_ProviderSection> {
  final _key = TextEditingController();
  final _base = TextEditingController();
  bool _show = false, _testing = false, _loaded = false, _ok = false;
  String? _result;
  bool get _isCustom => widget.def.id == 'custom';

  @override
  void initState() {
    super.initState();
    () async {
      final results = await Future.wait<Object?>([
        widget.store.apiKeys(widget.def.id),
        widget.store.baseUrl(widget.def.id),
      ]);
      final keys = results[0] as List<String>;
      _key.text = keys.isEmpty ? '' : keys.first;
      _base.text = (results[1] as String?) ?? widget.def.baseUrl;
      if (mounted) setState(() => _loaded = true);
    }();
  }

  @override
  void dispose() {
    _key.dispose();
    _base.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.store.setApiKeys(widget.def.id, _key.text.trim().isEmpty ? [] : [_key.text.trim()]);
    if (_isCustom) await widget.store.setBaseUrl(widget.def.id, _base.text.trim());
    await widget.onChanged?.call();
  }

  Future<void> _pasteKey() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final value = data?.text?.trim();
    if (value == null || value.isEmpty) return;
    _key.text = value;
    _key.selection = TextSelection.collapsed(offset: value.length);
    Haptics.copy();
  }

  Future<void> _test() async {
    Haptics.toggle();
    setState(() {
      _testing = true;
      _result = null;
    });
    await _save();
    final base = _base.text.trim();
    if (base.isEmpty) {
      setState(() {
        _testing = false;
        _ok = false;
        _result = 'Enter a base URL';
      });
      return;
    }
    try {
      final sw = Stopwatch()..start();
      final models = await widget.client.listModels(
          Endpoint(providerId: widget.def.id, baseUrl: base, apiKey: _key.text.trim(), model: 'test'));
      _ok = true;
      _result = '${sw.elapsedMilliseconds} ms · ${models.length} models';
      Haptics.copy();
    } on LlmError catch (e) {
      _ok = false;
      _result = e.status == 401 || e.status == 403 ? 'Invalid key or permission (${e.status}): ${e.message}' : e.message;
      Haptics.error();
    } catch (e) {
      _ok = false;
      final text = '$e'.replaceAll(RegExp(r'\s+'), ' ').trim();
      _result = text.length > 180 ? '${text.substring(0, 180)}…' : text;
      Haptics.error();
    }
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox(height: 48);
    final st = widget.stats();
    final stats = st != null && st.requests + st.errors > 0
        ? '${st.lastLatencyMs} ms · ${st.requests} requests · ${st.errors} errors · ${st.promptTokens} in / ${st.completionTokens} out'
        : null;
    return IosSection(
      header: widget.def.freeTier ? '${widget.def.name} · free tier' : widget.def.name,
      footer: stats,
      children: [
        if (_isCustom)
          IosField(controller: _base, placeholder: 'Base URL, e.g. http://192.168.1.10:20128/v1'),
        IosField(
          controller: _key,
          placeholder: widget.def.requiresKey ? 'API key' : 'API key (optional)',
          obscure: !_show,
          mono: true,
          suffix: Row(mainAxisSize: MainAxisSize.min, children: [
            CupertinoButton(
              padding: EdgeInsets.zero,
              minSize: 34,
              onPressed: _pasteKey,
              child: const Icon(Icons.content_paste_rounded, size: 19),
            ),
            CupertinoButton(
              padding: const EdgeInsets.only(right: 12),
              minSize: 30,
              onPressed: () => setState(() => _show = !_show),
              child: Icon(_show ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                  size: 20, color: IosColors.secondary(context)),
            ),
          ]),
        ),
        IosTile(
          title: _testing ? 'Testing…' : 'Test connection',
          subtitle: _result == null ? null : (_ok ? 'Connected · $_result' : _result),
          trailing: _testing
              ? const CupertinoActivityIndicator()
                  : (_result == null
                  ? null
                  : Icon(
                      _ok ? Icons.check_circle_rounded : Icons.error_rounded,
                      size: 24,
                      color: _ok ? IosColors.green : IosColors.red,
                    )),
          onTap: _testing ? null : _test,
        ),
      ],
    );
  }
}
