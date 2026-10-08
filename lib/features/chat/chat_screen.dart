import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart' show CupertinoSlidingSegmentedControl;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../core/chat_mode.dart';
import '../../core/haptics.dart';
import '../../core/models.dart';
import '../../core/sparkle.dart';
import '../../core/theme.dart';
import '../../services/agent/agent_runner.dart';
import '../../services/agent/agent_tools.dart' show ApprovalRequest, Checkpoint;
import '../../services/agent/plan.dart';
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
import 'plan_card.dart';

sealed class ChatItem {
  /// Creation time (ms). 0 = restored from history (never animates in).
  int born = DateTime.now().millisecondsSinceEpoch;
}

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
  String? checkpoint; // undo point taken before this step
  bool undone = false;
  ToolItem(this.id, this.name, this.label);
}

/// The agent's checklist. One card per run, updated in place.
class PlanItem extends ChatItem {
  PlanSnapshot plan;
  PlanItem(this.plan);
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

  /// Undo: restore points of the active repo workspace (oldest first), whether
  /// restoring one also moves the branch on GitHub, and the restore itself.
  final List<Checkpoint> Function()? checkpoints;
  final bool Function(String id)? undoTouchesRemote;
  final Future<String> Function(String id)? onUndo;

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
    this.checkpoints,
    this.undoTouchesRemote,
    this.onUndo,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with SingleTickerProviderStateMixin {
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

  // ---- smooth auto-follow ---------------------------------------------------
  // Streamed text is revealed by the bubble itself (see _StreamedMarkdown), so
  // the screen no longer rebuilds the whole list for every network chunk. A
  // per-frame ticker eases the scroll position to the bottom while the user
  // has not scrolled away.
  late final Ticker _follow = createTicker(_followTick);
  bool _pinned = true, _showJump = false, _selfScroll = false;
  Duration _lastMove = Duration.zero;

  void _startFollow() {
    if (!_follow.isActive) {
      _lastMove = Duration.zero;
      _follow.start();
    }
  }

  void _followTick(Duration e) {
    final idle = !_busy && e - _lastMove > const Duration(milliseconds: 1500);
    if (!_scroll.hasClients) {
      if (idle) _follow.stop();
      return;
    }
    final p = _scroll.position;
    final diff = p.maxScrollExtent - p.pixels;
    if (_pinned && diff > 0.5 && p.userScrollDirection == ScrollDirection.idle) {
      _selfScroll = true;
      _scroll.jumpTo(diff < 1.5 ? p.maxScrollExtent : p.pixels + diff * 0.25 + 0.5);
      _selfScroll = false;
      _lastMove = e;
    } else if (idle) {
      _follow.stop();
    }
  }

  void _onScroll() {
    if (_selfScroll || !_scroll.hasClients) return;
    final p = _scroll.position;
    final near = p.maxScrollExtent - p.pixels < 90;
    _pinned = near;
    final jump = !near && p.maxScrollExtent > 300;
    if (jump != _showJump && mounted) setState(() => _showJump = jump);
  }

  void _jumpToBottom() {
    Haptics.toggle();
    _pinned = true;
    setState(() => _showJump = false);
    _startFollow();
  }

  void _queueDelta(TextItem reply, String delta) {
    _deltaBuffer += delta;
    _flushTimer ??= Timer(const Duration(milliseconds: 40), () {
      _flushTimer = null;
      if (!mounted || _deltaBuffer.isEmpty) return;
      final chunk = _deltaBuffer;
      _deltaBuffer = '';
      final wasEmpty = reply.text.isEmpty;
      reply.text += chunk;
      // Only the first chunk needs a rebuild (typing dots -> text). After that
      // the bubble animates by itself.
      if (wasEmpty) setState(() {});
    });
  }

  void _flushDelta(TextItem? reply) {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (reply != null && _deltaBuffer.isNotEmpty) {
      reply.text += _deltaBuffer;
      _deltaBuffer = '';
    }
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
    _follow.dispose();
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    for (final m in widget.initial) {
      _items.add(TextItem(m.role, m.text)..born = 0);
    }
    if (_items.isNotEmpty) {
      // Reopen an existing chat at the latest message.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _selfScroll = true;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
        _selfScroll = false;
        _startFollow();
      });
    }
  }

  Object _content(TextItem i) => i.images.isEmpty
      ? i.text
      : [
          {'type': 'text', 'text': i.text.isEmpty ? 'Describe this image.' : i.text},
          for (final img in i.images)
            {'type': 'image_url', 'image_url': {'url': img.dataUrl}},
        ];

  List<Map<String, dynamic>> _history([String? task]) {
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
    final latestTask = task ?? (recent.where((m) => m['role'] == 'user').isEmpty
        ? null
        : recent.lastWhere((m) => m['role'] == 'user')['content']?.toString());
    return [
      {'role': 'system', 'content': '${widget.systemPrompt}${widget.skills.promptAddendumFor(latestTask)}$modeInstruction'},
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

  void _scrollDown() {
    if (_pinned) _startFollow();
  }

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
    _dispatch(text, List<Attachment>.of(_pending));
  }

  /// Re-run the last user message and replace the previous answer.
  void _regenerate() {
    if (_busy) return;
    final i = _items.lastIndexWhere((e) => e is TextItem && e.role == 'user');
    if (i < 0) return;
    final u = _items[i] as TextItem;
    Haptics.send();
    setState(() => _items.removeRange(i + 1, _items.length));
    _dispatch(u.text, u.images, reuseUser: true);
  }

  /// Pull a sent message back into the composer; later messages are dropped.
  void _edit(TextItem t) {
    if (_busy) return;
    final i = _items.indexOf(t);
    if (i < 0) return;
    setState(() => _items.removeRange(i, _items.length));
    _input.text = t.text;
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _notify();
  }

  void _selectText(String text) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: SelectableText(text,
                style: const TextStyle(fontSize: 16, height: 1.5)),
          ),
        ),
      ),
    );
  }

  /// iOS-style action sheet for a message (long-press).
  void _messageMenu(TextItem t) {
    final isUser = t.role == 'user';
    final lastAssistant = _items.isNotEmpty &&
        identical(_items.last, t) &&
        !isUser;
    Widget action(IconData icon, String label, VoidCallback run) => ListTile(
          leading: Icon(icon),
          title: Text(label),
          onTap: () {
            Navigator.pop(context);
            run();
          },
        );
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          action(Icons.copy_rounded, 'Copy', () {
            Clipboard.setData(ClipboardData(text: t.text));
            Haptics.copy();
          }),
          action(Icons.text_fields_rounded, 'Select text',
              () => _selectText(t.text)),
          action(Icons.ios_share_rounded, 'Share',
              () => SharePlus.instance.share(ShareParams(text: t.text))),
          if (isUser && !_busy)
            action(Icons.edit_outlined, 'Edit and resend', () => _edit(t)),
          if (lastAssistant && !_busy)
            action(Icons.refresh_rounded, 'Regenerate', _regenerate),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  void _dispatch(String text, List<Attachment> imgs, {bool reuseUser = false}) {
    // A model that dropped out (rate-limited / unreachable) falls back to Auto.
    if (_model != 'auto' &&
        !widget.models().any((e) => e.id == _model)) {
      _model = 'auto';
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('That model is unavailable right now. Using Auto.')));
    }

    final reply = TextItem('assistant', '', streaming: true);
    setState(() {
      if (!reuseUser) _pending.clear();
      _pinned = true;
      _showJump = false;
      if (!reuseUser) _items.add(TextItem('user', text, images: imgs));
      _items.add(reply);
    });
    _startFollow();

    final agent = _mode.usesTools ? widget.agentFactory?.call(_mode) : null;
    if (_mode.usesTools && agent == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${_mode.label} mode needs a tool source: GitHub repo (More menu > GitHub), Device file access or Terminal in Settings. Sending as plain chat.')));
    }
    if (agent != null) {
      _runAgent(agent, reply);
      return;
    }

    final req = ChatRequest(
      model: _model,
      messages: _history(text), // empty assistant placeholder is already excluded
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
          reply.error = _friendlyFailure(e);
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
        Haptics.done();
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
    PlanItem? curPlan; // checklist card of this run
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
            if (cur == null) {
              setState(() {
                cur = TextItem('assistant', '', streaming: true);
                _items.add(cur!);
              });
            }
            _queueDelta(cur!, delta);
          case AgentToolStart(:final id, :final name, :final label):
            usedTools = true;
            // The terminal is invisible: no row, and no command text in the
            // notification either.
            final hidden = name.startsWith('terminal_') || name == 'update_plan';
            keep_alive.KeepAlive.update(name.startsWith('terminal_')
                ? 'Working in the background…'
                : (name == 'update_plan' ? 'Planning…' : label));
            if (hidden) return;
            _flushDelta(cur);
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
          case AgentPlan(:final plan):
            setState(() {
              final p = curPlan;
              if (p == null || !_items.contains(p)) {
                final c = cur;
                if (c != null && c.text.isEmpty) {
                  _items.remove(c);
                  cur = null;
                }
                curPlan = PlanItem(plan);
                _items.add(curPlan!);
              } else {
                p.plan = plan;
              }
            });
            _scrollDown();
          case AgentToolDone(:final id, :final ok, :final summary, :final checkpoint):
            setState(() {
              var visible = false;
              for (final t in _items.whereType<ToolItem>()) {
                if (t.id == id) {
                  visible = true;
                  t.ok = ok;
                  t.summary = summary;
                  t.checkpoint = checkpoint;
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
                // Never execute generated code automatically. The user gets an
                // explicit Preview/Run action on the delivered card.
                _items.add(DeliverableItem(d, autoRun: false));
              }
            });
            Haptics.copy();
            _scrollDown();
          case AgentNotice(:final text):
            _flushDelta(cur);
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
        _flushDelta(cur);
        setState(() {
          if (cur == null) {
            cur = TextItem('assistant', '');
            _items.add(cur!);
          }
          cur!.error = _friendlyFailure(err);
          finish();
        });
        _notify();
      },
      onDone: () {
        _flushDelta(cur);
        setState(finish);
        Haptics.done();
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

  static String _friendlyFailure(Object error) {
    final text = '$error'.toLowerCase();
    String detail = '$error'
        .replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9._\-]+', caseSensitive: false), 'Bearer [redacted]')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (detail.length > 180) detail = '${detail.substring(0, 180)}…';
    if (text.contains('401') || text.contains('403') || text.contains('invalid key')) {
      return 'Failed · API key or permission issue\n$detail';
    }
    if (text.contains('timeout') || text.contains('timed out')) {
      return 'Failed · Request timed out\n$detail';
    }
    if (text.contains('rate') || text.contains('429')) {
      return 'Failed · Provider rate limit reached\n$detail';
    }
    return 'Failed · Please try again or switch provider\n$detail';
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

  /// Asks, then restores the repo to the state before this step.
  Future<void> _undo(ToolItem t) async {
    final id = t.checkpoint;
    if (id == null) return;
    final remote = widget.undoTouchesRemote?.call(id) ?? false;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Undo this step?'),
        content: Text(
            'Goes back to how things were before:\n${t.label}\n\nLater steps are undone too.'
            '${remote ? '\n\nThis includes commits made since: the branch is moved back on GitHub.' : ''}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Undo')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    Haptics.toggle();
    final msg = await widget.onUndo!(id);
    if (!mounted) return;
    // Restored points (and everything after them) are gone: mark those steps.
    final alive = {for (final c in widget.checkpoints?.call() ?? const <Checkpoint>[]) c.id};
    setState(() {
      for (final i in _items) {
        if (i is ToolItem && i.checkpoint != null && !alive.contains(i.checkpoint)) {
          i.undone = true;
        }
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showCheckpoints() {
    final list = (widget.checkpoints?.call() ?? const <Checkpoint>[]).reversed.toList();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: list.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(32),
                child: Text('No undo points yet. One is saved before every change the agent makes.',
                    textAlign: TextAlign.center))
            : ListView.separated(
                shrinkWrap: true,
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final c = list[i];
                  final hh = c.at.hour.toString().padLeft(2, '0');
                  final mm = c.at.minute.toString().padLeft(2, '0');
                  return ListTile(
                    title: Text(c.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                    subtitle: Text('Before this step · $hh:$mm'),
                    trailing: TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              Navigator.pop(ctx);
                              final t = ToolItem(c.id, 'restore', c.label)..checkpoint = c.id;
                              _undo(t);
                            },
                      child: const Text('Restore'),
                    ),
                  );
                },
              ),
      ),
    );
  }

  void _showTaskInfo() {
    final r = widget.router;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: ListView(shrinkWrap: true, children: [
              Row(children: [
                Icon(Icons.insights_rounded, color: cs.primary),
                const SizedBox(width: 10),
                Text('Task Info', style: Theme.of(ctx).textTheme.titleLarge),
              ]),
              const SizedBox(height: 4),
              Text('Live usage across all configured API routes', style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: _StatTile('Total tokens', _fmt(r.totalTokens), Icons.token_rounded)),
                const SizedBox(width: 8),
                Expanded(child: _StatTile('Requests', '${r.totalRequests}', Icons.swap_vert_rounded)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _StatTile('Input', _fmt(r.totalPromptTokens), Icons.arrow_downward_rounded)),
                const SizedBox(width: 8),
                Expanded(child: _StatTile('Output', _fmt(r.totalCompletionTokens), Icons.arrow_upward_rounded)),
              ]),
              const SizedBox(height: 16),
              Text('Remaining quota', style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: 4),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.account_balance_outlined),
                title: const Text('Provider quota'),
                subtitle: const Text('Not reported by most OpenAI-compatible APIs; usage above is tracked locally.'),
              ),
              if (r.totalErrors > 0)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.error_outline_rounded, color: cs.error),
                  title: Text('${r.totalErrors} failed request${r.totalErrors == 1 ? '' : 's'}'),
                  subtitle: const Text('Failed requests do not add token usage.'),
                ),
              if (r.providerUsage.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('By provider / all API keys', style: Theme.of(ctx).textTheme.titleSmall),
                for (final row in r.providerUsage)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(Icons.hub_outlined, size: 20),
                    title: Text(row.$1),
                    subtitle: Text('${_fmt(row.$2.promptTokens + row.$2.completionTokens)} tokens · ${row.$2.requests} requests'),
                  ),
              ],
            ]),
          ),
        );
      },
    );
  }

  static String _fmt(int n) => n >= 1000000
      ? '${(n / 1000000).toStringAsFixed(1)}M'
      : n >= 1000
          ? '${(n / 1000).toStringAsFixed(1)}K'
          : '$n';

  /// Show the AI mark only at the start of an assistant turn.
  bool _avatarFor(int i) {
    if (i == 0) return true;
    final p = _items[i - 1];
    if (p is ToolItem || p is PlanItem) return false;
    return !(p is TextItem && p.role == 'assistant');
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
                  tooltip: 'New chat',
                  onPressed: widget.onNewChat,
                  icon: const Icon(Icons.edit_outlined),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  icon: Stack(clipBehavior: Clip.none, children: [
                    const Icon(Icons.more_horiz_rounded),
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
                  onSelected: (v) {
                    Haptics.toggle();
                    if (v == 'info') _showTaskInfo();
                    if (v == 'github') widget.onOpenGitHub?.call();
                    if (v == 'build') _build();
                    if (v == 'checkpoints') _showCheckpoints();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'info',
                        child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.insights_outlined),
                            title: Text('Task info'))),
                    PopupMenuItem(
                        value: 'github',
                        child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const FaIcon(FontAwesomeIcons.github, size: 20),
                            title: Text(widget.githubConnected
                                ? 'GitHub · connected'
                                : 'GitHub'))),
                    if (widget.checkpoints != null)
                      const PopupMenuItem(
                          value: 'checkpoints',
                          child: ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.history_rounded),
                              title: Text('Undo points'))),
                    const PopupMenuItem(
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
          child: Stack(children: [
            _items.isEmpty
                ? _Suggestions(
                    items: _suggestions,
                    onTap: (prompt) {
                      _input.text = prompt;
                      _send();
                    })
                : GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                    child: ListView.builder(
                    controller: _scroll,
                    physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics()),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    cacheExtent: 800,
                    padding: EdgeInsets.fromLTRB(
                        14,
                        MediaQuery.of(context).padding.top + kToolbarHeight + 10,
                        14,
                        14),
                    itemCount: _items.length,
                    itemBuilder: (_, i) {
                      final it = _items[i];
                      return Padding(
                        key: ObjectKey(it),
                        padding: const EdgeInsets.only(bottom: 14),
                        child: _FadeSlideIn(
                          born: it.born,
                          child: switch (it) {
                            final TextItem t => _Bubble(
                                item: t,
                                showAvatar: _avatarFor(i),
                                onDeliver: _deliverCode,
                                onMenu: t.text.isEmpty
                                    ? null
                                    : () => _messageMenu(t),
                                onRegenerate: (i == _items.length - 1 &&
                                        !_busy &&
                                        t.role == 'assistant' &&
                                        !t.streaming &&
                                        t.text.isNotEmpty)
                                    ? _regenerate
                                    : null),
                            final DeliverableItem x => Padding(
                                padding: EdgeInsets.zero,
                                child: DeliverableCard(d: x.d, autoRun: x.autoRun)),
                            final ToolItem t => Padding(
                                padding: EdgeInsets.zero,
                                child: _ToolRow(
                                    item: t,
                                    onUndo: (t.checkpoint != null &&
                                            !t.undone &&
                                            widget.onUndo != null &&
                                            !_busy)
                                        ? () => _undo(t)
                                        : null)),
                            final PlanItem pl => PlanCard(plan: pl.plan),
                            final BuildItem b => Padding(
                                padding: EdgeInsets.zero,
                                child: BuildCard(
                                    status: b.status,
                                    onDownload: _downloadInline)),
                          },
                        ),
                      );
                    },
                  )),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: IgnorePointer(
                  ignoring: !_showJump,
                  child: AnimatedOpacity(
                    opacity: _showJump ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: AnimatedScale(
                      scale: _showJump ? 1 : 0.8,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutBack,
                      child: _CircleBtn(
                        icon: Icons.arrow_downward_rounded,
                        size: 38,
                        iconSize: 20,
                        bg: Theme.of(context).brightness == Brightness.dark
                            ? const Color(0xFF2C2C2E)
                            : Colors.white,
                        fg: Theme.of(context).colorScheme.onSurface,
                        border: true,
                        tooltip: 'Jump to latest',
                        onTap: _jumpToBottom,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ]),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: CupertinoSlidingSegmentedControl<ChatMode>(
                  groupValue: mode,
                  backgroundColor: cs.surfaceContainerHighest,
                  children: {
                    for (final m in ChatMode.values)
                      m: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Text(m.label,
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface)),
                      ),
                  },
                  onValueChanged: (m) {
                    if (m != null) onMode(m);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Text(mode.hint,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ),
              const Divider(),
              ListTile(
                leading: const AiSparkle(size: 20),
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
                  leading: _ProviderDot(e.id),
                  title: Text(modelLabel(e.id), overflow: TextOverflow.ellipsis),
                  subtitle: Text('Verified · ${health?.latencyOf(e) ?? 0} ms'),
                  trailing:
                      value == e.id ? const Icon(Icons.check_rounded) : null,
                  onTap: () => onPick(e.id),
                ),
              if (checking > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Checking $checking model${checking == 1 ? '' : 's'}…',
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    const SizedBox(height: 10),
                    const _ShimmerBar(height: 14, width: 220),
                    const SizedBox(height: 8),
                    const _ShimmerBar(height: 14, width: 160),
                  ]),
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

MarkdownStyleSheet _mdSheet(BuildContext context) {
  final t = Theme.of(context);
  final cs = t.colorScheme;
  final base = TextStyle(
      fontSize: 16, height: 1.5, color: cs.onSurface, letterSpacing: -0.1);
  TextStyle h(double size, FontWeight w) =>
      base.copyWith(fontSize: size, fontWeight: w, height: 1.28);
  return MarkdownStyleSheet.fromTheme(t).copyWith(
    p: base,
    pPadding: EdgeInsets.zero,
    h1: h(24, FontWeight.w700),
    h2: h(20, FontWeight.w700),
    h3: h(17.5, FontWeight.w600),
    h4: h(16.5, FontWeight.w600),
    h1Padding: const EdgeInsets.only(top: 6),
    h2Padding: const EdgeInsets.only(top: 6),
    h3Padding: const EdgeInsets.only(top: 4),
    blockSpacing: 12,
    listIndent: 22,
    listBullet: base,
    strong: base.copyWith(fontWeight: FontWeight.w700),
    em: base.copyWith(fontStyle: FontStyle.italic),
    a: base.copyWith(color: cs.primary),
    code: TextStyle(
      fontFamily: 'monospace',
      fontSize: 14,
      color: cs.onSurface,
      backgroundColor: cs.surfaceContainerHighest,
    ),
    // The fenced-code widget draws its own card; remove the default wrapper so
    // code is not boxed twice.
    codeblockPadding: EdgeInsets.zero,
    codeblockDecoration: const BoxDecoration(),
    blockquote: base.copyWith(color: cs.onSurfaceVariant),
    blockquotePadding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
    blockquoteDecoration: BoxDecoration(
      border: Border(
          left: BorderSide(color: cs.primary.withOpacity(0.55), width: 3)),
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
    ),
    tableBorder: TableBorder.all(
        color: cs.outlineVariant,
        width: 0.5,
        borderRadius: BorderRadius.circular(8)),
    tableHead: base.copyWith(fontWeight: FontWeight.w700, fontSize: 14.5),
    tableBody: base.copyWith(fontSize: 14.5),
    tableCellsPadding:
        const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
  );
}

/// Press feedback: gently shrinks while held, like iOS controls.
class _Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  const _Pressable({required this.child, this.onTap, this.scale = 0.94});

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;
  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _set(true),
        onTapUp: (_) => _set(false),
        onTapCancel: () => _set(false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? widget.scale : 1,
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: widget.child,
        ),
      );
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color bg, fg;
  final double size, iconSize;
  final bool border;
  final String? tooltip;
  const _CircleBtn({
    super.key,
    required this.icon,
    required this.onTap,
    required this.bg,
    required this.fg,
    this.size = 36,
    this.iconSize = 20,
    this.border = false,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final btn = _Pressable(
      onTap: onTap,
      scale: 0.88,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: border
              ? Border.all(color: cs.outlineVariant.withOpacity(0.6), width: 0.5)
              : null,
          boxShadow: border
              ? [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.12),
                      blurRadius: 10,
                      offset: const Offset(0, 2))
                ]
              : null,
        ),
        child: Icon(icon, size: iconSize, color: fg),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// Fades + lifts a freshly added chat row into place. Rows that already
/// existed (history, or scrolled back into view) appear instantly.
class _FadeSlideIn extends StatefulWidget {
  final int born;
  final Widget child;
  const _FadeSlideIn({required this.born, required this.child});

  @override
  State<_FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<_FadeSlideIn> {
  late final bool _animate = widget.born != 0 &&
      DateTime.now().millisecondsSinceEpoch - widget.born < 700;

  @override
  Widget build(BuildContext context) {
    // Same widget shape either way so the child's State is never recreated.
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: (_animate && !reduce) ? 0.0 : 1.0, end: 1.0),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      builder: (_, v, child) => Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, (1 - v) * 14), child: child),
      ),
      child: widget.child,
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      height: 22,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < 3; i++)
            Builder(builder: (_) {
              final v = (math.sin(_c.value * math.pi * 2 - i * 0.9) + 1) / 2;
              return Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withOpacity(0.25 + 0.6 * v),
                ),
                transform: Matrix4.translationValues(0, -3.0 * v, 0),
              );
            }),
        ]),
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  final String text;
  const _CopyButton(this.text);
  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _done = false;
  Timer? _t;

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _Pressable(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: widget.text));
        Haptics.copy();
        if (!mounted) return;
        setState(() => _done = true);
        _t?.cancel();
        _t = Timer(const Duration(milliseconds: 1300), () {
          if (mounted) setState(() => _done = false);
        });
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 6, 10, 2),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Icon(
            _done ? Icons.check_rounded : Icons.copy_rounded,
            key: ValueKey(_done),
            size: 17,
            color: _done ? const Color(0xFF30D158) : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Reveals streamed markdown at a steady, adaptive pace instead of in bursts.
/// The network may deliver text in big irregular chunks; this renders it as a
/// smooth flow (speeds up when far behind, never jumps).
class _StreamedMarkdown extends StatefulWidget {
  final TextItem item;
  final void Function(String code, String lang, {bool run})? onDeliver;
  const _StreamedMarkdown({required this.item, this.onDeliver});

  @override
  State<_StreamedMarkdown> createState() => _StreamedMarkdownState();
}

class _StreamedMarkdownState extends State<_StreamedMarkdown>
    with SingleTickerProviderStateMixin {
  late final Ticker _t = createTicker(_tick);
  double _shown = 0;
  int _rendered = 0;
  Duration _last = Duration.zero, _lastBuild = Duration.zero;

  bool get _animating =>
      widget.item.streaming ||
      (widget.item.born != 0 &&
          DateTime.now().millisecondsSinceEpoch - widget.item.born < 8000);

  void _start() {
    _last = Duration.zero;
    _lastBuild = Duration.zero;
    if (!_t.isActive) _t.start();
  }

  @override
  void initState() {
    super.initState();
    final len = widget.item.text.length;
    _shown = _animating ? 0 : len.toDouble();
    _rendered = _shown.floor();
    if (_shown < len || widget.item.streaming) _start();
  }

  @override
  void didUpdateWidget(_StreamedMarkdown old) {
    super.didUpdateWidget(old);
    if (!_t.isActive &&
        (_shown < widget.item.text.length || widget.item.streaming)) {
      _start();
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  void _tick(Duration e) {
    final text = widget.item.text;
    final total = text.length;
    final dt = math.min((e - _last).inMicroseconds / 1e6, 0.1);
    _last = e;
    if (_shown > total) _shown = total.toDouble();
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _shown = total.toDouble(); // Reduce Motion: no typewriter reveal
    }
    if (_shown < total) {
      final backlog = total - _shown;
      // ~45 chars/s baseline, ramps up with backlog so we never fall far behind.
      _shown = math.min(total.toDouble(), _shown + (45 + backlog * 4) * dt);
    }
    var n = _shown.floor();
    if (n > 0 && n < total) {
      final u = text.codeUnitAt(n - 1);
      if (u >= 0xD800 && u <= 0xDBFF) n -= 1; // don't split an emoji
    }
    final gapMs = total > 3000 ? 90 : 40;
    if (n != _rendered &&
        (n == total || (e - _lastBuild).inMilliseconds >= gapMs)) {
      _lastBuild = e;
      setState(() => _rendered = n);
    }
    if (!widget.item.streaming && _shown >= total && _rendered == total) {
      _t.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.item.text;
    final n = math.min(_rendered, text.length);
    return MarkdownBody(
      data: n >= text.length ? text : text.substring(0, n),
      selectable: false,
      styleSheet: _mdSheet(context),
      builders: {'code': CodeBlockBuilder(onDeliver: widget.onDeliver)},
    );
  }
}

class _Bubble extends StatelessWidget {
  final TextItem item;
  final bool showAvatar;
  final void Function(String code, String lang, {bool run})? onDeliver;
  final VoidCallback? onMenu, onRegenerate;
  const _Bubble(
      {required this.item,
      this.onDeliver,
      this.onMenu,
      this.onRegenerate,
      this.showAvatar = true});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onLongPress: onMenu == null
          ? null
          : () {
              Haptics.toggle();
              onMenu!();
            },
      child: item.role == 'user' ? _user(context, cs) : _assistant(context, cs),
    );
  }

  Widget _user(BuildContext context, ColorScheme cs) {
    final maxW = MediaQuery.of(context).size.width * 0.8;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
          decoration: BoxDecoration(
            color: cs.primary,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(22),
              topRight: Radius.circular(22),
              bottomLeft: Radius.circular(22),
              bottomRight: Radius.circular(6),
            ),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final img in item.images)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.photo_outlined, size: 16, color: cs.onPrimary),
                  const SizedBox(width: 6),
                  Flexible(
                      child: Text(img.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: cs.onPrimary, fontSize: 14))),
                ]),
              ),
            if (item.text.isNotEmpty)
              Text(item.text,
                  style: TextStyle(
                      color: cs.onPrimary,
                      fontSize: 16,
                      height: 1.35,
                      letterSpacing: -0.1)),
          ]),
        ),
      ),
    );
  }

  Widget _assistant(BuildContext context, ColorScheme cs) {
    final waiting = item.text.isEmpty && item.error == null;
    // Mark sits ABOVE the text so the answer uses the full screen width.
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (showAvatar || waiting)
        Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (showAvatar) AiSparkle(size: 18, active: item.streaming),
            if (showAvatar && waiting) const SizedBox(width: 10),
            if (waiting) const _TypingDots(),
          ]),
        ),
      if (item.text.isNotEmpty)
        _StreamedMarkdown(item: item, onDeliver: onDeliver),
      if (item.error != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(item.error!,
              style: TextStyle(color: cs.error, fontSize: 13)),
        ),
      if (!item.streaming && item.text.isNotEmpty)
        Row(children: [
          _CopyButton(item.text),
          if (onRegenerate != null)
            _Pressable(
              onTap: () {
                Haptics.toggle();
                onRegenerate!();
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(2, 6, 10, 2),
                child: Icon(Icons.refresh_rounded,
                    size: 18, color: cs.onSurfaceVariant),
              ),
            ),
        ]),
    ]);
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

  Widget _chip(BuildContext context, Attachment a) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.photo_outlined, size: 16, color: cs.primary),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 150),
          child: Text(a.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: cs.onSurface)),
        ),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: () => onRemovePending(a),
          child: Icon(Icons.cancel_rounded, size: 18, color: cs.onSurfaceVariant),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    const r = 28.0;

    Widget trailing(bool hasText) {
      if (busy) {
        return _CircleBtn(
            key: const ValueKey('stop'),
            icon: Icons.stop_rounded,
            iconSize: 20,
            bg: cs.onSurface,
            fg: cs.surface,
            tooltip: 'Stop',
            onTap: onStop);
      }
      if (listening) {
        return _CircleBtn(
            key: const ValueKey('listening'),
            icon: Icons.mic_rounded,
            bg: cs.error,
            fg: Colors.white,
            tooltip: 'Stop listening',
            onTap: onMic);
      }
      if (hasText || pending.isNotEmpty) {
        return _CircleBtn(
            key: const ValueKey('send'),
            icon: Icons.arrow_upward_rounded,
            iconSize: 21,
            bg: cs.primary,
            fg: cs.onPrimary,
            tooltip: 'Send',
            onTap: onSend);
      }
      return _CircleBtn(
          key: const ValueKey('mic'),
          icon: Icons.mic_none_rounded,
          bg: Colors.transparent,
          fg: cs.onSurfaceVariant,
          tooltip: 'Voice input',
          onTap: onMic);
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(r),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(dark ? 0.35 : 0.08),
                  blurRadius: 24,
                  offset: const Offset(0, 6)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(r),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: dark
                      ? const Color(0xFF1C1C1E).withOpacity(0.86)
                      : Colors.white.withOpacity(0.88),
                  borderRadius: BorderRadius.circular(r),
                  border: Border.all(
                      color: (dark ? Colors.white : Colors.black)
                          .withOpacity(dark ? 0.14 : 0.07),
                      width: 0.5),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: pending.isEmpty
                        ? const SizedBox(width: double.infinity)
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
                              child: Wrap(spacing: 6, runSpacing: 6, children: [
                                for (final a in pending) _chip(context, a),
                              ]),
                            ),
                          ),
                  ),
                  Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: _CircleBtn(
                          icon: Icons.add_rounded,
                          iconSize: 22,
                          bg: cs.surfaceContainerHighest,
                          fg: cs.onSurface,
                          tooltip: 'Add files, photos and skills',
                          onTap: onPlus),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: controller,
                        minLines: 1,
                        maxLines: 6,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        cursorColor: cs.primary,
                        style: TextStyle(
                            color: cs.onSurface, fontSize: 16, height: 1.3),
                        decoration: InputDecoration(
                            hintText: listening ? 'Listening…' : 'Message',
                            hintStyle: TextStyle(
                                color: cs.onSurfaceVariant, fontSize: 16),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 11)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: controller,
                        builder: (_, v, __) => SizedBox(
                          width: 36,
                          height: 36,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            transitionBuilder: (c, a) => ScaleTransition(
                              scale: CurvedAnimation(
                                  parent: a, curve: Curves.easeOutBack),
                              child: FadeTransition(opacity: a, child: c),
                            ),
                            child: trailing(v.text.trim().isNotEmpty),
                          ),
                        ),
                      ),
                    ),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label, value;
  final IconData icon;
  const _StatTile(this.label, this.value, this.icon);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: cs.primary),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: Theme.of(context).textTheme.titleMedium),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ])),
      ]),
    );
  }
}

class _ToolRow extends StatelessWidget {
  final ToolItem item;
  final VoidCallback? onUndo; // null: no undo point, or already undone
  const _ToolRow({required this.item, this.onUndo});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ok = item.ok;
    final Widget leading = ok == null
        ? SizedBox(
            key: const ValueKey('run'),
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary))
        : Icon(
            ok ? Icons.check_circle_rounded : Icons.error_rounded,
            key: ValueKey(ok),
            size: 18,
            color: ok ? const Color(0xFF30D158) : cs.error);
    return Align(
      alignment: Alignment.centerLeft,
      child: SoftCard(
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 18,
            height: 18,
            child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Center(key: ValueKey(ok), child: leading)),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.label,
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      decoration: item.undone ? TextDecoration.lineThrough : null,
                      color: item.undone ? cs.onSurfaceVariant : null),
                  overflow: TextOverflow.ellipsis),
              if (item.summary != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(item.summary!,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ),
            ]),
          ),
          if (item.undone)
            Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text('undone',
                    style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)))
          else if (onUndo != null)
            IconButton(
              tooltip: 'Undo this step',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              icon: Icon(Icons.undo_rounded, size: 18, color: cs.primary),
              onPressed: onUndo,
            ),
        ]),
      ),
    );
  }
}

/// Empty-state: greeting + suggestion tiles; tapping one sends that prompt.
class _Suggestions extends StatelessWidget {
  final List<(IconData, String, String)> items;
  final ValueChanged<String> onTap;
  const _Suggestions({required this.items, required this.onTap});

  static const _tints = [
    Color(0xFF0A84FF),
    Color(0xFF30D158),
    Color(0xFFBF5AF2),
    Color(0xFFFF9F0A),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (_, v, child) => Opacity(
          opacity: v,
          child: Transform.translate(offset: Offset(0, (1 - v) * 16), child: child)),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          child: LayoutBuilder(builder: (context, c) {
            final w = (math.min(c.maxWidth, 480) - 10) / 2;
            return Column(mainAxisSize: MainAxisSize.min, children: [
              const AiSparkle(size: 44),
              const SizedBox(height: 18),
              Text('What can I help with?',
                  style: tt.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4)),
              const SizedBox(height: 6),
              Text('Pick a starter or just type below',
                  style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 26),
              Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
                for (var i = 0; i < items.length; i++)
                  SizedBox(
                    width: w,
                    child: _Pressable(
                      onTap: () {
                        Haptics.toggle();
                        onTap(items[i].$3);
                      },
                      child: SoftCard(
                        radius: 18,
                        padding: const EdgeInsets.all(14),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: _tints[i % _tints.length].withOpacity(0.14),
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                child: Icon(items[i].$1,
                                    size: 19, color: _tints[i % _tints.length]),
                              ),
                              const SizedBox(height: 12),
                              Text(items[i].$2,
                                  style: tt.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w600)),
                            ]),
                      ),
                    ),
                  ),
              ]),
            ]);
          }),
        ),
      ),
    );
  }
}


/// Round monogram for a provider (no image assets needed).
class _ProviderDot extends StatelessWidget {
  final String id;
  const _ProviderDot(this.id);

  static const _palette = [
    Color(0xFF0A84FF),
    Color(0xFF30D158),
    Color(0xFFBF5AF2),
    Color(0xFFFF9F0A),
    Color(0xFFFF375F),
    Color(0xFF64D2FF),
  ];

  @override
  Widget build(BuildContext context) {
    final i = id.indexOf('/');
    final provider = i < 0 ? id : id.substring(0, i);
    final label = DefaultProviders.label(provider);
    final color = _palette[provider.codeUnits.fold<int>(0, (a, b) => a + b) % _palette.length];
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color.withOpacity(0.16), shape: BoxShape.circle),
      child: Text(label.isEmpty ? '?' : label.characters.first.toUpperCase(),
          style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13)),
    );
  }
}

/// Skeleton placeholder with a soft moving highlight.
class _ShimmerBar extends StatefulWidget {
  final double height;
  final double? width;
  const _ShimmerBar({required this.height, this.width});

  @override
  State<_ShimmerBar> createState() => _ShimmerBarState();
}

class _ShimmerBarState extends State<_ShimmerBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = cs.surfaceContainerHighest;
    final hi = Color.alphaBlend(cs.onSurface.withOpacity(0.09), base);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: LinearGradient(
            begin: Alignment(-1.5 + 3 * _c.value, 0),
            end: Alignment(-0.5 + 3 * _c.value, 0),
            colors: [base, hi, base],
          ),
        ),
      ),
    );
  }
}
