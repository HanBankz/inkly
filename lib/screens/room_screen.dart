import 'package:flutter/material.dart';

class RoomScreen extends StatefulWidget {
  final String roomCode;
  final bool isHost;

  const RoomScreen({
    super.key,
    required this.roomCode,
    required this.isHost,
  });

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Text(
          'Room ${widget.roomCode} — Host: ${widget.isHost}',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }
} 