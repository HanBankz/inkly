import 'dart:async';
import 'package:flutter/material.dart';
import 'package:inkly/screens/onboarding_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  //MY VAARIABLE ZONE
  late final Timer _navigationTimer;

  // --- LIFECYCLE ZONE ---
  @override
  void initState() {
    super.initState();
    _navigationTimer = Timer(const Duration(seconds: 3), _goToOnboarding);
  }

  @override
  void dispose() {
    _navigationTimer.cancel();
    super.dispose();
  }

  //logic
  void _goToOnboarding() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const OnboardingScreen()),
    );
  }

  // --- UI ZONE ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Image.asset('assets/images/inkly.png', width: 180, height: 190),
      ),
    );
  }
}
