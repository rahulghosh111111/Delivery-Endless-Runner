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
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Rules and Awards',
            onPressed: () {
              showDialog(
                context: context,
                builder: (BuildContext context) {
                  return AlertDialog(
                    title: const Text('Rules & Awards'),
                    content: const SingleChildScrollView(
                      child: ListBody(
                        children: <Widget>[
                          Text(
                            'Rules:',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text('- Touch your screen to move the scooter'),
                          Text('- Collect coins to increase your score.'),
                          Text('- Get a delivery to the destination to complete the mission'),
                          SizedBox(height: 16),
                          Text(
                            'Awards:',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text('- High scores unlock new characters.'),
                          Text('- Collect 100 coins to get an extra life.'),
                        ],
                      ),
                    ),
                    actions: <Widget>[
                      TextButton(
                        child: const Text('Close'),
                        onPressed: () {
                          Navigator.of(context).pop();
                        },
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
      body: Center(
        child: ElevatedButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const DeliveryEndlessRunnerGame(
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
