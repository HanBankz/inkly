import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:scribble/scribble.dart';
import 'package:uuid/uuid.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'dart:async';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

enum ToolType { brush, eraser, rectangle, circle, line, text, eyedropper, blur }

class RoomScreen extends StatefulWidget {
  final String roomCode;
  final bool isHost;

  const RoomScreen({super.key, required this.roomCode, required this.isHost});

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  // --- VARIABLES ZONE ---
  late final ScribbleNotifier _scribbleNotifier;
  late final RealtimeChannel _presenceChannel;

  List<Map<String, dynamic>> _connectedUsers = [];
  RealtimeChannel? _strokeChannel;
  int _knownLineCount = 0;
  bool _isApplyingRemoteStroke = false;

  final Uuid _uuid = const Uuid();
  final List<Map<String, dynamic>> _canvasStrokes = [];
  final List<Map<String, dynamic>> _redoStack = [];

  RealtimeChannel? _cursorChannel;
  Map<String, Map<String, dynamic>> _remoteCursors = {};
  final GlobalKey _canvasKey = GlobalKey();
  int _lastCursorSentAt = 0;
  String _myName = '';
  String _myColorHex = '#7C5CFF';

  bool _toolsExpanded = false;
  ToolType _currentTool = ToolType.brush;
  double _brushOpacity = 1.0;
  final TransformationController _zoomController = TransformationController();

  Offset? _shapeStart;
  Offset? _shapeCurrent;

  bool get _isShapeTool =>
      _currentTool == ToolType.rectangle ||
      _currentTool == ToolType.circle ||
      _currentTool == ToolType.line;

  final List<Map<String, dynamic>> _canvasTexts = [];
  RealtimeChannel? _textChannel;

  Offset? _pendingTextPosition;
  TextEditingController? _pendingTextController;
  String? _draggingTextId;
  Offset? _dragOriginalPosition;
  bool _textDidMove = false;
  FocusNode? _pendingTextFocusNode;
  Timer? _textDeleteTimer;
  bool _blockCanvasForText = false;

  final List<String> _colorSwatches = [
    '#000000',
    '#FF3B30',
    '#FF9500',
    '#FFCC00',
    '#34C759',
    '#5AC8FA',
    '#007AFF',
    '#AF52DE',
    '#FF2D55',
    '#FFFFFF',
  ];
  double _brushSize = 4;
  bool _showOpacitySlider = false;

  // --- LIFECYCLE ZONE ---
  @override
  void initState() {
    super.initState();
    _scribbleNotifier = ScribbleNotifier();
    _scribbleNotifier.setColor(Colors.black);
    _scribbleNotifier.setStrokeWidth(4);
    _scribbleNotifier.setAllowedPointersMode(ScribblePointerMode.all);
    _setupPresence();
    _loadStrokeHistory();
    _setupStrokeSync();
    _setupCursorSync();
    _setupTextSync();
    _loadTextHistory();
    _scribbleNotifier.addListener(_onScribbleChanged);
  }

  @override
  void dispose() {
    _scribbleNotifier.removeListener(_onScribbleChanged);
    _scribbleNotifier.dispose();
    _presenceChannel.unsubscribe();
    _strokeChannel?.unsubscribe();
    _cursorChannel?.unsubscribe();
    _pendingTextController?.dispose();
    _pendingTextFocusNode?.dispose();
    _textDeleteTimer?.cancel();
    super.dispose();
  }

  // --- LOGIC ZONE ---
  Future<void> _setupPresence() async {
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser!.id;

    final profile = await supabase
        .from('profiles')
        .select()
        .eq('id', userId)
        .single();

    _myName = profile['display_name'];
    _myColorHex = profile['avatar_color'];

    _presenceChannel = supabase.channel('room:${widget.roomCode}');

    _presenceChannel.onPresenceSync((payload) {
      final presenceState = _presenceChannel.presenceState();
      final users = presenceState
          .expand((state) => state.presences)
          .map((presence) => presence.payload)
          .toList();

      setState(() {
        _connectedUsers = users;
      });
    });

    _presenceChannel.subscribe((status, error) async {
      if (status == RealtimeSubscribeStatus.subscribed) {
        await _presenceChannel.track({
          'user_id': userId,
          'display_name': profile['display_name'],
          'avatar_color': profile['avatar_color'],
        });
      }
    });
  }

  Future<void> _loadStrokeHistory() async {
    final supabase = Supabase.instance.client;

    final rows = await supabase
        .from('strokes')
        .select()
        .eq('room_code', widget.roomCode)
        .order('created_at');

    _canvasStrokes.clear();
    for (final row in rows) {
      _canvasStrokes.add({
        'id': row['id'],
        'user_id': row['user_id'],
        'line': SketchLine.fromJson(row['stroke_data']),
      });
    }

    _rebuildCanvas();
  }

  void _rebuildCanvas() {
    final lines = _canvasStrokes.map((s) => s['line'] as SketchLine).toList();

    _isApplyingRemoteStroke = true;
    _scribbleNotifier.setSketch(
      sketch: Sketch(lines: lines),
      addToUndoHistory: false,
    );
    _isApplyingRemoteStroke = false;
    _knownLineCount = lines.length;
  }

  void _setupStrokeSync() {
    _strokeChannel = Supabase.instance.client.channel(
      'strokes:${widget.roomCode}',
    );

    _strokeChannel!.onBroadcast(
      event: 'stroke_added',
      callback: (payload) {
        _canvasStrokes.add({
          'id': payload['id'],
          'user_id': payload['user_id'],
          'line': SketchLine.fromJson(payload['line']),
        });
        _rebuildCanvas();
      },
    );

    _strokeChannel!.onBroadcast(
      event: 'stroke_removed',
      callback: (payload) {
        _canvasStrokes.removeWhere((s) => s['id'] == payload['id']);
        _rebuildCanvas();
      },
    );

    _strokeChannel!.onBroadcast(
      event: 'canvas_cleared',
      callback: (payload) {
        _canvasStrokes.clear();
        _redoStack.clear();
        _rebuildCanvas();
      },
    );

    _strokeChannel!.subscribe();
  }

  void _onScribbleChanged() {
    if (_isApplyingRemoteStroke) return;

    final currentLines = _scribbleNotifier.currentSketch.lines;
    if (currentLines.length > _knownLineCount) {
      final newLines = currentLines.sublist(_knownLineCount);
      for (final line in newLines) {
        _addNewStroke(line);
      }
    }
    _knownLineCount = currentLines.length;
  }

  Future<void> _addNewStroke(SketchLine line) async {
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser!.id;
    final strokeId = _uuid.v4();

    _canvasStrokes.add({'id': strokeId, 'user_id': userId, 'line': line});
    _redoStack.clear();
    _knownLineCount = _canvasStrokes.length;

    _strokeChannel?.sendBroadcastMessage(
      event: 'stroke_added',
      payload: {'id': strokeId, 'user_id': userId, 'line': line.toJson()},
    );

    try {
      // CHANGED: added await + try/catch so a failed insert is never silent
      await supabase.from('strokes').insert({
        'id': strokeId,
        'room_code': widget.roomCode,
        'user_id': userId,
        'stroke_data': line.toJson(),
      });
    } catch (e) {
      debugPrint('Failed to save stroke: $e');
    }
  }

  Future<void> _undoMyLastStroke() async {
    final userId = Supabase.instance.client.auth.currentUser!.id;

    final index = _canvasStrokes.lastIndexWhere((s) => s['user_id'] == userId);
    if (index == -1) return;

    final removed = _canvasStrokes.removeAt(index);
    _redoStack.add(removed);
    _rebuildCanvas();

    _strokeChannel?.sendBroadcastMessage(
      event: 'stroke_removed',
      payload: {'id': removed['id']},
    );

    try {
      // CHANGED: added await + try/catch so a failed delete is never silent
      await Supabase.instance.client
          .from('strokes')
          .delete()
          .eq('id', removed['id']);
    } catch (e) {
      debugPrint('Failed to delete stroke: $e');
    }
  }

  Future<void> _redoMyLastStroke() async {
    if (_redoStack.isEmpty) return;

    final restored = _redoStack.removeLast();
    _canvasStrokes.add(restored);
    _rebuildCanvas();

    final line = restored['line'] as SketchLine;

    _strokeChannel?.sendBroadcastMessage(
      event: 'stroke_added',
      payload: {
        'id': restored['id'],
        'user_id': restored['user_id'],
        'line': line.toJson(),
      },
    );

    try {
      // CHANGED: added await + try/catch so a failed insert is never silent
      await Supabase.instance.client.from('strokes').insert({
        'id': restored['id'],
        'room_code': widget.roomCode,
        'user_id': restored['user_id'],
        'stroke_data': line.toJson(),
      });
    } catch (e) {
      debugPrint('Failed to restore stroke: $e');
    }
  }

  Future<void> _hostUndoLastStroke() async {
    if (_canvasStrokes.isEmpty) return;

    final removed = _canvasStrokes.removeLast();
    _rebuildCanvas();

    _strokeChannel?.sendBroadcastMessage(
      event: 'stroke_removed',
      payload: {'id': removed['id']},
    );

    try {
      await Supabase.instance.client
          .from('strokes')
          .delete()
          .eq('id', removed['id']);
    } catch (e) {
      debugPrint('Host undo failed: $e');
    }
  }

  Future<void> _clearCanvas() async {
    _canvasStrokes.clear();
    _redoStack.clear();
    _rebuildCanvas();

    _strokeChannel?.sendBroadcastMessage(event: 'canvas_cleared', payload: {});

    try {
      await Supabase.instance.client
          .from('strokes')
          .delete()
          .eq('room_code', widget.roomCode);
    } catch (e) {
      debugPrint('clear canvas failed: $e');
    }
  }

  Future<void> _exportCanvas() async {
    try {
      final rawBytes = await _scribbleNotifier.renderImage(pixelRatio: 2.0);
      final codec = await ui.instantiateImageCodec(
        rawBytes.buffer.asUint8List(),
      );
      final frame = await codec.getNextFrame();
      final original = frame.image;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final paint = Paint()..color = const Color(0xFFF5F5F5);
      canvas.drawRect(
        Rect.fromLTWH(
          0,
          0,
          original.width.toDouble(),
          original.height.toDouble(),
        ),
        paint,
      );
      canvas.drawImage(original, Offset.zero, Paint());

      final picture = recorder.endRecording();
      final finalImage = await picture.toImage(original.width, original.height);
      final finalBytes = await finalImage.toByteData(
        format: ui.ImageByteFormat.png,
      );

      final result = await SaverGallery.saveImage(
        finalBytes!.buffer.asUint8List(),
        fileName:
            'inkly_${widget.roomCode}_${DateTime.now().millisecondsSinceEpoch}',
        skipIfExists: false,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.isSuccess ? 'Saved to gallery' : 'Failed to save image',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  void _confirmClearCanvas() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear the canvas for everyone?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _clearCanvas();
            },
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _selectTool(ToolType tool) {
    if (_pendingTextPosition != null) _commitPendingText();
    setState(() {
      _currentTool = tool;
      _toolsExpanded = false;
    });

    switch (tool) {
      case ToolType.brush:
        _scribbleNotifier.setColor(
          Color(
            int.parse(_myColorHex.replaceFirst('#', '0xFF')),
          ).withValues(alpha: _brushOpacity),
        );
        break;
      case ToolType.eraser:
        _scribbleNotifier.setEraser();
        break;
      case ToolType.rectangle:
      case ToolType.circle:
      case ToolType.line:
        // Shape drawing logic — next category
        break;
      case ToolType.text:
        // Text placement logic — next category
        break;
      case ToolType.eyedropper:
        break;
      case ToolType.blur:
        // Blur logic — next category
        break;
    }
  }

  List<Point> _interpolatePoints(Offset a, Offset b, int steps) {
    return [
      for (int i = 0; i <= steps; i++)
        Point(
          a.dx + (b.dx - a.dx) * (i / steps),
          a.dy + (b.dy - a.dy) * (i / steps),
        ),
    ];
  }

  List<Point> _generateShapePoints(ToolType tool, Offset start, Offset end) {
    switch (tool) {
      case ToolType.line:
        return _interpolatePoints(start, end, 24);

      case ToolType.rectangle:
        final topLeft = start;
        final topRight = Offset(end.dx, start.dy);
        final bottomRight = end;
        final bottomLeft = Offset(start.dx, end.dy);

        return [
          ..._interpolatePoints(topLeft, topRight, 15),
          ...List.filled(5, Point(topRight.dx, topRight.dy)),
          ..._interpolatePoints(topRight, bottomRight, 15),
          ...List.filled(5, Point(bottomRight.dx, bottomRight.dy)),
          ..._interpolatePoints(bottomRight, bottomLeft, 15),
          ...List.filled(5, Point(bottomLeft.dx, bottomLeft.dy)),
          ..._interpolatePoints(bottomLeft, topLeft, 15),
          ...List.filled(8, Point(topLeft.dx, topLeft.dy)),
        ];

      case ToolType.circle:
        final centerX = (start.dx + end.dx) / 2;
        final centerY = (start.dy + end.dy) / 2;
        final radiusX = (end.dx - start.dx).abs() / 2;
        final radiusY = (end.dy - start.dy).abs() / 2;
        return [
          for (int i = 0; i <= 56; i++)
            Point(
              centerX + radiusX * math.cos(2 * math.pi * i / 48),
              centerY + radiusY * math.sin(2 * math.pi * i / 48),
            ),
        ];
      default:
        return [];
    }
  }

  void _startShape(Offset position) {
    setState(() {
      _shapeStart = position;
      _shapeCurrent = position;
    });
  }

  void _updateShape(Offset position) {
    setState(() {
      _shapeCurrent = position;
    });
  }

  void _finishShape() {
    if (_shapeStart == null || _shapeCurrent == null) return;

    final points = _generateShapePoints(
      _currentTool,
      _shapeStart!,
      _shapeCurrent!,
    );
    if (points.isNotEmpty) {
      final line = SketchLine(
        points: points,
        color: Color(
          int.parse(_myColorHex.replaceFirst('#', '0xFF')),
        ).withValues(alpha: _brushOpacity).toARGB32(),
        width: 4,
      );

      _addNewStroke(line);
      _rebuildCanvas();
    }

    setState(() {
      _shapeStart = null;
      _shapeCurrent = null;
    });
  }

  Future<void> _pickColorAt(Offset position) async {
    try {
      final bytes = await _scribbleNotifier.renderImage(pixelRatio: 1.0);
      final codec = await ui.instantiateImageCodec(bytes.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      final image = frame.image;

      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) return;

      final x = position.dx.round().clamp(0, image.width - 1);
      final y = position.dy.round().clamp(0, image.height - 1);
      final pixelIndex = (y * image.width + x) * 4;

      final r = byteData.getUint8(pixelIndex);
      final g = byteData.getUint8(pixelIndex + 1);
      final b = byteData.getUint8(pixelIndex + 2);
      final a = byteData.getUint8(pixelIndex + 3);

      if (a == 0) return;

      final pickedColor = Color.fromARGB(a, r, g, b);
      final hex = '#${pickedColor.toARGB32().toRadixString(16).substring(2)}';

      setState(() {
        _myColorHex = hex;
        _currentTool = ToolType.brush;
      });

      _scribbleNotifier.setColor(pickedColor.withValues(alpha: _brushOpacity));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Container(width: 20, height: 20, color: pickedColor),
              const SizedBox(width: 12),
              Text('Color picked: $hex'),
            ],
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      debugPrint('Eyedropper failed: $e');
    }
  }

  void _applyColor(String hex) {
    setState(() {
      _myColorHex = hex;
      _currentTool = ToolType.brush;
    });
    _scribbleNotifier.setColor(
      Color(
        int.parse(hex.replaceFirst('#', '0xFF')),
      ).withValues(alpha: _brushOpacity),
    );
  }

  void _applyBrushSize(double size) {
    setState(() => _brushSize = size);
    _scribbleNotifier.setStrokeWidth(size);
  }

  void _applyBrushOpacity(double opacity) {
    setState(() => _brushOpacity = opacity);
    _scribbleNotifier.setColor(
      Color(
        int.parse(_myColorHex.replaceFirst('#', '0xFF')),
      ).withValues(alpha: opacity),
    );
  }

  Future<void> _openCustomColorPicker() async {
    Color pickerColor = Color(int.parse(_myColorHex.replaceFirst('#', '0xFF')));

    final result = await showDialog<Color>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pick a color'),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: pickerColor,
            onColorChanged: (color) => pickerColor = color,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(pickerColor),
            child: const Text('Select'),
          ),
        ],
      ),
    );

    if (result != null) {
      final hex = '#${result.toARGB32().toRadixString(16).substring(2)}';
      _applyColor(hex);
    }
  }

  void _setupTextSync() {
    _textChannel = Supabase.instance.client.channel('texts:${widget.roomCode}');

    _textChannel!.onBroadcast(
      event: 'text_added',
      callback: (payload) {
        setState(() => _canvasTexts.add(payload));
      },
    );

    _textChannel!.onBroadcast(
      event: 'text_moved',
      callback: (payload) {
        setState(() {
          final index = _canvasTexts.indexWhere(
            (t) => t['id'] == payload['id'],
          );
          if (index != -1) {
            _canvasTexts[index] = {
              ..._canvasTexts[index],
              'pos_x': payload['pos_x'],
              'pos_y': payload['pos_y'],
            };
          }
        });
      },
    );

    _textChannel!.onBroadcast(
      event: 'text_removed',
      callback: (payload) {
        setState(() {
          _canvasTexts.removeWhere((t) => t['id'] == payload['id']);
        });
      },
    );

    _textChannel!.subscribe();
  }

  Future<void> _loadTextHistory() async {
    final rows = await Supabase.instance.client
        .from('canvas_texts')
        .select()
        .eq('room_code', widget.roomCode);

    setState(() {
      _canvasTexts.clear();
      _canvasTexts.addAll(rows.map((r) => Map<String, dynamic>.from(r)));
    });
  }

  void _startTextEntry(Offset position) {
    setState(() {
      _pendingTextPosition = position;
      _pendingTextController = TextEditingController();
      _pendingTextFocusNode = FocusNode();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingTextFocusNode?.requestFocus();
    });
  }

  void _handleTextTap(Offset position) {
    if (_pendingTextPosition != null) {
      _commitPendingText();
    }
    _startTextEntry(position);
  }

  Future<void> _commitPendingText() async {
    final content = _pendingTextController?.text.trim() ?? '';
    final position = _pendingTextPosition;

    _pendingTextController?.dispose();
    _pendingTextFocusNode?.dispose();

    setState(() {
      _pendingTextPosition = null;
      _pendingTextController = null;
      _pendingTextFocusNode = null;
    });

    if (content.isEmpty || position == null) return;

    final userId = Supabase.instance.client.auth.currentUser!.id;
    final id = _uuid.v4();
    final data = {
      'id': id,
      'user_id': userId,
      'content': content,
      'pos_x': position.dx,
      'pos_y': position.dy,
      'color': _myColorHex,
    };

    setState(() => _canvasTexts.add(data));

    _textChannel?.sendBroadcastMessage(event: 'text_added', payload: data);

    try {
      await Supabase.instance.client.from('canvas_texts').insert({
        ...data,
        'room_code': widget.roomCode,
      });
    } catch (e) {
      debugPrint('Failed to save text: $e');
    }
  }

  Future<void> _moveText(String id, Offset newPosition) async {
    setState(() {
      final index = _canvasTexts.indexWhere((t) => t['id'] == id);
      if (index != -1) {
        _canvasTexts[index] = {
          ..._canvasTexts[index],
          'pos_x': newPosition.dx,
          'pos_y': newPosition.dy,
        };
      }
    });

    _textChannel?.sendBroadcastMessage(
      event: 'text_moved',
      payload: {'id': id, 'pos_x': newPosition.dx, 'pos_y': newPosition.dy},
    );

    try {
      await Supabase.instance.client
          .from('canvas_texts')
          .update({'pos_x': newPosition.dx, 'pos_y': newPosition.dy})
          .eq('id', id);
    } catch (e) {
      debugPrint('Failed to move text: $e');
    }
  }

  Future<void> _deleteText(Map<String, dynamic> text) async {
    final userId = Supabase.instance.client.auth.currentUser!.id;
    final isOwner = text['user_id'] == userId;

    if (!isOwner && !widget.isHost) return;

    setState(() {
      _canvasTexts.removeWhere((t) => t['id'] == text['id']);
    });

    _textChannel?.sendBroadcastMessage(
      event: 'text_removed',
      payload: {'id': text['id']},
    );

    try {
      await Supabase.instance.client
          .from('canvas_texts')
          .delete()
          .eq('id', text['id']);
    } catch (e) {
      debugPrint('Failed to delete text: $e');
    }
  }

  void _confirmDeleteText(Map<String, dynamic> text) {
    final userId = Supabase.instance.client.auth.currentUser!.id;
    final isOwner = text['user_id'] == userId;
    if (!isOwner && !widget.isHost) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this text?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _deleteText(text);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _setupCursorSync() {
    _cursorChannel = Supabase.instance.client.channel(
      'cursors:${widget.roomCode}',
    );

    _cursorChannel!.onBroadcast(
      event: 'cursor_move',
      callback: (payload) {
        setState(() {
          _remoteCursors[payload['user_id']] = payload;
        });
      },
    );

    _cursorChannel!.onBroadcast(
      event: 'cursor_up',
      callback: (payload) {
        setState(() {
          _remoteCursors.remove(payload['user_id']);
        });
      },
    );

    _cursorChannel!.subscribe();
  }

  void _handlePointerMove(PointerEvent event) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastCursorSentAt < 50) return;
    _lastCursorSentAt = now;

    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final local = box.globalToLocal(event.position);
    final userId = Supabase.instance.client.auth.currentUser!.id;

    _cursorChannel?.sendBroadcastMessage(
      event: 'cursor_move',
      payload: {
        'user_id': userId,
        'name': _myName,
        'color': _myColorHex,
        'x': local.dx / box.size.width,
        'y': local.dy / box.size.height,
      },
    );
  }

  void _handlePointerUp(PointerEvent event) {
    final userId = Supabase.instance.client.auth.currentUser!.id;
    _cursorChannel?.sendBroadcastMessage(
      event: 'cursor_up',
      payload: {'user_id': userId},
    );
  }

  // --- UI ZONE ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        widget.roomCode,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 14,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                  ),
                  _buildAvatarStack(),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _exportCanvas,
                    icon: const Icon(Icons.download, color: Colors.white70),
                  ),
                  if (widget.isHost)
                    IconButton(
                      onPressed: _confirmClearCanvas,
                      icon: const Icon(
                        Icons.delete_forever,
                        color: Colors.redAccent,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                color: const Color(0xFFF5F5F5),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: InteractiveViewer(
                        transformationController: _zoomController,
                        minScale: 1.0,
                        maxScale: 4.0,
                        child: Center(
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: SizedBox(
                              width: 1080,
                              height: 2300,
                              child: Listener(
                                onPointerMove: _handlePointerMove,
                                onPointerUp: _handlePointerUp,
                                child: Stack(
                                  key: _canvasKey,
                                  children: [
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        ignoring:
                                            _isShapeTool ||
                                            _currentTool == ToolType.text ||
                                            _currentTool ==
                                                ToolType.eyedropper ||
                                            _blockCanvasForText,
                                        child: Scribble(
                                          notifier: _scribbleNotifier,
                                          drawPen: true,
                                        ),
                                      ),
                                    ),
                                    if (_isShapeTool)
                                      Positioned.fill(
                                        child: GestureDetector(
                                          onPanStart: (details) => _startShape(
                                            details.localPosition,
                                          ),
                                          onPanUpdate: (details) =>
                                              _updateShape(
                                                details.localPosition,
                                              ),
                                          onPanEnd: (_) => _finishShape(),
                                          child: CustomPaint(
                                            painter: _ShapePreviewPainter(
                                              tool: _currentTool,
                                              start: _shapeStart,
                                              current: _shapeCurrent,
                                              color: Color(
                                                int.parse(
                                                  _myColorHex.replaceFirst(
                                                    '#',
                                                    '0xFF',
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (_currentTool == ToolType.text)
                                      Positioned.fill(
                                        child: GestureDetector(
                                          onTapUp: (details) => _handleTextTap(
                                            details.localPosition,
                                          ),
                                        ),
                                      ),
                                    if (_currentTool == ToolType.eyedropper)
                                      Positioned.fill(
                                        child: GestureDetector(
                                          onTapUp: (details) => _pickColorAt(
                                            details.localPosition,
                                          ),
                                        ),
                                      ),
                                    if (_pendingTextPosition != null)
                                      Positioned(
                                        left: _pendingTextPosition!.dx,
                                        top: _pendingTextPosition!.dy,
                                        child: IntrinsicWidth(
                                          child: TextField(
                                            controller: _pendingTextController,
                                            focusNode: _pendingTextFocusNode,
                                            autofocus: true,
                                            style: TextStyle(
                                              color: Color(
                                                int.parse(
                                                  _myColorHex.replaceFirst(
                                                    '#',
                                                    '0xFF',
                                                  ),
                                                ),
                                              ),
                                              fontSize: 24,
                                              fontWeight: FontWeight.bold,
                                            ),
                                            decoration: const InputDecoration(
                                              border: InputBorder.none,
                                              isDense: true,
                                            ),
                                          ),
                                        ),
                                      ),
                                    for (final text in _canvasTexts)
                                      Positioned(
                                        left: text['pos_x'],
                                        top: text['pos_y'],
                                        child: Listener(
                                          behavior: HitTestBehavior.opaque,
                                          onPointerDown: (event) {
                                            setState(
                                              () => _blockCanvasForText = true,
                                            );
                                            _draggingTextId = text['id'];
                                            _dragOriginalPosition = Offset(
                                              text['pos_x'],
                                              text['pos_y'],
                                            );
                                            _textDidMove = false;
                                            _textDeleteTimer?.cancel();
                                            _textDeleteTimer = Timer(
                                              const Duration(milliseconds: 500),
                                              () {
                                                if (_draggingTextId ==
                                                        text['id'] &&
                                                    !_textDidMove) {
                                                  _confirmDeleteText(text);
                                                }
                                              },
                                            );
                                          },
                                          onPointerMove: (event) {
                                            if (_draggingTextId != text['id']) {
                                              return;
                                            }
                                            if (!_textDidMove &&
                                                event.delta.distance > 2) {
                                              _textDidMove = true;
                                              _textDeleteTimer?.cancel();
                                            }
                                            if (_textDidMove) {
                                              final current = Offset(
                                                text['pos_x'],
                                                text['pos_y'],
                                              );
                                              _moveText(
                                                text['id'],
                                                current + event.delta,
                                              );
                                            }
                                          },
                                          onPointerUp: (event) {
                                            _textDeleteTimer?.cancel();
                                            _draggingTextId = null;
                                            setState(
                                              () => _blockCanvasForText = false,
                                            );
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.all(12),
                                            child: Text(
                                              text['content'],
                                              style: TextStyle(
                                                color: Color(
                                                  int.parse(
                                                    (text['color'] as String)
                                                        .replaceFirst(
                                                          '#',
                                                          '0xFF',
                                                        ),
                                                  ),
                                                ),
                                                fontSize: 24,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    for (final entry in _remoteCursors.entries)
                                      _buildRemoteCursor(entry.value),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 16,
                      right: 16,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          FloatingActionButton(
                            heroTag: 'tools_fab',
                            backgroundColor: const Color(0xFF7C5CFF),
                            onPressed: () => setState(
                              () => _toolsExpanded = !_toolsExpanded,
                            ),
                            child: Icon(
                              _toolsExpanded ? Icons.close : Icons.brush,
                            ),
                          ),
                          if (_toolsExpanded) ...[
                            const SizedBox(height: 12),
                            _buildToolGrid(),
                          ],
                        ],
                      ),
                    ),
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: Row(
                        children: [
                          FloatingActionButton.small(
                            heroTag: 'undo',
                            onPressed: _undoMyLastStroke,
                            child: const Icon(Icons.undo),
                          ),
                          const SizedBox(width: 8),
                          FloatingActionButton.small(
                            heroTag: 'redo',
                            onPressed: _redoMyLastStroke,
                            child: const Icon(Icons.redo),
                          ),
                          if (widget.isHost) ...[
                            const SizedBox(width: 8),
                            FloatingActionButton.small(
                              heroTag: 'host_undo',
                              backgroundColor: Colors.deepOrange,
                              onPressed: _hostUndoLastStroke,
                              child: const Icon(Icons.admin_panel_settings),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ), //bottom pallete color
            Container(
              color: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final hex in _colorSwatches)
                          Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: GestureDetector(
                              onTap: () => _applyColor(hex),
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: Color(
                                    int.parse(hex.replaceFirst('#', '0xFF')),
                                  ),
                                  shape: BoxShape.circle,
                                  border: _myColorHex == hex
                                      ? Border.all(
                                          color: Colors.white,
                                          width: 2,
                                        )
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        GestureDetector(
                          onTap: _openCustomColorPicker,
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: Colors.white12,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.add,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => setState(
                          () => _showOpacitySlider = !_showOpacitySlider,
                        ),
                        icon: Icon(
                          _showOpacitySlider
                              ? Icons.opacity
                              : Icons.line_weight,
                          color: Colors.white70,
                          size: 20,
                        ),
                      ),
                      Expanded(
                        child: _showOpacitySlider
                            ? Slider(
                                value: _brushOpacity,
                                min: 0.1,
                                max: 1.0,
                                activeColor: const Color(0xFF7C5CFF),
                                onChanged: _applyBrushOpacity,
                              )
                            : Slider(
                                value: _brushSize,
                                min: 1,
                                max: 30,
                                activeColor: const Color(0xFF7C5CFF),
                                onChanged: _applyBrushSize,
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ), //bottom pallete ending
          ],
        ),
      ),
    );
  }

  Widget _buildToolGrid() {
    final tools = [
      (ToolType.brush, Icons.brush, 'Brush'),
      (ToolType.eraser, Icons.auto_fix_normal, 'Eraser'),
      (ToolType.rectangle, Icons.crop_square, 'Rectangle'),
      (ToolType.circle, Icons.circle_outlined, 'Circle'),
      (ToolType.line, Icons.horizontal_rule, 'Line'),
      (ToolType.text, Icons.text_fields, 'Text'),
      (ToolType.eyedropper, Icons.colorize, 'Eyedropper'),
      (ToolType.blur, Icons.blur_on, 'Blur'),
    ];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (tool, icon, label) in tools) ...[
            _buildToolButton(tool, icon, label),
            const SizedBox(height: 8),
          ],
          _buildLayersButton(),
          const SizedBox(height: 8),
          _buildZoomButton(),
        ],
      ),
    );
  }

  Widget _buildToolButton(ToolType tool, IconData icon, String label) {
    final isSelected = _currentTool == tool;
    return GestureDetector(
      onTap: () => _selectTool(tool),
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF7C5CFF) : Colors.white12,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }

  Widget _buildLayersButton() {
    return GestureDetector(
      onTap: () {
        showModalBottomSheet(
          context: context,
          backgroundColor: Colors.black87,
          builder: (context) => const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Layers panel coming soon',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        );
      },
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.layers, color: Colors.white, size: 24),
      ),
    );
  }

  Widget _buildZoomButton() {
    return GestureDetector(
      onTap: () {
        final isZoomedIn = _zoomController.value.getMaxScaleOnAxis() > 1.5;
        _zoomController.value = isZoomedIn
            ? Matrix4.identity()
            : (Matrix4.identity()..scale(2.0));
      },
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.zoom_in, color: Colors.white, size: 24),
      ),
    );
  }

  Widget _buildRemoteCursor(Map<String, dynamic> cursor) {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return const SizedBox.shrink();

    final color = Color(
      int.parse((cursor['color'] as String).replaceFirst('#', '0xFF')),
    );

    return Positioned(
      left: (cursor['x'] as num) * box.size.width - 8,
      top: (cursor['y'] as num) * box.size.height - 8,
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                cursor['name'] ?? '?',
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatarStack() {
    const maxVisible = 3;
    final visibleUsers = _connectedUsers.take(maxVisible).toList();
    final overflowCount = _connectedUsers.length - maxVisible;

    final avatarCount = visibleUsers.length + (overflowCount > 0 ? 1 : 0);
    final stackWidth = 32 + ((avatarCount - 1).clamp(0, 10) * 24.0);

    return SizedBox(
      height: 36,
      width: stackWidth,
      child: Stack(
        children: [
          for (int i = 0; i < visibleUsers.length; i++)
            Positioned(
              right: i * 24.0,
              child: _buildAvatarCircle(
                name: visibleUsers[i]['display_name'] ?? '?',
                colorHex: visibleUsers[i]['avatar_color'] ?? '#7C5CFF',
              ),
            ),
          if (overflowCount > 0)
            Positioned(
              right: visibleUsers.length * 24.0,
              child: Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(
                  color: Colors.white24,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '+$overflowCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAvatarCircle({required String name, required String colorHex}) {
    final color = Color(int.parse(colorHex.replaceFirst('#', '0xFF')));

    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black, width: 2),
      ),
      alignment: Alignment.center,
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _ShapePreviewPainter extends CustomPainter {
  final ToolType tool;
  final Offset? start;
  final Offset? current;
  final Color color;

  _ShapePreviewPainter({
    required this.tool,
    required this.start,
    required this.current,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (start == null || current == null) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;

    switch (tool) {
      case ToolType.line:
        canvas.drawLine(start!, current!, paint);
        break;
      case ToolType.rectangle:
        canvas.drawRect(Rect.fromPoints(start!, current!), paint);
        break;
      case ToolType.circle:
        canvas.drawOval(Rect.fromPoints(start!, current!), paint);
        break;
      default:
        break;
    }
  }

  @override
  bool shouldRepaint(_ShapePreviewPainter oldDelegate) =>
      oldDelegate.start != start || oldDelegate.current != current;
}
