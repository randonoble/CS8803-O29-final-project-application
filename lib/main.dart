import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fukuda-Unterberger Test',
      theme: ThemeData(),
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  bool recording = false;

  AccelerometerEvent? accelLatest;
  GyroscopeEvent? gyroLatest;

  bool get allSensorsReady => accelLatest != null && gyroLatest != null;

  final List<StreamSubscription<dynamic>> _streamSubscriptions = [];

  final DatabaseHelper dbHelper = DatabaseHelper.instance;

  final List<ImuData> pendingReadings = [];

  String? preparedJson;

  @override
  Widget build(BuildContext context) {
    // ← 1
    return Scaffold(
      // ← 3
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          // ← 4
          children: [
            Text('Fukuda-Unterberger test'),
            if (allSensorsReady) ...[
              Text('Press stop recording when your test is complete'),
              Table(
                border: TableBorder.all(),
                columnWidths: const {
                  0: FlexColumnWidth(2),
                  1: FlexColumnWidth(1),
                  2: FlexColumnWidth(1),
                  3: FlexColumnWidth(1),
                },
                children: [
                  TableRow(
                    children: [Text('Sensor'), Text('X'), Text('Y'), Text('Z')],
                  ),
                  TableRow(
                    children: [
                      Text('Accelerometer'),
                      Text(accelLatest!.x.toStringAsFixed(1)),
                      Text(accelLatest!.y.toStringAsFixed(1)),
                      Text(accelLatest!.z.toStringAsFixed(1)),
                    ],
                  ),
                  TableRow(
                    children: [
                      Text('Gyroscope'),
                      Text(gyroLatest!.x.toStringAsFixed(1)),
                      Text(gyroLatest!.y.toStringAsFixed(1)),
                      Text(gyroLatest!.z.toStringAsFixed(1)),
                    ],
                  ),
                ],
              ),
            ] else ...[
              Text(
                'Raise your arms, close your eyes, and march in place for 50 steps after starting the recording',
              ),
            ],

            ElevatedButton(
              onPressed: () {
                recording ? stopRecording() : startRecording();
              },
              child: Text(recording ? 'Stop Recording' : 'Start Recording'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => HistoryPage()),
                );
              },
              child: Text("View Logs"),
            ),
          ],
        ), // ← 7
      ),
    );
  }

  // stop recording sensor data by cancelling the _streamSubscriptions and convert into a JSON String "preparedJson" for analysis
  void stopRecording() async {
    setState(() {
      recording = false;
    });

    for (final subscription in _streamSubscriptions) {
      subscription.cancel();
    }
    _streamSubscriptions.clear();

    if (pendingReadings.isNotEmpty) {
      await dbHelper.insertImuData(pendingReadings);
      pendingReadings.clear();
    }

    preparedJson = await dbHelper.prepareData();

    final decoded = jsonDecode(preparedJson!) as Map<String, dynamic>;

    debugPrint(decoded['readings'].toString());
  }

  // start recording sensor data
  void startRecording() async {
    if (recording) {
      return;
    }

    setState(() {
      recording = true;
      accelLatest = null;
      gyroLatest = null;
      preparedJson = null;
    });

    await dbHelper.clearData();

    final accelSubscription =
        accelerometerEventStream(
          samplingPeriod: const Duration(milliseconds: 15),
        ).listen((AccelerometerEvent event) async {
          if (recording) {
            // print('AccelEvent: ${event.x}, ${event.y}, ${event.z}');
            final data = ImuData(
              sensorType: 'accelerometer',
              timestamp: DateTime.now().microsecondsSinceEpoch,
              x: event.x.toDouble(),
              y: event.y.toDouble(),
              z: event.z.toDouble(),
            );

            setState(() {
              accelLatest = event;
            });

            if (!allSensorsReady) {
              return;
            } else {
              pendingReadings.add(data);
            }
          }
        });

    final gyroSubscription =
        gyroscopeEventStream(
          samplingPeriod: const Duration(milliseconds: 15),
        ).listen((GyroscopeEvent event) async {
          if (recording) {
            final data = ImuData(
              sensorType: 'gyroscope',
              timestamp: DateTime.now().microsecondsSinceEpoch,
              x: event.x.toDouble(),
              y: event.y.toDouble(),
              z: event.z.toDouble(),
            );

            setState(() {
              gyroLatest = event;
            });

            if (!allSensorsReady) {
              return;
            } else {
              pendingReadings.add(data);
            }
          }
        });

    _streamSubscriptions.add(accelSubscription);
    _streamSubscriptions.add(gyroSubscription);
  }
}

// log display
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: const Text('Result logs')));
  }
}

class ImuData {
  final String sensorType;
  final int timestamp;
  final double x;
  final double y;
  final double z;

  ImuData({
    required this.sensorType,
    required this.timestamp,
    required this.x,
    required this.y,
    required this.z,
  });

  Map<String, Object?> toMap() {
    return {
      'sensorType': sensorType,
      'timestamp': timestamp,
      'x': x,
      'y': y,
      'z': z,
    };
  }
}

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  DatabaseHelper._init();

  Future<void> clearData() async {
    final db = await database;
    await db.delete('imu_data');
  }

  // Define the function to get all items from database
  Future<Database> get database async {
    if (_database == null) {
      _database = await initDatabase();
      return _database!;
    }
    return _database!;
  }

  // Open the database and create the table if it doesn't exist.
  Future<Database> initDatabase() async {
    return openDatabase('imu_data_v2.db', version: 1, onCreate: _onCreate);
  }

  // SQL code to create the database table.
  Future _onCreate(Database db, int version) async {
    await db.execute("""
    CREATE TABLE imu_data (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sensorType TEXT NOT NULL,
      timestamp INTEGER NOT NULL,
      x REAL NOT NULL,
      y REAL NOT NULL,
      z REAL NOT NULL
    )
    """);
  }

  // Method to insert IMU data into the database.
  Future<void> insertImuData(List<ImuData> readings) async {
    final db = await database;
    final data = db.batch();

    for (final reading in readings) {
      data.insert('imu_data', reading.toMap());
    }

    await data.commit();
  }

  Future<String> prepareData() async {
    final db = await database;

    final rows = await db.query('imu_data', orderBy: 'timestamp ASC, id ASC');

    final readings = rows.map((row) {
      return {
        'sensor_type': row['sensorType'],
        'timestamp_us': row['timestamp'],
        'x': row['x'],
        'y': row["y"],
        'z': row["z"],
      };
    }).toList();

    final payload = {
      'readings': readings,
      'timestamp_unit': 'microseconds_since_unix_epoch',
    };

    return jsonEncode(payload);
  }
}
