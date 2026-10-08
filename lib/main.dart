import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'core/chat_mode.dart';
import 'core/models.dart';
import 'core/sparkle.dart';
import 'core/theme.dart';
import 'features/chat/chat_screen.dart';
import 'features/github/github_screen.dart';
import 'features/providers/providers_screen.dart';
import 'features/proxy/proxy_screen.dart';
import 'features/settings/connectors_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/settings/skills_screen.dart';
import 'services/telegram_bridge.dart';
import 'services/browser_session.dart';
import 'services/agent/browser_tools.dart';
import 'services/agent/agent_runner.dart';
import 'services/agent/agent_tools.dart';
import 'services/agent/device_file_tools.dart';
import 'services/agent/local_undo.dart';
import 'services/agent/plan.dart';
import 'services/agent/preview_tools.dart';
import 'services/agent/terminal_tools.dart';
import 'services/terminal/terminal_bridge.dart';
import 'services/app_settings.dart';
import 'services/build_poller.dart';
import 'services/chat_codec.dart';
import 'services/agent/delivery_tools.dart';
import 'services/default_providers.dart';
import 'services/deliverables.dart';
import 'services/github_service.dart';
import 'services/local_gateway.dart';
import 'services/model_health.dart';
import 'services/local_file_service.dart';
import 'services/openai_compatible_client.dart';
import 'services/proxy_controller.dart';
import 'services/proxy_server.dart';
import 'services/router_service.dart';
import 'services/secure_store.dart';
import 'services/session_store.dart';
import 'services/skill_store.dart';
import 'services/skill_hub.dart';
import 'features/settings/skill_hub_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ProxyController.initForegroundService();
  runApp(const BootstrapApp());
}

/// Manual service locator: one place that wires everything together.
class AppServices {
  // Bundled registry is the safe default. A production build may replace this
  // with a controlled HTTPS registry URL using a source change.
  static const registryUrl = '';

  final store = SecureStore();
  final client = OpenAICompatibleClient();
  final settings = AppSettings();
  final files = LocalFileService();
  final sessions = SessionStore();
  final skills = SkillStore();

  late final RouterService router;
  late final ProxyServer proxyServer;
  late final ProxyController proxy;
  late final TelegramBridge telegram;
  late final LocalGateways gateways;
  late final ModelHealth health = ModelHealth(client);
  late final DeliveryStore delivery = DeliveryStore(() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/deliverables');
    await d.create(recursive: true);
    return d;
  });
  List<Endpoint> upstream = []; // real providers behind the embedded gateways

  List<ProviderDef> providers = [];
  List<Endpoint> chain = [];
  GitHubService? gh;
  BuildPoller? poller;
  RepoSelection? selection;

  // Agent workspace (staged changes) survives chat switches, and is reset when
  // the token or repo selection changes.
  AgentWorkspace? _ws;
  String? _wsKey;
  GitHubService? _wsGh;

  final terminalBridge = TerminalBridge();
  late final SkillHub skillHub;
  DeviceFileToolkit? deviceFiles; // set in create(); used when enabled in Settings
  late final LocalUndoLog localUndo; // undo for terminal / device-file edits

  /// The repo workspace behind the agent (checkpoints / undo), if one is active.
  AgentWorkspace? get workspace => settings.toolsEnabled ? _ws : null;

  // ---- undo across the repo workspace and local files -------------------------

  /// All undo points (repo steps and device/terminal file steps), oldest first.
  List<Checkpoint> allCheckpoints() {
    final l = <Checkpoint>[...?workspace?.checkpoints, ...localUndo.checkpoints];
    l.sort((a, b) => a.at.compareTo(b.at));
    return l;
  }

  Checkpoint? _checkpoint(String id) {
    for (final c in allCheckpoints()) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// First repo checkpoint taken at or after [c] (what a repo undo must go back to).
  Checkpoint? _repoCheckpointFrom(Checkpoint c) {
    final w = workspace;
    if (w == null) return null;
    for (final x in w.checkpoints) {
      if (!x.at.isBefore(c.at)) return x;
    }
    return null;
  }

  bool undoTouchesRemote(String id) {
    final c = _checkpoint(id);
    final r = c == null ? null : _repoCheckpointFrom(c);
    final pushed = c != null && localUndo.pushes.any((x) => !x.at.isBefore(c.at));
    return pushed || (r != null && (workspace?.undoTouchesRemote(r.id) ?? false));
  }

  /// Moves a branch back after a shell `git push`, unless someone pushed since.
  Future<String?> _undoPush(PushRecord r) async {
    final g = gh;
    if (g == null) return 'GitHub is not connected';
    final repo = RepoRef(r.owner, r.repo);
    final now = await g.branchSha(repo, r.branch);
    if (now != r.after) return 'the branch changed since (someone else pushed)';
    await g.resetBranch(repo, r.branch, r.before);
    final w = _ws;
    if (w != null && w.repo.owner == r.owner && w.repo.repo == r.repo && w.branch == r.branch) {
      if (w.headSha == r.after) w.headSha = r.before;
      w.tree = null;
    }
    return null;
  }

  /// Undoes [id] and everything after it, in the repo and on the device.
  Future<String> undo(String id) async {
    final c = _checkpoint(id);
    if (c == null) return 'That restore point is no longer available.';
    final parts = <String>[];
    // Local side first: it also moves back branches pushed by the shell, which
    // the repo undo needs to see as unchanged.
    final local = await localUndo.restoreFrom(c.at);
    if (local.isNotEmpty) parts.add(local);
    final r = _repoCheckpointFrom(c);
    if (r != null) {
      parts.add(await workspace!.restore(r.id));
    }
    return parts.isEmpty ? 'Nothing to undo.' : parts.join(' ');
  }

  /// Null when no tool source is available (no repo selected and device
  /// file access switched off).
  AgentRunner? makeAgent(ChatMode mode) {
    final kits = <Toolkit>[];
    final g = gh, sel = selection;
    AgentWorkspace? active;
    if (settings.toolsEnabled && g != null && sel != null) {
      final key = sel.encode();
      if (_ws == null || _wsKey != key || !identical(_wsGh, g)) {
        _ws = AgentWorkspace(g, sel.repo, sel.branch, sel.workflowFile);
        _wsKey = key;
        _wsGh = g;
      }
      active = _ws;
      kits.add(AgentToolkit(_ws!, autoVerify: () => settings.autoVerify));
      kits.add(PreviewToolkit(() => active, delivery));
    }
    if (settings.deviceFilesEnabled && deviceFiles != null) {
      kits.add(UndoToolkit(deviceFiles!, localUndo, deviceFiles!.undoPlan));
    }
    if (settings.terminalEnabled) {
      kits.add(UndoToolkit(TerminalToolkit(terminalBridge, settings), localUndo,
          (n, a) => TerminalToolkit.undoPlan(terminalBridge, n, a)));
    }
    if (settings.browserEnabled) kits.add(BrowserToolkit(settings, terminalBridge.http));
    // Always available, so Build / Autonomous can hand results back in chat.
    kits.add(DeliveryToolkit(delivery, allowDevicePaths: settings.deviceFilesEnabled));
    // The visible checklist card.
    kits.add(PlanToolkit());
    final auto = mode == ChatMode.autonomous;
    return AgentRunner(
      router: router,
      toolkit: kits.length == 1 ? kits.first : ToolkitSet(kits),
      maxSteps: auto ? 100 : 40,
      maxDuration: auto ? const Duration(minutes: 45) : null,
      beginRun: active == null ? null : () => active!.beginRun(),
      notices: PreviewReports.instance.takeLateNote,
      modeNote: auto
          ? 'Mode: AUTONOMOUS. Work on your own until the task is finished. Do not ask questions unless you are truly blocked; make reasonable assumptions and state them. Go through every step needed, verify results (build, then fix errors yourself), then finish with a short summary. Actions that need approval wait for the user; never retry a denied action.'
          : 'Mode: BUILD. Work through the task step by step until it is complete: inspect first, make the change, then verify it (a failed build is yours to fix). End with a short summary of what changed and what is left.',
    );
  }

  static Future<AppServices> create() async {
    final a = AppServices();
    await a.settings.load();
    await a.skills.load();
    a.skillHub = SkillHub(
        gh: () => a.gh,
        connected: () => a.selection == null ? null : (repo: a.selection!.repo, branch: a.selection!.branch),
        store: a.skills);
    unawaited(a.skillHub.load());
    final docs = await getApplicationDocumentsDirectory();
    // Terminal: secrets, GitHub client and the /storage switch are looked up
    // lazily so token / setting changes apply immediately.
    a.terminalBridge
      ..secrets = ((name) async => name == 'github' ? a.store.githubToken() : null)
      ..github = (() => a.gh)
      ..storageAllowed = (() => a.settings.terminalStorage);
    a.deviceFiles = DeviceFileToolkit('${docs.path}/fs_trash');
    a.localUndo = LocalUndoLog('${docs.path}/undo_store');
    a.localUndo.stopJobs = () async {
      a.terminalBridge.jobs.killAll();
    };
    a.localUndo.undoPush = a._undoPush;
    await a.localUndo.init();
    // A `git push` made by the shell is remembered so Undo can move the branch back.
    a.terminalBridge.onPush = (owner, repo, branch, before, after) {
      a.localUndo.recordPush(owner, repo, branch, before, after);
      final w = a._ws;
      if (w != null && w.repo.owner == owner && w.repo.repo == repo && w.branch == branch) {
        if (w.headSha == before) w.headSha = after; // keep the repo undo's idea of the head current
        w.tree = null;
      }
    };
    unawaited(a.deviceFiles!.purgeOldTrash());
    a.providers = await ProviderRegistry(registryUrl).load();
    a.router = RouterService(client: a.client, chain: () => a.chain);
    a.proxyServer =
        ProxyServer(router: a.router, modelIds: () => [for (final e in a.chain) e.id]);
    a.proxy = ProxyController(a.proxyServer, a.store);
    a.gateways = LocalGateways(
      client: a.client,
      store: a.store,
      stats: a.router.stats,
      upstream: () => a.upstream,
      settings: a.settings,
      onChanged: () async {
        await a.rebuildChain();
        unawaited(a.refreshGatewayModels(force: true));
      },
    );
    await a.rebuildChain(); // fills `upstream`
    // Start the local gateway in the background; the chat shell can appear
    // immediately instead of waiting for the local proxy to bind its port.
    unawaited(a.gateways.init()); // OmniRoute starts by default
    unawaited(a.refreshGatewayModels()); // live model list, never blocks startup

    // Telegram bot: resume automatically so replies keep flowing after a restart.
    a.telegram = TelegramBridge(router: a.router, systemPrompt: a.settings.systemPrompt);
    final tgToken = await a.store.telegramToken();
    if (tgToken != null && tgToken.isNotEmpty) {
      unawaited(a.telegram.start(tgToken, chatId: await a.store.telegramChatId()));
    }

    // Restore GitHub session if we have a token + repo.
    final token = await a.store.githubToken();
    if (token != null && token.isNotEmpty) {
      a.gh = GitHubService(token);
      a.poller = BuildPoller(a.gh!);
      a.selection = RepoSelection.decode(await a.store.repoSelection());
      unawaited(a.skillHub.syncAll()); // pick up new skills in the background
    }
    return a;
  }

  // Models the built-in gateways reported via GET /models (id -> models).
  final Map<String, List<String>> _discovered = {};
  DateTime? _lastRefresh;

  /// Ask OmniRoute what they serve right now. Throttled, short
  /// timeout, and failures are silent: the always-present "auto" targets keep
  /// working even when the listing endpoint is down.
  Future<void> refreshGatewayModels({bool force = false}) async {
    final last = _lastRefresh;
    if (!force && last != null && DateTime.now().difference(last) < const Duration(seconds: 60)) {
      return;
    }
    _lastRefresh = DateTime.now();
    await Future.wait([
      for (final g in DefaultProviders.all)
        () async {
          try {
            final ep = Endpoint(
                providerId: g.id, baseUrl: g.baseUrl, apiKey: g.apiKey, model: 'auto');
            final ids = await client.listModels(ep).timeout(const Duration(seconds: 5));
            _discovered[g.id] = ids.where((m) => m != 'auto').take(40).toList();
          } catch (_) {
            _discovered.remove(g.id); // unreachable: don't offer stale models
          }
        }(),
    ]);
    await rebuildChain();
  }

  /// Ordered fallback chain:
  ///  1. OmniRoute "auto" (built in, zero setup)
  ///  3. any extra provider the user added a key for (optional)
  /// Models the gateways report are appended as pick-only entries, so the model
  /// switcher can pin one without lengthening the automatic fallback chain.
  Future<void> rebuildChain() async {
    final up = <Endpoint>[];
    final ordered = [
      ...providers.where((p) => p.id != 'custom'),
      ...providers.where((p) => p.id == 'custom'),
    ];
    for (final p in ordered) {
      if (DefaultProviders.isDefault(p.id)) continue;
      final isCustom = p.id == 'custom';
      final keys = await store.apiKeys(p.id);
      final base = isCustom ? (await store.baseUrl(p.id) ?? p.baseUrl) : p.baseUrl;
      if (base.isEmpty) continue;
      if (p.requiresKey && keys.isEmpty) continue;
      if (isCustom && keys.isEmpty && (await store.baseUrl(p.id)) == null) continue;
      if (_pointsAtOwnProxy(base)) continue; // would call itself in a loop
      final models = isCustom ? ['auto'] : p.models;
      for (final key in keys.isEmpty ? [''] : keys) {
        for (final m in models) {
          up.add(Endpoint(providerId: p.id, baseUrl: base, apiKey: key, model: m));
        }
      }
    }
    final upSig = up.map((e) => '${e.id}|${e.baseUrl}|${e.apiKey.hashCode}').join(';');
    if (_upSig != null && _upSig != upSig) gateways.resetCooldowns();
    _upSig = upSig;
    upstream = up;
    // Chat talks to the running embedded gateway. While it is stopped (or
    // failed to start) chat uses the providers directly, so it never goes dead.
    final out = <Endpoint>[
      for (final g in DefaultProviders.all)
        Endpoint(providerId: g.id, baseUrl: g.baseUrl, apiKey: g.apiKey, model: 'auto'),
      if (DefaultProviders.all.isEmpty) ...up,
    ];
    for (final g in DefaultProviders.all) {
      for (final m in _discovered[g.id] ?? const <String>[]) {
        out.add(Endpoint(
            providerId: g.id,
            baseUrl: g.baseUrl,
            apiKey: g.apiKey,
            model: m,
            // OmniRoute is the internal gateway; users select Auto or a
            // provider preset instead of seeing the gateway's own aliases.
            selectableOnly: g.id != DefaultProviders.omniRouteId));
      }
    }
    chain = out;
    final sig = out.map((e) => '${e.id}|${e.baseUrl}|${e.apiKey.hashCode}').join(';');
    if (_chainSig != null && _chainSig != sig) {
      router.resetCooldowns(); // config changed
      health.clear(); // old probe results no longer apply
    }
    _chainSig = sig;
  }

  String? _chainSig;
  String? _upSig;

  /// True if [url] targets this phone's own proxy port (loopback), which would
  /// make the app call itself.
  bool _pointsAtOwnProxy(String url) {
    final u = Uri.tryParse(OpenAICompatibleClient.normalizeBase(url));
    if (u == null) return false;
    const loop = {'localhost', '127.0.0.1', '::1', '[::1]', '0.0.0.0'};
    final port = u.hasPort ? u.port : (u.scheme == 'https' ? 443 : 80);
    final own = {proxy.port, DefaultProviders.omniRoutePort, gateways.port};
    return loop.contains(u.host) && own.contains(port);
  }
}

class BootstrapApp extends StatefulWidget {
  const BootstrapApp({super.key});

  @override
  State<BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<BootstrapApp> {
  late Future<AppServices> _app;

  @override
  void initState() {
    super.initState();
    _app = AppServices.create();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'AI Dev Hub',
        debugShowCheckedModeBanner: false,
        scrollBehavior: const IosScrollBehavior(),
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: FutureBuilder<AppServices>(
          future: _app,
          builder: (_, snap) {
            if (snap.hasError) {
              return _StartupView(error: '${snap.error}', onRetry: () => setState(() => _app = AppServices.create()));
            }
            if (!snap.hasData) return const _StartupView();
            return HubApp(snap.data!);
          },
        ),
      );
}

class _StartupView extends StatelessWidget {
  final String? error;
  final VoidCallback? onRetry;
  const _StartupView({this.error, this.onRetry});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const AiSparkle(size: 46, active: true),
              const SizedBox(height: 16),
              Text(error == null ? 'Starting AI Dev Hub…' : 'Startup needs attention', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              if (error == null) const LinearProgressIndicator(minHeight: 3),
              if (error != null) ...[
                Text(error!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                FilledButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ]),
          ),
        ),
      );
}

class HubApp extends StatelessWidget {
  final AppServices app;
  const HubApp(this.app, {super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app.settings,
        builder: (_, __) => MaterialApp(
          title: 'AI Dev Hub',
          debugShowCheckedModeBanner: false,
          themeMode: app.settings.themeMode,
          scrollBehavior: const IosScrollBehavior(),
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx)
                .copyWith(textScaler: TextScaler.linear(app.settings.fontScale)),
            child: BrowserHost(child: child!),
          ),
          home: HomeShell(app),
        ),
      );
}

class HomeShell extends StatefulWidget {
  final AppServices app;
  const HomeShell(this.app, {super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  AppServices get app => widget.app;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  List<ChatSession> _sessions = [];
  int _current = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    () async {
      _sessions = await app.sessions.load();
      if (_sessions.isEmpty) _sessions = [_newSession()];
      _current = _sessions.length - 1;
      if (mounted) setState(() => _ready = true);
    }();
  }

  ChatSession _newSession() => ChatSession('New chat', DateTime.now(), []);

  Future<void> _persist() => app.sessions.save(_sessions);

  void _onMessages(List<ChatMsg> msgs) {
    if (msgs.isEmpty) return;
    final old = _sessions[_current];
    final first = msgs.firstWhere((m) => m.role == 'user', orElse: () => msgs.first).text;
    final title = first.replaceAll('\n', ' ').trim();
    _sessions[_current] = ChatSession(
        title.length > 40 ? '${title.substring(0, 40)}…' : title, old.created, msgs);
    _persist();
  }

  void _newChat() {
    setState(() {
      _sessions.add(_newSession());
      _current = _sessions.length - 1;
    });
    _persist();
  }

  void _deleteChat(int i) {
    setState(() {
      _sessions.removeAt(i);
      if (_sessions.isEmpty) _sessions.add(_newSession());
      _current = _current.clamp(0, _sessions.length - 1);
      if (i < _current) _current--;
    });
    _persist();
  }

  void _push(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  /// Drawer entries close the drawer first, then navigate.
  void _go(VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }

  void _openSkills() => _push(SkillsScreen(store: app.skills, onBrowseGitHub: _openSkillHub));

  void _openSkillHub() => _push(SkillHubScreen(
        hub: app.skillHub,
        store: app.skills,
        connected: app.gh != null,
        onConnect: _openGitHub,
      ));

  void _openConnectors() => _push(ConnectorsScreen(
        settings: app.settings,
        files: app.files,
        githubConnected: app.gh != null,
        repoLabel: app.selection == null
            ? null
            : '${app.selection!.repo.owner}/${app.selection!.repo.repo}',
        onOpenGitHub: _openGitHub,
        telegram: app.telegram,
        store: app.store,
      ));

  void _openProviders() => _push(ProvidersScreen(
        providers: app.providers,
        store: app.store,
        client: app.client,
        stats: () => app.router.stats,
        onChanged: app.rebuildChain,
      ));


  void _openProxy() => _push(ProxyScreen(controller: app.proxy));

  void _openSettings() => _push(SettingsScreen(
        settings: app.settings,
        loadSessions: () async => _sessions,
        importSessions: (list) async {
          setState(() => _sessions.addAll(list));
          await _persist();
        },
        onOpenProviders: _openProviders,
        onOpenProxy: _openProxy,
        gateways: app.gateways,
      ));

  Widget _drawer() {
    final cs = Theme.of(context).colorScheme;
    return Drawer(
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text('AI Dev Hub', style: Theme.of(context).textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FilledButton.tonalIcon(
              onPressed: () => _go(_newChat),
              icon: const Icon(Icons.add_rounded),
              label: const Text('New chat'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text('Chats',
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: cs.onSurfaceVariant)),
          ),
          Expanded(
            child: ListView(padding: EdgeInsets.zero, children: [
              for (var i = _sessions.length - 1; i >= 0; i--)
                ListTile(
                  dense: true,
                  selected: i == _current,
                  selectedTileColor: cs.primary.withOpacity(0.14),
                  title: Text(_sessions[i].title, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    tooltip: 'Delete chat',
                    icon: const Icon(Icons.delete_outline_rounded, size: 20),
                    onPressed: () {
                      Navigator.of(context).pop();
                      _deleteChat(i);
                    },
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    setState(() => _current = i);
                  },
                ),
            ]),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('Skills'),
            onTap: () => _go(_openSkills),
          ),
          ListTile(
            leading: const Icon(Icons.extension_outlined),
            title: const Text('Connectors'),
            onTap: () => _go(_openConnectors),
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () => _go(_openSettings),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  // ---- builds -------------------------------------------------------------

  Stream<BuildStatus>? _triggerBuild() {
    final sel = app.selection, poller = app.poller;
    if (sel == null || poller == null) return null;
    return poller.run(sel.repo,
        workflowFile: sel.workflowFile,
        ref: sel.branch,
        correlationId: BuildPoller.newCorrelationId());
  }

  /// Download the artifact ZIP, unpack it, then install the APK or share the file.
  Future<List<Deliverable>> _downloadArtifact(BuildArtifact a) async {
    final zip = await app.poller!.downloadArtifactZip(a);
    final archive = ZipDecoder().decodeBytes(zip);
    final out = <Deliverable>[];
    for (final f in archive) {
      if (!f.isFile) continue;
      out.add(await app.delivery.saveBytes(f.name.split('/').last, f.content as List<int>));
    }
    // A build with no loose files (rare): hand over the original zip.
    if (out.isEmpty) out.add(await app.delivery.saveBytes('${a.name}.zip', zip));
    return out;
  }

  // ---- attach -------------------------------------------------------------

  Future<String?> _attachFile() async {
    try {
      final r = await FilePicker.platform.pickFiles();
      final path = r?.files.single.path;
      if (path == null) return null;
      final f = File(path);
      if (await f.length() > 200 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('File too large (limit 200 KB)')));
        }
        return null;
      }
      final text = await f.readAsString();
      final name = path.split('/').last;
      final ext = name.contains('.') ? name.split('.').last : '';
      return '```$ext path=$name\n$text\n```';
    } catch (_) {
      return null; // binary / unreadable
    }
  }

  Future<Attachment?> _attachPhoto() async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.image);
      final path = r?.files.single.path;
      if (path == null) return null;
      final f = File(path);
      if (await f.length() > 4 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Photo too large (limit 4 MB)')));
        }
        return null;
      }
      final name = path.split('/').last;
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : 'jpeg';
      final mime = switch (ext) {
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        _ => 'image/jpeg',
      };
      return Attachment(name, 'data:$mime;base64,${base64Encode(await f.readAsBytes())}');
    } catch (_) {
      return null;
    }
  }

  void _openGitHub() => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => GitHubScreen(
          store: app.store,
          onChanged: (gh, sel) {
            app.gh = gh;
            app.poller = BuildPoller(gh);
            app.selection = sel;
            if (mounted) setState(() {});
          },
        ),
      ));

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final s = app.settings;
    final session = _sessions[_current];

    return Scaffold(
      key: _scaffoldKey,
      drawer: _drawer(),
      body: ListenableBuilder(
        listenable: app.skills,
        builder: (_, __) => ChatScreen(
          key: ValueKey(session.created.toIso8601String()),
          router: app.router,
          models: app.router.available,
          health: app.health,
          onModelMenuOpen: () => app.refreshGatewayModels().then((_) {
            // Newly discovered models get verified too.
            app.health.check(app.router.available().where((e) => e.selectableOnly));
            if (mounted) setState(() {});
          }),
          systemPrompt: s.systemPrompt,
          skills: app.skills,
          onManageSkills: _openSkills,
          contextMessages: AppSettings.contextMessages,
          initial: session.messages,
          onMessagesChanged: _onMessages,
          onOpenMenu: () => _scaffoldKey.currentState?.openDrawer(),
          onNewChat: _newChat,
          onOpenGitHub: _openGitHub,
          githubConnected: app.gh != null,
          onTriggerBuild: _triggerBuild,
          onDownloadArtifact: _downloadArtifact,
          delivery: app.delivery,
          onPickFile: _attachFile,
          onPickPhoto: _attachPhoto,
          toolsEnabled: s.toolsEnabled || s.deviceFilesEnabled || s.terminalEnabled || s.browserEnabled,
          agentFactory: app.makeAgent,
          checkpoints: app.allCheckpoints,
          undoTouchesRemote: app.undoTouchesRemote,
          onUndo: (id) async {
            try {
              return await app.undo(id);
            } catch (e) {
              return 'Undo failed: $e';
            }
          },
        ),
      ),
    );
  }
}
