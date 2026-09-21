import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:scribble/scribble.dart';

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
    _scribbleNotifier.addListener(_onScribbleChanged);
  }

  @override
  void dispose() {
    _scribbleNotifier.removeListener(_onScribbleChanged);
    _scribbleNotifier.dispose();
    _presenceChannel.unsubscribe();
    _strokeChannel?.unsubscribe();
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
        .select('stroke_data')
        .eq('room_code', widget.roomCode)
        .order('created_at');

    final lines = rows
        .map((row) => SketchLine.fromJson(row['stroke_data']))
        .toList();

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
      event: 'stroke',
      callback: (payload) {
        final line = SketchLine.fromJson(payload);
        final updatedLines = [..._scribbleNotifier.currentSketch.lines, line];

        _isApplyingRemoteStroke = true;
        _scribbleNotifier.setSketch(
          sketch: Sketch(lines: updatedLines),
          addToUndoHistory: false,
        );
        _isApplyingRemoteStroke = false;
        _knownLineCount = updatedLines.length;
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
        _broadcastStroke(line);
        _saveStroke(line);
      }
    }
    _knownLineCount = currentLines.length;
  }

  void _broadcastStroke(SketchLine line) {
    _strokeChannel?.sendBroadcastMessage(
      event: 'stroke',
      payload: line.toJson(),
    );
  }

  Future<void> _saveStroke(SketchLine line) async {
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser!.id;

    await supabase.from('strokes').insert({
      'room_code': widget.roomCode,
      'user_id': userId,
      'stroke_data': line.toJson(),
    });
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
                ],
              ),
            ),
            Expanded(
              child: Container(
                color: const Color(0xFFF5F5F5),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Scribble(
                        notifier: _scribbleNotifier,
                        drawPen: true,
                      ),
                    ),
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: Column(
                        children: [
                          FloatingActionButton.small(
                            heroTag: 'undo',
                            onPressed: () => _scribbleNotifier.undo(),
                            child: const Icon(Icons.undo),
                          ),
                          const SizedBox(height: 8),
                          FloatingActionButton.small(
                            heroTag: 'redo',
                            onPressed: () => _scribbleNotifier.redo(),
                            child: const Icon(Icons.redo),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
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
