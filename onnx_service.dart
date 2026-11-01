import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import '../services/crash_guard.dart';
import 'heatmap_renderer.dart';

/// One detected anomaly (box in 640x640 letterboxed pixel space).
class Detection {
  final int classId;
  final String label;
  final double confidence; // 0..1
  final double x1, y1, x2, y2;
  const Detection(this.classId, this.label, this.confidence, this.x1, this.y1, this.x2, this.y2);
}

class AiResult {
  final List<Detection> detections; // after NMS, sorted by confidence
  final Map<String, double> bestPerClass; // best score per class, over ALL anchors (before threshold)
  final double maxScore; // highest class score anywhere: tells "ran, nothing found" from "broken"
  final int millis; // inference time
  const AiResult(this.detections, this.bestPerClass, {this.maxScore = 0, this.millis = 0});
  Detection? get top => detections.isEmpty ? null : detections.first;
}

class OnnxServiceException implements Exception {
  final String message;
  OnnxServiceException(this.message);
  @override
  String toString() => 'OnnxServiceException: $message';
}

/// Local inference for best2.onnx (Ultralytics YOLOv8 detect, 6 classes).
///   input  'images'  float32 [1,3,640,640]  RGB 0..1, NCHW
///   output 'output0' float32 [1,10,8400]    channel-major: value(c, i) = flat[c * 8400 + i]
///                    c 0-3 = cx,cy,w,h (640-px letterbox space), c 4-9 = class scores (already sigmoid)
///   NMS is NOT inside the graph, so it is done here.
class OnnxService {
  static const modelAsset = 'assets/models/best2.onnx';
  static const inputName = 'images';
  static const outputName = 'output0';
  static const labels = ['soil', 'void', 'moisture', 'organic', 'rock', 'metal'];
  static const numAnchors = 8400;
  static const size = HeatmapRenderer.size; // 640
  static const _maxCandidates = 300; // cap before NMS (keeps NMS fast)

  OrtSession? _session;
  bool _busy = false;
  bool get isReady => _session != null;

  Future<void> init() async {
    if (_session != null) return;
    try {
      await CrashGuard.mark('init: createSession');
      _session = await OnnxRuntime().createSessionFromAsset(modelAsset);
      await CrashGuard.mark('done');
    } catch (e) {
      await CrashGuard.mark('done');
      throw OnnxServiceException('Failed to load model: $e');
    }
  }

  /// [raw] = 2-D matrix of RAW sensor values without NaN (GridProcessor.filled()).
  Future<AiResult> analyze(
    List<List<double>> raw, {
    double confThreshold = 0.25,
    double iouThreshold = 0.45,
    bool detrend = true,
    bool imagenet = false,
  }) async {
    if (_session == null) throw OnnxServiceException('Call init() first.');
    if (_busy) throw OnnxServiceException('Inference already running.');
    if (raw.isEmpty || raw.first.isEmpty) throw OnnxServiceException('Empty matrix.');
    _busy = true;

    final sw = Stopwatch()..start();
    OrtValue? input;
    Map<String, OrtValue>? outputs;
    try {
      // 1) matrix -> heat-map -> flat Float32List, NCHW (heavy loop: off the UI isolate)
      await CrashGuard.mark('infer: buildTensor');
      final Float32List tensor = await compute(_buildTensor, (raw, detrend, imagenet));
      const expected = 1 * 3 * size * size;
      if (tensor.length != expected) {
        throw OnnxServiceException('Tensor length ${tensor.length}, expected $expected.');
      }
      for (var i = 0; i < tensor.length; i += 997) {
        if (!tensor[i].isFinite) throw OnnxServiceException('Tensor contains NaN/Inf.');
      }

      // 2) shape [1,3,640,640]
      await CrashGuard.mark('infer: createInputValue');
      input = await OrtValue.fromList(tensor, [1, 3, size, size]);

      // 3) run
      await CrashGuard.mark('infer: session.run');
      outputs = await _session!.run({inputName: input});
      final out = outputs[outputName] ?? (outputs.isEmpty ? null : outputs.values.first);
      if (out == null) throw OnnxServiceException('Model returned no outputs.');

      // 4) read: flatten whatever nesting the plugin returns, convert safely to double
      await CrashGuard.mark('infer: readOutput');
      final rawOut = await out.asFlattenedList();
      const want = (4 + 6) * numAnchors;
      if (rawOut.length != want) {
        throw OnnxServiceException('Unexpected output size ${rawOut.length} (expected $want).');
      }
      final flat = Float32List(want);
      for (var i = 0; i < want; i++) {
        final e = rawOut[i];
        flat[i] = e is num ? e.toDouble() : double.tryParse('$e') ?? double.nan;
      }

      // 5) decode + NMS
      await CrashGuard.mark('infer: decode');
      final res = _decode(flat, confThreshold, iouThreshold, sw.elapsedMilliseconds);
      await CrashGuard.mark('done');
      return res;
    } on OnnxServiceException {
      rethrow;
    } catch (e) {
      throw OnnxServiceException('Inference failed: $e');
    } finally {
      // Always free native memory, even on error.
      await CrashGuard.mark('infer: dispose');
      try {
        await input?.dispose();
        if (outputs != null) {
          for (final v in outputs.values) {
            await v.dispose();
          }
        }
      } catch (_) {}
      await CrashGuard.mark('done');
      _busy = false;
    }
  }

  Future<void> dispose() async {
    await _session?.close();
    _session = null;
  }

  // ---- helpers ---------------------------------------------------------
  static Float32List _buildTensor((List<List<double>>, bool, bool) a) =>
      HeatmapRenderer.toTensor(a.$1, detrend: a.$2, imagenet: a.$3);

  static AiResult _decode(Float32List f, double conf, double iou, int ms) {
    final cand = <Detection>[];
    final best = {for (final l in labels) l: 0.0};
    var maxScore = 0.0;
    for (var i = 0; i < numAnchors; i++) {
      var cls = 0;
      var score = f[4 * numAnchors + i];
      for (var c = 1; c < labels.length; c++) {
        final s = f[(4 + c) * numAnchors + i];
        if (s > score) {
          score = s;
          cls = c;
        }
      }
      if (score.isNaN) continue;
      if (score > maxScore) maxScore = score;
      if (score > best[labels[cls]]!) best[labels[cls]] = score;
      if (score < conf) continue;
      final cx = f[i], cy = f[numAnchors + i];
      final w = f[2 * numAnchors + i], h = f[3 * numAnchors + i];
      cand.add(Detection(cls, labels[cls], score, cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2));
    }
    cand.sort((a, b) => b.confidence.compareTo(a.confidence));
    final top = cand.length > _maxCandidates ? cand.sublist(0, _maxCandidates) : cand;
    return AiResult(_nms(top, iou), best, maxScore: maxScore, millis: ms);
  }

  /// Per-class greedy NMS (input already sorted by confidence).
  static List<Detection> _nms(List<Detection> d, double iouThr) {
    final keep = <Detection>[];
    for (final c in d) {
      if (keep.every((k) => k.classId != c.classId || _iou(k, c) < iouThr)) keep.add(c);
      if (keep.length >= 50) break;
    }
    return keep;
  }

  static double _iou(Detection a, Detection b) {
    final ix = math.max(0.0, math.min(a.x2, b.x2) - math.max(a.x1, b.x1));
    final iy = math.max(0.0, math.min(a.y2, b.y2) - math.max(a.y1, b.y1));
    final inter = ix * iy;
    final u = (a.x2 - a.x1) * (a.y2 - a.y1) + (b.x2 - b.x1) * (b.y2 - b.y1) - inter;
    return u <= 0 ? 0 : inter / u;
  }
}
