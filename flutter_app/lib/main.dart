import 'package:flutter/material.dart';
import 'game/delivery_endless_runner.dart';

void main() {
  runApp(const DeliveryGameApp());
}

class DeliveryGameApp extends StatelessWidget {
  const DeliveryGameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Delivery Endless Runner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MainMenuScreen(),
    );
  }
}

class MainMenuScreen extends StatelessWidget {
  const MainMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // In a real app, this would be retrieved from your authentication state.
    const String dummyAuthToken = "dummy_token_12345";

    return Scaffold(
      appBar: AppBar(
        title: const Text("Delivery Game Hub"),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: ElevatedButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DeliveryEndlessRunnerGame(
                  authToken: dummyAuthToken,
                ),
              ),
            );
          },
          child: const Text('Play Delivery Run'),
        ),
      ),
    );
  }
}
