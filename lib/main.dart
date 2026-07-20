import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const QuoteApp());
}

class QuoteApp extends StatelessWidget {
  const QuoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Daily Quote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFB5651D), // warm terracotta
        scaffoldBackgroundColor: const Color(0xFFFBF3E9),
        fontFamily: 'Georgia',
      ),
      home: const HomeScreen(),
    );
  }
}