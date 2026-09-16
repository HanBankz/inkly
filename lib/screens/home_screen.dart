import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:math';
import 'package:inkly/screens/room_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // --- VARIABLES ZONE ---
  final TextEditingController _joinCodeController = TextEditingController();
  bool _isCreating  = false;
  bool _isJoining = false;


  // --- LIFECYCLE ZONE ---
  @override
  void dispose() {
    _joinCodeController.dispose();
    super.dispose();
  }
    // --- LOGIC ZONE ---
  String _generateRoomCode() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random();
    return List.generate(4, (index) => chars[random.nextInt(chars.length)])
        .join();
  }

  Future<void> _createRoom() async {
    setState(() => _isCreating = true);

    try {
      final supabase = Supabase.instance.client;
      final userId = supabase.auth.currentUser!.id;

      String code;
      bool codeTaken;

      do {
        code = _generateRoomCode();
        final existing = await supabase
            .from('rooms')
            .select('code')
            .eq('code', code)
            .maybeSingle();
        codeTaken = existing != null;
      } while (codeTaken);

      await supabase.from('rooms').insert({
        'code': code,
        'host_id': userId,
      });

      await supabase.from('room_participants').insert({
        'room_code': code,
        'user_id': userId,
      });

      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => RoomScreen(roomCode: code, isHost: true),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create room: $e')),
      );
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  // --- UI ZONE ---
@override
Widget build (BuildContext context) {
  return Scaffold(

  );
}
}