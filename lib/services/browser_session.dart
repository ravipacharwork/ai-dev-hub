import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// One in-app browser the model can drive. The WebView must be in the widget
/// tree to load pages, so [BrowserHost] keeps it mounted (1x1 px when hidden,
/// a visible panel when [visible] is true so the user can watch).
class BrowserSession {
  BrowserSession._();
  static final instance = BrowserSession._();

  final visible = ValueNotifier<bool>(false);
  final url = ValueNotifier<String>('');
  final captureKey = GlobalKey();
  Completer<void>? _loading;

  late final WebViewController controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (r) {
        final u = Uri.tryParse(r.url);
        // Only web pages: no file:, javascript:, intent: and similar schemes.
        return (u != null && (u.scheme == 'http' || u.scheme == 'https'))
            ? NavigationDecision.navigate
            : NavigationDecision.prevent;
      },
      onPageStarted: (u) => url.value = u,
      onPageFinished: (u) {
        url.value = u;
        final c = _loading;
        if (c != null && !c.isCompleted) c.complete();
      },
    ));

  Future<void> open(String address) async {
    _loading = Completer<void>();
    await controller.loadRequest(Uri.parse(address));
    await _loading!.future.timeout(const Duration(seconds: 25), onTimeout: () {});
  }

  Future<void> settle([int ms = 1200]) async {
    await Future<void>.delayed(Duration(milliseconds: ms));
  }

  /// Runs JS that returns a JSON string and decodes it. Android wraps the
  /// returned string in an extra layer of JSON quoting; iOS does not.
  Future<dynamic> evalJson(String js) async {
    final r = await controller.runJavaScriptReturningResult(js);
    var s = r.toString();
    if (s.startsWith('"')) s = jsonDecode(s) as String;
    return jsonDecode(s);
  }

  Future<Uint8List> captureScreenshot() async {
    final render = captureKey.currentContext?.findRenderObject();
    if (render is! RenderRepaintBoundary) throw StateError('Browser view is not ready for screenshot');
    final image = await render.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) throw StateError('Could not encode browser screenshot');
    return data.buffer.asUint8List();
  }
}

class BrowserHost extends StatelessWidget {
  final Widget child;
  const BrowserHost({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final b = BrowserSession.instance;
    return Stack(children: [
      child,
      ValueListenableBuilder<bool>(
        valueListenable: b.visible,
        builder: (_, show, __) {
          final h = MediaQuery.of(context).size.height;
          return Positioned(
            left: 0,
            right: show ? 0 : null,
            bottom: show ? 0 : 0,
            width: show ? null : 1,
            height: show ? h * 0.45 : 1,
            child: Opacity(
              opacity: show ? 1 : 0.01,
              child: Material(
                color: Colors.black,
                child: Column(children: [
                  if (show)
                    SizedBox(
                      height: 40,
                      child: Row(children: [
                        const SizedBox(width: 12),
                        Expanded(
                          child: ValueListenableBuilder<String>(
                            valueListenable: b.url,
                            builder: (_, u, __) => Text(u,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 12)),
                          ),
                        ),
                        IconButton(
                            icon: const Icon(Icons.close_rounded, color: Colors.white),
                            onPressed: () => b.visible.value = false),
                      ]),
                    ),
                  Expanded(child: RepaintBoundary(key: b.captureKey, child: WebViewWidget(controller: b.controller))),
                ]),
              ),
            ),
          );
        },
      ),
    ]);
  }
}
