import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'screens/call_ended_screen.dart';
import 'screens/calling_screen.dart';
import 'screens/home_screen.dart';
import 'screens/video_call_screen.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const ProviderScope(child: MyApp()));
}

final _router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
    GoRoute(
      path: '/calling',
      builder: (context, state) => const CallingScreen(),
    ),
    GoRoute(
      path: '/call',
      builder: (context, state) => const VideoCallScreen(),
    ),
    GoRoute(
      path: '/ended',
      builder: (context, state) => const CallEndedScreen(),
    ),
  ],
);

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Garim Eye V2',
      theme: AppTheme.darkTheme,
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}
