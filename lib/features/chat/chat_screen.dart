import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../core/chat_mode.dart';
import '../../core/haptics.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../services/agent/agent_runner.dart';
import '../../services/agent/agent_tools.dart' show ApprovalRequest;
import '../../services/build_poller.dart';
import '../../services/chat_codec.dart';
import '../../services/default_providers.dart';
import '../../services/deliverables.dart';
import '../../services/keep_alive.dart' as keep_alive;
import '../../services/model_health.dart';
import '../../services/router_service.dart';
import '../../services/skill_store.dart';
import 'build_card.dart';
import 'code_block.dart';
import 'deliverable_card.dart';

sealed class ChatItem {}

/// A photo attached to the next message (kept as a data: URL for vision models).
class Attachment {
  final String name, dataUrl;
  const Attachment(this.name, this.dataUrl);
}

class TextItem extends ChatItem {
  final String role; // user | assistant
  String text;
  bool streaming;
  String? error;
  final List<Attachment> images;
  TextItem(this.role, this.text,
      {this.streaming = false, this.images = const []});
}

class BuildItem extends ChatItem {
  final Stream<BuildStatus> status;
  BuildItem(this.status);
}

/// A file / zip / code / web app / APK delivered inline in the chat.
class DeliverableItem extends ChatItem {
  final Deliverable d;
  final bool autoRun;
  DeliverableItem(this.d, {this.autoRun = false});
}

/// One tool call made by the agent (ok == null while it runs).
class ToolItem extends ChatItem {
  final String id, name, label;
  String? summary;
  bool? ok;
  ToolItem(this.id, this.name, this.label);
}

/// Wire-up is by callbacks so this screen stays independent of your DI choice.
class ChatScreen extends StatefulWidget {
  final RouterService router;

  /// Models that are configured and currently reachable. Evaluated each time
  /// the model menu opens, so it always reflects what is available right now.
  final List<Endpoint> Function() models;
  final VoidCallback? onModelMenuOpen; // e.g. refresh the live model list
  final String systemPrompt;
  final SkillStore skills;
  final VoidCallback? onManageSkills;

  /// Return a status stream (BuildPoller.run(...)) or null if not configured.
  final Stream<BuildStatus>? Function()? onTriggerBuild;
  /// Download a finished build and return its files (APK, zip, ...), which
  /// the chat then shows as inline cards.
  final Future<List<Deliverable>> Function(BuildArtifact)? onDownloadArtifact;

  /// Where code blocks are saved when the user taps "Save as file" / "Run".
  final DeliveryStore? delivery;
  final VoidCallback? onOpenMenu; // side menu (chats, skills, connectors, settings)
  final VoidCallback? onNewChat;
  final VoidCallback? onOpenGitHub;
  final bool githubConnected;

  /// Return text to insert into the composer (e.g. a fenced file), or null.
  final Future<String?> Function()? onPickFile;
  final Future<Attachment?> Function()? onPickPhoto;
  final List<ChatMsg> initial;
  final ValueChanged<List<ChatMsg>>? onMessagesChanged;
  final int contextMessages;

  /// Agent mode: when [toolsEnabled], each send goes through the tool loop
  /// built by [agentFactory] (null return = tools unavailable, plain chat).
  final bool toolsEnabled;
  final AgentRunner? Function(ChatMode mode)? agentFactory;

  final ModelHealth? health;

  const ChatScreen({
    super.key,
    required this.router,
    required this.models,
    this.health,
    required this.skills,
    this.onModelMenuOpen,
    this.onManageSkills,
    this.systemPrompt = 'You are a helpful coding assistant.',
    this.onTriggerBuild,
    this.onDownloadArtifact,
    this.delivery,
    this.onOpenMenu,
    this.onNewChat,
    this.onOpenGitHub,
    this.githubConnected = false,
    this.onPickFile,
    this.onPickPhoto,
    this.initial = const [],
    this.onMessagesChanged,
    this.contextMessages = 30,
    this.toolsEnabled = false,
    this.agentFactory,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _items = <ChatItem>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<dynamic>? _sub;
  Timer? _flushTimer;
  String _deltaBuffer = '';
  AgentRunner? _agent;
  String _model = 'auto';
  late ChatMode _mode = widget.toolsEnabled ? ChatMode.build : ChatMode.chat;
  bool _kaHeld = false;

  void _queueDelta(TextItem reply, String delta) {
    _deltaBuffer += delta;
    _flushTimer ??= Timer(const Duration(milliseconds: 32), () {
      _flushTimer = null;
      if (!mounted || _deltaBuffer.isEmpty) return;
      final chunk = _deltaBuffer;
      _deltaBuffer = '';
      setState(() => reply.text += chunk);
      _scrollDown();
    });
  }

  void _keepAlive(bool on, [String text = 'Working...']) {
    if (on && !_kaHeld) {
      _kaHeld = true;
      keep_alive.KeepAlive.acquire(text);
    } else if (!on && _kaHeld) {
      _kaHeld = false;
      keep_alive.KeepAlive.release();
    }
  }
  final _pending = <Attachment>[];
  bool get _busy => _sub != null;

  // ---- voice input ----------------------------------------------------------
  final _speech = SpeechToText();
  bool _speechReady = false;
  bool _listening = false;
  String _beforeSpeech = '';

  Future<void> _toggleMic() async {
    Haptics.toggle();
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (!_speechReady) {
      _speechReady = await _speech.initialize(
        onStatus: (st) {
          if ((st == 'done' || st == 'notListening') && mounted) {
            setState(() => _listening = false);
          }
        },
        onError: (_) {
          if (mounted) setState(() => _listening = false);
        },
      );
    }
    if (!_speechReady) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Voice input unavailable. Allow microphone access and install a speech service.')));
      }
      return;
    }
    _beforeSpeech = _input.text.isEmpty ? '' : '${_input.text.trimRight()} ';
    setState(() => _listening = true);
    await _speech.listen(
      listenOptions: SpeechListenOptions(partialResults: true),
      onResult: (r) {
        _input.text = '$_beforeSpeech${r.recognizedWords}';
        _input.selection = TextSelection.collapsed(offset: _input.text.length);
      },
    );
  }

  static const _suggestions = <(IconData, String, String)>[
    (Icons.build_circle_outlined, 'Fix a bug', 'Help me find and fix a bug in my code. I will paste it next.'),
    (Icons.rocket_launch_outlined, 'Build an app', 'Build a small web app and show it running inline.'),
    (Icons.account_tree_outlined, 'Explain a repo', 'Walk me through the structure of my selected GitHub repo.'),
    (Icons.send_outlined, 'Draft a message', 'Draft a short, friendly follow-up message for me.'),
  ];

  @override
  void dispose() {
    _keepAlive(false);
    _speech.cancel();
    _agent?.cancel();
    _sub?.cancel();
    _flushTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    for (final m in widget.initial) {
      _items.add(TextItem(m.role, m.text));
    }
  }

  Object _content(TextItem i) => i.images.isEmpty
      ? i.text
      : [
          {'type': 'text', 'text': i.text.isEmpty ? 'Describe this image.' : i.text},
          for (final img in i.images)
            {'type': 'image_url', 'image_url': {'url': img.dataUrl}},
        ];

  List<Map<String, dynamic>> _history() {
    // Merge consecutive same-role text messages (e.g. a user message whose reply
    // failed, or assistant text split around tool calls): some providers
    // reject back-to-back messages with the same role. Messages with photos
    // are never merged.
    final msgs = <Map<String, dynamic>>[];
    for (final i in _items.whereType<TextItem>()) {
      if (i.text.isEmpty && i.images.isEmpty) continue;
      final c = _content(i);
      if (msgs.isNotEmpty &&
          msgs.last['role'] == i.role &&
          msgs.last['content'] is String &&
          c is String) {
        msgs.last['content'] = '${msgs.last['content']}\n\n$c';
      } else {
        msgs.add({'role': i.role, 'content': c});
      }
    }
    final n = widget.contextMessages;
    final recent = msgs.length > n ? msgs.sublist(msgs.length - n) : msgs;
    final modeInstruction = _mode == ChatMode.plan
        ? '\n\nPLAN MODE: Produce a clear implementation plan, assumptions, file-level changes, risks, and verification steps. Do not call tools, edit files, access repositories, or run commands.'
        : '';
    return [
      {'role': 'system', 'content': '${widget.systemPrompt}${widget.skills.promptAddendum}$modeInstruction'},
      ...recent,
    ];
  }

  void _notify() => widget.onMessagesChanged?.call([
        for (final i in _items.whereType<TextItem>())
          if (i.text.isNotEmpty || i.images.isNotEmpty)
            ChatMsg(i.role, [
              i.text,
              for (final img in i.images) '[Photo: ${img.name}]',
            ].where((x) => x.isNotEmpty).join('\n')),
      ]);

  Future<void> _attach() async {
    final t = await widget.onPickFile?.call();
    if (t != null && t.isNotEmpty) {
      _input.text = '${_input.text}\n$t'.trimLeft();
    }
  }

  Future<void> _attachPhoto() async {
    final a = await widget.onPickPhoto?.call();
    if (a != null && mounted) setState(() => _pending.add(a));
  }

  void _plusMenu() {
    Haptics.toggle();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: widget.skills,
          builder: (_, __) {
            final skills = widget.skills.skills;
            return SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (widget.onPickFile != null)
                  ListTile(
                    leading: const Icon(Icons.attach_file_rounded),
                    title: const Text('Upload file'),
                    subtitle: const Text('Text or code, up to 200 KB'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _attach();
                    },
                  ),
                if (widget.onPickPhoto != null)
                  ListTile(
                    leading: const Icon(Icons.photo_outlined),
                    title: const Text('Upload photo'),
                    subtitle: const Text('Needs a model that supports images'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _attachPhoto();
                    },
                  ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                  child: Row(children: [
                    Expanded(
                        child: Text('Skills',
                            style: Theme.of(ctx).textTheme.titleSmall)),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        widget.onManageSkills?.call();
                      },
                      child: const Text('Manage'),
                    ),
                  ]),
                ),
                if (skills.isEmpty)
                  ListTile(
                    leading: const Icon(Icons.add_rounded),
                    title: const Text('Add a skill'),
                    onTap: () {
                      Navigator.pop(ctx);
                      widget.onManageSkills?.call();
                    },
                  ),
                for (final k in skills)
                  SwitchListTile(
                    dense: true,
                    title: Text(k.name),
                    value: k.enabled,
                    onChanged: (v) {
                      Haptics.toggle();
                      widget.skills.setEnabled(k, v);
                    },
                  ),
                const SizedBox(height: 8),
              ]),
            );
          },
        ),
      ),
    );
  }

  void _scrollDown() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
        }
      });

  /// Code block -> file card in the chat.
  Future<void> _deliverCode(String code, String lang, {bool run = false}) async {
    final store = widget.delivery;
    if (store == null) return;
    try {
      final ext = Deliverable.extForLang(lang);
      final d = await store.saveText(run ? 'app.html' : 'snippet.$ext', code);
      if (!mounted) return;
      setState(() => _items.add(DeliverableItem(d, autoRun: run)));
      _scrollDown();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    }
  }

  /// Finished build -> its files appear right in the chat (APK gets Install).
  Future<void> _downloadInline(BuildArtifact a) async {
    final fn = widget.onDownloadArtifact;
    if (fn == null) return;
    try {
      final files = await fn(a);
      if (!mounted) return;
      setState(() => _items.addAll(files.map(DeliverableItem.new)));
      _scrollDown();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    }
  }

  void _send() {
    final text = _input.text.trim();
    if ((text.isEmpty && _pending.isEmpty) || _busy) return;
    Haptics.send();
    _input.clear();

    // A model that dropped out (rate-limited / unreachable) falls back to Auto.
    if (_model != 'auto' &&
        !widget.models().any((e) => e.id == _model)) {
      _model = 'auto';
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('That model is unavailable right now. Using Auto.')));
    }

    final reply = TextItem('assistant', '', streaming: true);
    final imgs = List<Attachment>.of(_pending);
    setState(() {
      _pending.clear();
      _items..add(TextItem('user', text, images: imgs))..add(reply);
    });
    _scrollDown();

    final agent = _mode.usesTools ? widget.agentFactory?.call(_mode) : null;
    if (_mode.usesTools && agent == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${_mode.label} mode needs a tool source: GitHub repo (tap the GitHub icon), Device file access or Terminal in Settings. Sending as plain chat.')));
    }
    if (agent != null) {
      _runAgent(agent, reply);
      return;
    }

    final req = ChatRequest(
      model: _model,
      messages: _history(), // empty assistant placeholder is already excluded
    );

    _sub = widget.router.stream(req).listen(
      (payload) {
        final d = _delta(payload);
        if (d == null) return;
        _queueDelta(reply, d);
      },
      onError: (e) {
        Haptics.error();
        setState(() {
          reply.error = '$e';
          reply.streaming = false;
          _sub = null;
        });
        _notify();
      },
      onDone: () {
        _flushTimer?.cancel();
        _flushTimer = null;
        if (_deltaBuffer.isNotEmpty) {
          reply.text += _deltaBuffer;
          _deltaBuffer = '';
        }
        setState(() {
          reply.streaming = false;
          if (reply.text.isEmpty && reply.error == null) {
            reply.error = 'The model returned an empty response.';
          }
          _sub = null;
        });
        _notify();
      },
    );
  }

  Future<bool> _approve(ApprovalRequest r) async {
    if (!mounted) return false;
    Haptics.toggle();
    keep_alive.KeepAlive.update('Waiting for your approval: ${r.title}');
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(r.title),
        content: SingleChildScrollView(
          child: Text(r.detail,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Deny')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Approve')),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Drives one agent turn. Assistant text, tool calls and build cards are
  /// appended to the list in the order they happen.
  void _runAgent(AgentRunner agent, TextItem first) {
    _agent = agent;
    _keepAlive(true, '${_mode.label} task running');
    TextItem? cur = first; // bubble currently receiving streamed text
    var usedTools = false;

    void finish() {
      final c = cur;
      if (c != null) {
        c.streaming = false;
        if (c.text.isEmpty && c.error == null) {
          if (usedTools) {
            _items.remove(c);
          } else {
            c.error = 'The model returned an empty response.';
          }
        }
      }
      _agent = null;
      _sub = null;
      _keepAlive(false);
    }

    _sub = agent
        .run(
          messages: _history(),
          model: _model,
          approve: _approve,
        )
        .listen(
      (e) {
        switch (e) {
          case AgentText(:final delta):
            setState(() {
              if (cur == null) {
                cur = TextItem('assistant', '', streaming: true);
                _items.add(cur!);
              }
              cur!.text += delta;
            });
            _scrollDown();
          case AgentToolStart(:final id, :final name, :final label):
            usedTools = true;
            keep_alive.KeepAlive.update(label);
            if (name.startsWith('terminal_')) return;
            setState(() {
              final c = cur;
              if (c != null) {
                c.streaming = false;
                if (c.text.isEmpty) _items.remove(c);
              }
              cur = null;
              _items.add(ToolItem(id, name, label));
            });
            _scrollDown();
          case AgentToolDone(:final id, :final ok, :final summary):
            setState(() {
              var visible = false;
              for (final t in _items.whereType<ToolItem>()) {
                if (t.id == id) {
                  visible = true;
                  t.ok = ok;
                  t.summary = summary;
                }
              }
              // Spinner while the model reads the tool result.
              if (visible) {
                cur = TextItem('assistant', '', streaming: true);
                _items.add(cur!);
              }
            });
            if (_items.isNotEmpty) _scrollDown();
          case AgentBuild(:final status):
            setState(() => _items.add(BuildItem(status.asBroadcastStream())));
            _scrollDown();
          case AgentDeliver(:final items):
            setState(() {
              for (final d in items) {
                _items.add(DeliverableItem(d, autoRun: d.kind == DeliverableKind.html));
              }
            });
            Haptics.copy();
            _scrollDown();
          case AgentNotice(:final text):
            setState(() {
              final c = cur;
              if (c != null && c.text.isEmpty) _items.remove(c);
              cur = TextItem('assistant', text);
              _items.add(cur!);
            });
            _scrollDown();
        }
      },
      onError: (Object err) {
        Haptics.error();
        setState(() {
          if (cur == null) {
            cur = TextItem('assistant', '');
            _items.add(cur!);
          }
          cur!.error = '$err';
          finish();
        });
        _notify();
      },
      onDone: () {
        setState(finish);
        _notify();
      },
    );
  }

  String? _delta(String payload) {
    if (payload == '[DONE]') return null;
    try {
      final ch = (jsonDecode(payload) as Map)['choices'] as List?;
      if (ch == null || ch.isEmpty) return null;
      final c = ((ch.first as Map)['delta'] as Map?)?['content'];
      return c is String ? c : null;
    } catch (_) {
      return null;
    }
  }

  void _stop() {
    _keepAlive(false);
    _agent?.cancel();
    _agent = null;
    _sub?.cancel();
    setState(() {
      if (_items.isNotEmpty && _items.last is TextItem) {
        final t = _items.last as TextItem;
        t.streaming = false;
        if (t.text.isEmpty && t.error == null) _items.removeLast();
      }
      _sub = null;
    });
    _notify();
  }

  void _build() {
    final s = widget.onTriggerBuild?.call();
    if (s == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Connect GitHub and choose a repo first')));
      return;
    }
    Haptics.toggle();
    setState(() => _items.add(BuildItem(s.asBroadcastStream())));
    _scrollDown();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: AppBar(
              leading: IconButton(
                  tooltip: 'Menu',
                  icon: const Icon(Icons.menu_rounded),
                  onPressed: widget.onOpenMenu),
              title: _ModelPicker(
                mode: _mode,
                onMode: (m) {
                  Haptics.toggle();
                  setState(() => _mode = m);
                },
                value: _model,
                choices: () => widget.models(),
                health: widget.health,
                onOpen: widget.onModelMenuOpen,
                onChanged: (m) {
                  Haptics.toggle();
                  setState(() => _model = m);
                },
              ),
              centerTitle: true,
              actions: [
                IconButton(
                  tooltip: 'GitHub',
                  onPressed: widget.onOpenGitHub,
                  icon: Stack(clipBehavior: Clip.none, children: [
                    const FaIcon(FontAwesomeIcons.github, size: 22),
                    if (widget.githubConnected)
                      Positioned(
                        right: -2,
                        top: -2,
                        child: Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: const Color(0xFF30D158),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: Theme.of(context).colorScheme.surface,
                                width: 1.5),
                          ),
                        ),
                      ),
                  ]),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  icon: const Icon(Icons.more_vert_rounded),
                  onSelected: (v) {
                    if (v == 'new') widget.onNewChat?.call();
                    if (v == 'build') _build();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'new',
                        child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.add_comment_outlined),
                            title: Text('New chat'))),
                    PopupMenuItem(
                        value: 'build',
                        child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.rocket_launch_outlined),
                            title: Text('Build APK / ZIP'))),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      body: Column(children: [
        Expanded(
          child: _items.isEmpty
              ? _Suggestions(
                  items: _suggestions,
                  onTap: (prompt) {
                    _input.text = prompt;
                    _send();
                  })
              : ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(
                12, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 12, 12),
            itemCount: _items.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: switch (_items[i]) {
                final TextItem t => _Bubble(item: t, onDeliver: _deliverCode),
                final DeliverableItem x => DeliverableCard(d: x.d, autoRun: x.autoRun),
                final ToolItem t => _ToolRow(item: t),
                final BuildItem b => BuildCard(
                    status: b.status,
                    onDownload: _downloadInline),
              },
            ),
          ),
        ),
        _Composer(
          controller: _input,
          busy: _busy,
          pending: _pending,
          onRemovePending: (a) => setState(() => _pending.remove(a)),
          onSend: _send,
          onStop: _stop,
          onPlus: _plusMenu,
          listening: _listening,
          onMic: _toggleMic,
        ),
      ]),
    );
  }
}

String modelLabel(String id) {
  if (id == 'auto') return 'Auto';
  final i = id.indexOf('/');
  if (i < 0) return id;
  final provider = DefaultProviders.label(id.substring(0, i));
  final model = id.substring(i + 1);
  return '$provider · ${model == 'auto' ? 'Auto' : model}';
}

/// Compact model switcher. Tapping opens a sheet with the chat mode and the
/// models that are active (gateway running), available (not cooling down) and
/// capable of running (a live test request succeeded). Checks run when the
/// sheet opens and the list fills in as results arrive.
class _ModelPicker extends StatelessWidget {
  final ChatMode mode;
  final ValueChanged<ChatMode> onMode;
  final String value;
  final List<Endpoint> Function() choices;
  final ModelHealth? health;
  final VoidCallback? onOpen;
  final ValueChanged<String> onChanged;
  const _ModelPicker(
      {required this.mode,
      required this.onMode,
      required this.value,
      required this.choices,
      required this.onChanged,
      this.health,
      this.onOpen});

  void _open(BuildContext context) {
    onOpen?.call();
    health?.check(choices().where((e) => e.selectableOnly));
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _ModelSheet(
        mode: mode,
        onMode: (m) {
          Navigator.pop(ctx);
          onMode(m);
        },
        value: value,
        choices: choices,
        health: health,
        onPick: (id) {
          Navigator.pop(ctx);
          onChanged(id);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _open(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
              child: Text('${mode.label} · ${modelLabel(value)}',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: cs.onSurface))),
          const SizedBox(width: 2),
          Icon(Icons.expand_more_rounded, size: 18, color: cs.onSurface),
        ]),
      ),
    );
  }
}

class _ModelSheet extends StatelessWidget {
  final ChatMode mode;
  final ValueChanged<ChatMode> onMode;
  final String value;
  final List<Endpoint> Function() choices;
  final ModelHealth? health;
  final ValueChanged<String> onPick;
  const _ModelSheet(
      {required this.mode,
      required this.onMode,
      required this.value,
      required this.choices,
      required this.health,
      required this.onPick});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: health ?? ValueNotifier(0),
      builder: (ctx, _) {
        // Selectable (pinnable) models only; "auto" is its own row.
        final all = choices().where((e) => e.selectableOnly).toList();
        final ok = [
          for (final e in all)
            if (health == null || health!.stateOf(e) == ModelState.ok) e
        ];
        final checking = health?.pending ?? 0;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.75),
            child: ListView(shrinkWrap: true, children: [
              for (final m in ChatMode.values)
                ListTile(
                  dense: true,
                  title: Text(m.label),
                  subtitle: Text(m.hint),
                  trailing: mode == m ? const Icon(Icons.check_rounded) : null,
                  onTap: () => onMode(m),
                ),
              const Divider(),
              ListTile(
                title: const Text('Auto (best available)'),
                subtitle: Text(ok.isEmpty
                    ? 'Routes to whichever provider works right now'
                    : '${ok.length} verified model${ok.length == 1 ? '' : 's'}'),
                trailing:
                    value == 'auto' ? const Icon(Icons.check_rounded) : null,
                onTap: () => onPick('auto'),
              ),
              for (final e in ok)
                ListTile(
                  dense: true,
                  title: Text(modelLabel(e.id), overflow: TextOverflow.ellipsis),
                  subtitle: Text('Verified · ${health?.latencyOf(e) ?? 0} ms'),
                  trailing:
                      value == e.id ? const Icon(Icons.check_rounded) : null,
                  onTap: () => onPick(e.id),
                ),
              if (checking > 0)
                ListTile(
                  dense: true,
                  leading: const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  title: Text('Checking $checking model${checking == 1 ? '' : 's'}…',
                      style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                )
              else
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.refresh_rounded),
                  title: Text(
                      all.isEmpty
                          ? 'No models found. Check your provider keys.'
                          : '${all.length - ok.length} unavailable hidden · Re-check',
                      style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                  onTap: () => health?.check(all, force: true),
                ),
            ]),
          ),
        );
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  final TextItem item;
  final void Function(String code, String lang, {bool run})? onDeliver;
  const _Bubble({required this.item, this.onDeliver});

  @override
  Widget build(BuildContext context) {
    final isUser = item.role == 'user';
    final cs = Theme.of(context).colorScheme;
    final maxW = MediaQuery.of(context).size.width * (isUser ? 0.82 : 1.0);

    final content = isUser
        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final img in item.images)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.photo_outlined, size: 16, color: cs.onPrimary),
                  const SizedBox(width: 6),
                  Flexible(
                      child: Text(img.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: cs.onPrimary))),
                ]),
              ),
            if (item.text.isNotEmpty)
              Text(item.text, style: TextStyle(color: cs.onPrimary)),
          ])
        : item.text.isEmpty && item.error == null
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                MarkdownBody(
                  data: item.text + (item.streaming ? ' ▍' : ''),
                  selectable: false, // selectable + builders conflict; code has copy buttons
                  builders: {'code': CodeBlockBuilder(onDeliver: onDeliver)},
                ),
                if (item.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(item.error!,
                        style: TextStyle(color: cs.error, fontSize: 12)),
                  ),
                if (!item.streaming && item.text.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      tooltip: 'Copy response',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      color: cs.onSurfaceVariant,
                      icon: const Icon(Icons.copy_rounded),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: item.text));
                        Haptics.copy();
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                duration: Duration(seconds: 1),
                                content: Text('Copied')));
                      },
                    ),
                  ),
              ]);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: isUser
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                    color: cs.primary, borderRadius: BorderRadius.circular(20)),
                child: content)
            // Assistant replies sit flat on the page (no bubble), full width,
            // so text, steps and file cards read as one continuous thread.
            : Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: content),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool busy;
  final List<Attachment> pending;
  final ValueChanged<Attachment> onRemovePending;
  final VoidCallback onSend, onStop, onPlus, onMic;
  final bool listening;
  const _Composer(
      {required this.controller,
      required this.busy,
      required this.pending,
      required this.onRemovePending,
      required this.onSend,
      required this.onStop,
      required this.onPlus,
      required this.onMic,
      required this.listening});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
        child: Glass(
          radius: 26,
          padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (pending.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final a in pending)
                      InputChip(
                        avatar: Icon(Icons.photo_outlined,
                            size: 16, color: cs.onSurface),
                        label: Text(a.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: cs.onSurface)),
                        onDeleted: () => onRemovePending(a),
                      ),
                  ]),
                ),
              ),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              IconButton(
                  tooltip: 'Add files, photos and skills',
                  icon: const Icon(Icons.add_circle_outline_rounded),
                  onPressed: onPlus),
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  style: TextStyle(color: cs.onSurface),
                  decoration: InputDecoration(
                      hintText: listening ? 'Listening…' : 'Message',
                      hintStyle: TextStyle(color: cs.onSurfaceVariant),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
              IconButton(
                tooltip: listening ? 'Stop listening' : 'Voice input',
                icon: Icon(listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                    color: listening ? cs.error : null),
                onPressed: onMic,
              ),
              IconButton.filled(
                icon: Icon(busy ? Icons.stop_rounded : Icons.arrow_upward_rounded),
                onPressed: busy ? onStop : onSend,
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _ToolRow extends StatelessWidget {
  final ToolItem item;
  const _ToolRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ok = item.ok;
    final Widget leading = ok == null
        ? const SizedBox(
            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
            size: 18, color: ok ? cs.primary : cs.error);
    return Align(
      alignment: Alignment.centerLeft,
      child: Glass(
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          leading,
          const SizedBox(width: 10),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.label,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  overflow: TextOverflow.ellipsis),
              if (item.summary != null)
                Text(item.summary!,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      ),
    );
  }
}


/// Empty-state suggestion buttons; tapping one sends that prompt.
class _Suggestions extends StatelessWidget {
  final List<(IconData, String, String)> items;
  final ValueChanged<String> onTap;
  const _Suggestions({required this.items, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('What can I help with?',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
            for (final (icon, label, prompt) in items)
              ActionChip(
                avatar: Icon(icon, size: 18, color: cs.onSurface),
                label: Text(label, style: TextStyle(color: cs.onSurface)),
                onPressed: () {
                  Haptics.toggle();
                  onTap(prompt);
                },
              ),
          ]),
        ]),
      ),
    );
  }
}
