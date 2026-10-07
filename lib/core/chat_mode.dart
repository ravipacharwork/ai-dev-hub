/// How the assistant behaves for the next message (picked in the top dropdown).
enum ChatMode {
  /// Plain conversation. No tools are used, nothing touches files, repos or the terminal.
  chat('Chat', 'Just talk. No tools.'),

  /// Multi-step work with tools (repo, device files, terminal), up to 25 rounds.
  /// Keeps running if you leave the app. Risky actions still ask first.
  build('Build', 'Works through a task step by step with tools (up to 25 rounds).'),

  /// Long unattended runs: up to 100 rounds / 45 min, no clarifying questions,
  /// kept alive in the background. Risky actions still wait for your approval.
  autonomous('Autonomous', 'Runs on its own up to 100 rounds / 45 min, even in the background.');

  final String label, hint;
  const ChatMode(this.label, this.hint);
  bool get usesTools => this != ChatMode.chat;
}
