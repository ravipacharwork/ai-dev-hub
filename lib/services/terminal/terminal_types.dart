class TerminalStatus {
  final bool ready;
  final String workspace;
  final bool realShell;
  final bool storageBridge;
  final bool githubConnected;
  final int runningJobs;
  const TerminalStatus({
    this.ready = true,
    this.workspace = '/workspace',
    this.realShell = false,
    this.storageBridge = false,
    this.githubConnected = false,
    this.runningJobs = 0,
  });
}

class CmdResult {
  final String stdout, stderr;
  final int? exitCode;
  final bool timedOut;
  final String? error;
  const CmdResult(this.stdout, this.stderr, this.exitCode, this.timedOut, this.error);
  bool get ok => error == null && !timedOut && exitCode == 0;
  factory CmdResult.failure(String msg) => CmdResult('', '', null, false, msg);
  factory CmdResult.out(String text) => CmdResult(text, '', 0, false, null);
  factory CmdResult.err(String text, [int code = 1]) => CmdResult('', text, code, false, null);
}
