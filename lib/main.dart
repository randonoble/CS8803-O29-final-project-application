import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:audioplayers/audioplayers.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fukuda-Unterberger Test',
      theme: ThemeData(colorScheme: ColorScheme.light()),
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
  bool starting = false;
  bool fallPopupOpen = false;
  int currentPage = 0;

  final List<MapEntry<int, double>> _recentAcceleration = [];
  final Stopwatch _fallClock = Stopwatch();

  AccelerometerEvent? accelLatest;
  GyroscopeEvent? gyroLatest;

  bool get allSensorsReady => accelLatest != null && gyroLatest != null;

  final List<StreamSubscription<dynamic>> _streamSubscriptions = [];

  final DatabaseHelper dbHelper = DatabaseHelper.instance;

  final List<ImuData> pendingReadings = [];

  final AudioPlayer _fallAudio = AudioPlayer();

  bool isCalibrated = false;
  final RotationalPoints = <RotationalPoint>[];
  final clock = Stopwatch();
  String axis = 'y';
  String? preparedJson;
  TrialRecord? latestResult;
  double angleRads = 0;
  double bias = 0;
  double sum = 0;
  int samples = 0;
  int measurementStart = 0;
  int lastGraphPoint = 0;
  int? calibratedStart;
  int? prevTime;
  int trialStarted = 0;
  double? prevRate;
  double get rotationDeg => angleRads * 180 / math.pi;

  @override
  void initState() {
    super.initState();
    loadLastResult();
  }

  Future<void> loadLastResult() async {
    final trials = await dbHelper.getTrials();
    if (trials.isNotEmpty && !starting && !recording) {
      setState(() {
        latestResult = trials.first;
      });
    }
  }

  @override
  void dispose() {
    recording = false;
    clock.stop();
    for (final sub in _streamSubscriptions) {
      sub.cancel();
    }
    _fallAudio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      // ← 1
      Scaffold(
        appBar: AppBar(
          title: Text(currentPage == 0 ? 'My Fukuda Guide' : 'Trial History'),
        ),
        // ← 3
        bottomNavigationBar: NavigationBar(
          selectedIndex: currentPage,
          onDestinationSelected: (index) {
            if (index == currentPage) return;

            if (recording || starting || fallPopupOpen) {
              ScaffoldMessenger.of(context).showSnackBar;
              const SnackBar(content: Text('Finish the recording first'));
              return;
            }
            setState(() {
              currentPage = index;
            });
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.directions_walk),
              label: 'Test',
            ),
            NavigationDestination(icon: Icon(Icons.history), label: 'History'),
          ],
        ),
        body: currentPage == 0
            ? Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(10),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 700, minWidth: 100),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Choose the phone position from the dropdown below that is easiest for you to keep stable and hold your phone with the screen facing you flat against your chest in that position.',
                        ),
                        SizedBox(height: 15),
                        Text(
                          'Press (Start Recording) and stand still for two seconds to allow the application to calibrate, then march in place for 50 steps and finally press (Stop Recording) to save the trial.',
                        ),
                        SizedBox(height: 15),
                        DropdownButtonFormField<String>(
                          initialValue: axis,
                          decoration: InputDecoration(
                            labelText: 'Rotational Axis used for the trial',
                          ),
                          items: [
                            DropdownMenuItem(
                              value: 'x',
                              child: Text('Horizontal'),
                            ),
                            DropdownMenuItem(
                              value: 'y',
                              child: Text('Vertical (Upright)'),
                            ),
                            DropdownMenuItem(
                              value: 'z',
                              child: Text('Perpendicular'),
                            ),
                          ],
                          onChanged: recording || starting
                              ? null
                              : (value) => setState(() {
                                  axis = value ?? 'y';
                                }),
                        ),
                        SizedBox(height: 15),
                        if (allSensorsReady) ...[
                          Text('Live Sensor Readings'),
                          Table(
                            border: TableBorder.all(),
                            columnWidths: {
                              0: FlexColumnWidth(3),
                              1: FlexColumnWidth(1),
                              2: FlexColumnWidth(1),
                              3: FlexColumnWidth(1),
                            },
                            children: [
                              row([
                                'Sensor Type',
                                'X-axis',
                                'Y-axis',
                                'Z-axis',
                              ]),
                              row([
                                'Accelerometer',
                                (accelLatest!.x.toStringAsFixed(2)),
                                (accelLatest!.y.toStringAsFixed(2)),
                                (accelLatest!.z.toStringAsFixed(2)),
                              ]),
                              row([
                                'Gyroscope',
                                (gyroLatest!.x.toStringAsFixed(2)),
                                (gyroLatest!.y.toStringAsFixed(2)),
                                (gyroLatest!.z.toStringAsFixed(2)),
                              ]),
                            ],
                          ),
                        ],
                        SizedBox(height: 15),
                        if (!isCalibrated && recording)
                          Text('Calibrating Gyroscope - please stand still!'),
                        SizedBox(height: 15),
                        ElevatedButton(
                          onPressed: starting
                              ? null
                              : () => recording
                                    ? stopRecording()
                                    : startRecording(),
                          child: Text(
                            starting
                                ? 'Starting...'
                                : recording
                                ? 'Stop Recording'
                                : 'Start Recording',
                          ),
                        ),
                        // ElevatedButton(
                        //   onPressed: starting
                        //       ? null
                        //       : () => Navigator.push(
                        //           context,
                        //           MaterialPageRoute(
                        //             builder: (_) => HistoryPage(),
                        //           ),
                        //         ),
                        //   child: Text('View Previous Trial History'),
                        // ),
                        if (latestResult != null) ...[
                          SizedBox(height: 15),
                          Card(
                            child: Padding(
                              padding: EdgeInsetsGeometry.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Latest Trial Result',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    '${latestResult!.rotationDeg.abs().toStringAsFixed(2)}°',
                                    style: TextStyle(
                                      fontSize: 32,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    'Signed Angle: ${signedDeg(latestResult!.rotationDeg)}',
                                  ),
                                  Text(
                                    'Completed: ${formatDate(latestResult!.ended)}',
                                  ),
                                  SizedBox(height: 10),
                                  RotationalGraph(points: latestResult!.points),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              )
            : const HistoryPage(),
      );

  // ← 4
  TableRow row(List<String> values) => TableRow(
    children: values
        .map(
          (value) =>
              Padding(padding: EdgeInsetsGeometry.all(10), child: Text(value)),
        )
        .toList(),
  );

  // stop recording sensor data by cancelling the _streamSubscriptions and convert into a JSON String "preparedJson" for analysis
  Future<void> stopRecording() async {
    setState(() {
      recording = false;
    });
    clock.stop();

    for (final subscription in _streamSubscriptions) {
      subscription.cancel();
    }
    _streamSubscriptions.clear();

    if (pendingReadings.isNotEmpty) {
      await dbHelper.insertImuData(pendingReadings);
      pendingReadings.clear();
    }

    if (fallPopupOpen) {
      return;
    }

    preparedJson = await dbHelper.prepareData();

    final decoded = jsonDecode(preparedJson!) as Map<String, dynamic>;
    final elapsed = math.max(
      0,
      (clock.elapsedMicroseconds - measurementStart) ~/ 1000,
    );
    final point = RotationalPoint(elapsed: elapsed, angleDeg: rotationDeg);
    if (RotationalPoints.isEmpty || RotationalPoints.last.elapsed < elapsed) {
      RotationalPoints.add(point);
    } else {
      RotationalPoints[RotationalPoints.length - 1] = point;
    }
    final trial = TrialRecord(
      id: null,
      started: trialStarted,
      ended: DateTime.now().microsecondsSinceEpoch,
      rotationDeg: rotationDeg,
      points: List.from(RotationalPoints),
    );
    final results = TrialRecord(
      id: await dbHelper.insertTrial(trial),
      started: trial.started,
      ended: trial.ended,
      rotationDeg: trial.rotationDeg,
      points: trial.points,
    );
    setState(() {
      latestResult = results;
    });

    await resultsFeedback(results);
  }

  // start recording sensor data
  void startRecording() async {
    if (recording || starting) {
      return;
    }

    //reset fall detection
    _recentAcceleration.clear();
    _fallClock.reset();
    _fallClock.start();

    setState(() {
      starting = true;
    });

    await dbHelper.clearData();
    pendingReadings.clear();
    RotationalPoints.clear();
    angleRads = 0;
    bias = 0;
    sum = 0;
    samples = 0;
    measurementStart = 0;
    lastGraphPoint = 0;
    prevRate = null;
    isCalibrated = false;
    calibratedStart = null;
    prevTime = null;
    setState(() {
      recording = true;
      starting = false;
      accelLatest = null;
      gyroLatest = null;
      preparedJson = null;
      latestResult = null;
    });
    trialStarted = DateTime.now().microsecondsSinceEpoch;
    clock
      ..reset()
      ..start();
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

            if (checkFall(event)) {
              debugPrint('Possible Fall');
              await handleFall();
              return;
            }

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
              final rate = axis == 'x'
                  ? event.x
                  : axis == 'y'
                  ? event.y
                  : event.z;
              final now = clock.elapsedMicroseconds;
              if (!isCalibrated) {
                calibratedStart ??= now;
                if (now - calibratedStart! < 2000000) {
                  sum += rate;
                  samples++;
                  return;
                }
                if (samples == 0) return;
                bias = sum / samples;
                isCalibrated = true;
                prevTime = now;
                prevRate = rate - bias;
                measurementStart = now;
                RotationalPoints.add(RotationalPoint(elapsed: 0, angleDeg: 0));
                return;
              }
              final trueRate = rate - bias;
              if (prevTime != null && prevRate != null) {
                final t = (now - prevTime!) / 1000000.00;
                if (t > 0 && t <= 0.25) {
                  angleRads += (prevRate! + trueRate) * .5 * t;
                }
              }
              prevTime = now;
              prevRate = trueRate;
              final elapsed = ((now - measurementStart) / 1000).round();
              if (elapsed - lastGraphPoint > 49) {
                RotationalPoints.add(
                  RotationalPoint(elapsed: elapsed, angleDeg: rotationDeg),
                );
                lastGraphPoint = elapsed;
              }
            }
          }
        });

    _streamSubscriptions.add(accelSubscription);
    _streamSubscriptions.add(gyroSubscription);
  }

  bool checkFall(AccelerometerEvent event) {
    final now = _fallClock.elapsedMilliseconds;

    // calculate accelerometer magnitude, divided by earth's gravity
    final rawMagnitude = math.sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );

    final magnitude = rawMagnitude / 9.81;

    // last 1 second
    _recentAcceleration.removeWhere((sample) => now - sample.key > 500);

    // check if reading dropped below 0.5g for downward fall
    final hadLowAcceleration = _recentAcceleration.any(
      (sample) => sample.value < 0.5,
    );

    // check current reading magitude to see if it is above 2.5, which is the common high impact threshold
    final hasImpact = magnitude > 2.5;

    _recentAcceleration.add(MapEntry(now, magnitude));

    if (hadLowAcceleration && hasImpact) {
      return true;
    }

    return false;
  }

  Future<void> handleFall() async {
    if (fallPopupOpen || !recording || !mounted) {
      return;
    }

    fallPopupOpen = true;

    try {
      await stopRecording();
      _fallClock.stop();

      if (!mounted) return;

      try {
        await _fallAudio.play(AssetSource('fallDetected.mp3'));
      } catch (error) {
        debugPrint('Cound not play fall audio: $error');
      }

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Fall detected'),
            content: const Text(
              'Recording has stopped because a possible fall was detected. '
              'When you are ready, tap Start Recording to repeat the test.',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
    } finally {
      fallPopupOpen = false;
    }
  }

  Future<void> resultsFeedback(TrialRecord trial) async {
    if (!mounted) return;

    final angle = trial.rotationDeg.abs();

    const referenceAngle = 30.0;
    const borderAngle = 3.0;

    String title;
    String feedback;

    if (angle < referenceAngle - borderAngle) {
      title = 'Normal Result';
      feedback =
          'You turned less than 30°. which is within the expected range.';
    } else if (angle <= referenceAngle + borderAngle) {
      title = 'Borderline result';
      feedback =
          'Your rotation was close to 30°. If you feel well, repeat the test again to compare your results.';
    } else {
      title = 'Abnormal Result';
      feedback =
          'You turned more than 30°, which may suggest a balance difference. This is not a diagnosis, but we recommend'
          ' speaking with a doctor, especially if you are experiencing dizziness.';
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${angle.toStringAsFixed(1)}°',
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(feedback, style: const TextStyle(fontSize: 18)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }
}

// log display
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late Future<List<TrialRecord>> trialsFuture;
  int sort = 0;
  bool asce = false;

  @override
  void initState() {
    super.initState();
    trialsFuture = DatabaseHelper.instance.getTrials();
  }

  @override
  Widget build(BuildContext context) => Material(
    child: FutureBuilder<List<TrialRecord>>(
      future: trialsFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Center(child: CircularProgressIndicator());
        }
        final trials = snapshot.data;
        if (trials!.isEmpty) {
          return Center(child: Text('No previously completed trials.'));
        }
        trials.sort((a, b) {
          final order = sort == 0
              ? a.ended.compareTo(b.ended)
              : a.rotationDeg.abs().compareTo(b.rotationDeg.abs());
          return asce ? order : -order;
        });
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SingleChildScrollView(
            child: DataTable(
              sortColumnIndex: sort,
              sortAscending: asce,
              columnSpacing: 15,
              columns: [
                DataColumn(
                  label: Text('Date'),
                  onSort: (i, asc) => setState(() {
                    sort = i;
                    asce = asc;
                  }),
                ),
                DataColumn(
                  label: Text('Degree of Rotation'),
                  onSort: (i, asc) => setState(() {
                    sort = i;
                    asce = asc;
                  }),
                ),
                DataColumn(label: Text('Graph')),
              ],
              rows: trials
                  .map(
                    (trial) => DataRow(
                      cells: [
                        DataCell(Text(formatDate(trial.ended))),
                        DataCell(Text(signedDeg(trial.rotationDeg))),
                        DataCell(
                          SizedBox(
                            width: 100,
                            child: RotationalGraph(
                              points: trial.points,
                              sml: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                  .toList(),
            ),
          ),
        );
      },
    ),
  );
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

class RotationalGraphPainter extends CustomPainter {
  final List<RotationalPoint> points;
  final Color color;
  final bool sml;
  RotationalGraphPainter(this.points, this.color, this.sml);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.width < 10 || size.height < 10) return;
    final left = sml ? 3.0 : 30.0, right = size.width - 4;
    final top = 4.0, bottom = size.height - (sml ? 4 : 20);
    double maxAng = 30;
    for (final p in points) {
      maxAng = math.max(maxAng, p.angleDeg.abs()).toDouble();
    }
    final scale = (maxAng / 10).ceil() * 10.0;
    final grid = Paint()
      ..color = color
      ..strokeWidth = 1;
    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < 5; i++) {
      final y = top + (bottom - top) * i / 4;
      canvas.drawLine(Offset(left, y), Offset(right, y), grid);
    }
    final f = points.first.elapsed,
        duration = math.max(1, points.last.elapsed - f);
    final path = Path();
    for (int i = 0; i < points.length; i++) {
      final p = points[i];
      final x = left + (p.elapsed - f) / duration * (right - left);
      final y = bottom - (p.angleDeg + scale) / (2 * scale) * (bottom - top);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}

class RotationalGraph extends StatelessWidget {
  final List<RotationalPoint> points;
  final bool sml;
  const RotationalGraph({super.key, required this.points, this.sml = false});
  @override
  Widget build(BuildContext context) => SizedBox(
    height: sml ? 60 : 180,
    width: double.infinity,
    child: CustomPaint(
      painter: RotationalGraphPainter(
        points,
        Theme.of(context).colorScheme.primary,
        sml,
      ),
    ),
  );
}

class RotationalPoint {
  final int elapsed;
  final double angleDeg;
  const RotationalPoint({required this.elapsed, required this.angleDeg});
  Map<String, Object?> toMap() => {'t': elapsed, 'a': angleDeg};
  factory RotationalPoint.fromMap(Map<String, Object?> map) => RotationalPoint(
    elapsed: (map['t'] as num).toInt(),
    angleDeg: (map['a'] as num).toDouble(),
  );
}

class TrialRecord {
  final int? id;
  final int started;
  final int ended;
  final double rotationDeg;
  final List<RotationalPoint> points;
  TrialRecord({
    required this.id,
    required this.started,
    required this.ended,
    required this.rotationDeg,
    required this.points,
  });
  Map<String, Object?> toMap() => {
    'started': started,
    'ended': ended,
    'rotation_deg': rotationDeg,
    'samples': jsonEncode(points.map((p) => p.toMap()).toList()),
  };
  factory TrialRecord.fromMap(Map<String, Object?> map) => TrialRecord(
    id: (map['id'] as num).toInt(),
    started: (map['started'] as num).toInt(),
    ended: (map['ended'] as num).toInt(),
    rotationDeg: (map['rotation_deg'] as num).toDouble(),
    points: (jsonDecode(map['samples'] as String) as List)
        .map(
          (p) => RotationalPoint.fromMap(Map<String, Object?>.from(p as Map)),
        )
        .toList(),
  );
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
    CREATE TABLE IF NOT EXISTS imu_data (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sensorType TEXT NOT NULL,
      timestamp INTEGER NOT NULL,
      x REAL NOT NULL,
      y REAL NOT NULL,
      z REAL NOT NULL
    )
    """);
    await _createTrialsTable(db);
  }

  Future<void> _createTrialsTable(Database db) async {
    await db.execute("""
    CREATE TABLE IF NOT EXISTS trials (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      started INTEGER NOT NULL,
      ended REAL NOT NULL,
      rotation_deg REAL NOT NULL,
      samples TEXT NOT NULL
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

  Future<int> insertTrial(TrialRecord trial) async =>
      (await database).insert('trials', trial.toMap());
  Future<List<TrialRecord>> getTrials() async => (await (await database).query(
    'trials',
    orderBy: 'ended DESC',
  )).map((r) => TrialRecord.fromMap(r)).toList();
}

String signedDeg(double degrees) =>
    '${degrees >= 0 ? '+' : ''}${degrees.toStringAsFixed(2)}°';
String formatDate(int timestamp) => DateTime.fromMicrosecondsSinceEpoch(
  timestamp,
).toLocal().toString().substring(0, 16);
