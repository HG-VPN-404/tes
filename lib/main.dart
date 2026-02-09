import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

// --- GANTI URL INI DENGAN URL WORKER KAMU ---
const String WORKER_URL = "https://sky.publicxx.workers.dev/?url="; 

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Init Plugin Download
  await FlutterDownloader.initialize(debug: true, ignoreSsl: true);
  
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: HomeScreen(),
  ));
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _urlController = TextEditingController();
  
  // Variabel State
  bool _isLoading = false;
  String _statusMessage = "";
  List<dynamic> _fileList = [];
  
  // Setup Port untuk listener download progress (Optional tapi bagus buat UX)
  final ReceivePort _port = ReceivePort();

  @override
  void initState() {
    super.initState();
    // Setup listener download
    IsolateNameServer.registerPortWithName(_port.sendPort, 'downloader_send_port');
    _port.listen((dynamic data) {
      // Bisa tambah logika update progress bar disini kalau mau
      String id = data[0];
      int status = data[1];
      int progress = data[2];
      print("Download Task: $id, Status: $status, Progress: $progress");
    });
    FlutterDownloader.registerCallback(downloadCallback);
  }

  @pragma('vm:entry-point')
  static void downloadCallback(String id, int status, int progress) {
    final SendPort? send = IsolateNameServer.lookupPortByName('downloader_send_port');
    send?.send([id, status, progress]);
  }

  @override
  void dispose() {
    IsolateNameServer.removePortNameMapping('downloader_send_port');
    super.dispose();
  }

  // Fungsi Utama: Nembak API Worker
  Future<void> _fetchVideoData() async {
    final targetUrl = _urlController.text.trim();
    if (targetUrl.isEmpty) return;

    setState(() {
      _isLoading = true;
      _statusMessage = "Sedang memproses...";
      _fileList = [];
    });

    try {
      // Construct URL API Gateway
      // Format: WORKER_URL/?url=TARGET_URL
      final apiUrl = Uri.parse("$WORKER_URL/?url=$targetUrl");
      
      final response = await http.get(apiUrl);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        
        if (json['status'] == 'success') {
          setState(() {
            _fileList = json['data']; // Ambil array data
            _statusMessage = "Ditemukan ${json['total_items']} file.";
          });
        } else {
          setState(() {
            _statusMessage = "Error API: ${json['msg']}";
          });
        }
      } else {
        setState(() {
          _statusMessage = "Server Error: ${response.statusCode}";
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = "Exception: $e";
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // Fungsi Download
  Future<void> _downloadFile(String url, String filename) async {
    // 1. Cek Permission
    var status = await Permission.storage.request();
    if (!status.isGranted) {
       // Coba manage external storage untuk Android 11+
       status = await Permission.manageExternalStorage.request();
       if (!status.isGranted) {
         ScaffoldMessenger.of(context).showSnackBar(
           const SnackBar(content: Text("Izin penyimpanan ditolak!")),
         );
         return;
       }
    }

    // 2. Tentukan folder simpan
    // Menggunakan getExternalStorageDirectory (biasanya /sdcard/Android/data/com.package/files)
    // Supaya aman dari aturan Scoped Storage Android terbaru
    final directory = await getExternalStorageDirectory();
    final savedDir = directory?.path;

    if (savedDir == null) return;

    // 3. Eksekusi Download
    await FlutterDownloader.enqueue(
      url: url,
      savedDir: savedDir,
      fileName: filename,
      showNotification: true, 
      openFileFromNotification: true,
    );
    
    ScaffoldMessenger.of(context).showSnackBar(
       SnackBar(content: Text("Download dimulai: $filename")),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Terabox Downloader & Player")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Input Section
            TextField(
              controller: _urlController,
              decoration: InputDecoration(
                labelText: "Tempel Link Terabox",
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.paste),
                  onPressed: () async {
                    // Logic paste clipboard bisa ditambah disini
                  },
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _fetchVideoData,
                child: _isLoading 
                  ? const CircularProgressIndicator(color: Colors.white) 
                  : const Text("PROSES LINK"),
              ),
            ),
            
            const SizedBox(height: 20),
            Text(_statusMessage, style: const TextStyle(color: Colors.grey)),
            const Divider(),

            // List Result
            Expanded(
              child: _fileList.isEmpty 
              ? const Center(child: Text("Belum ada data"))
              : ListView.builder(
                  itemCount: _fileList.length,
                  itemBuilder: (context, index) {
                    final item = _fileList[index];
                    final String filename = item['filename'] ?? "Unknown";
                    final String? thumb = item['thumb'];
                    final String size = item['size_mb'] ?? "0";
                    // PENTING: Ambil link proxy dari structure API kamu
                    final String? proxyUrl = item['links']?['proxy'];

                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        leading: thumb != null 
                          ? Image.network(thumb, width: 50, fit: BoxFit.cover, 
                              errorBuilder: (_,__,___) => const Icon(Icons.video_file))
                          : const Icon(Icons.video_file),
                        title: Text(filename, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text("$size MB"),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Tombol Play
                            IconButton(
                              icon: const Icon(Icons.play_circle_fill, color: Colors.blue),
                              onPressed: () {
                                if (proxyUrl != null) {
                                  Navigator.push(context, MaterialPageRoute(
                                    builder: (_) => VideoPlayerScreen(url: proxyUrl)
                                  ));
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text("Link proxy tidak tersedia")),
                                  );
                                }
                              },
                            ),
                            // Tombol Download
                            IconButton(
                              icon: const Icon(Icons.download, color: Colors.green),
                              onPressed: () {
                                if (proxyUrl != null) {
                                  _downloadFile(proxyUrl, filename);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- SCREEN VIDEO PLAYER ---
class VideoPlayerScreen extends StatefulWidget {
  final String url;
  const VideoPlayerScreen({super.key, required this.url});

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _videoPlayerController;
  ChewieController? _chewieController;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    // Load video dari URL Proxy
    _videoPlayerController = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    await _videoPlayerController.initialize();

    setState(() {
      _chewieController = ChewieController(
        videoPlayerController: _videoPlayerController,
        autoPlay: true,
        looping: false,
        aspectRatio: _videoPlayerController.value.aspectRatio,
        errorBuilder: (context, errorMessage) {
          return Center(
            child: Text(
              "Gagal memutar video.\n$errorMessage",
              style: const TextStyle(color: Colors.white),
            ),
          );
        },
      );
    });
  }

  @override
  void dispose() {
    _videoPlayerController.dispose();
    _chewieController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent, 
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: _chewieController != null && _chewieController!.videoPlayerController.value.isInitialized
            ? Chewie(controller: _chewieController!)
            : const CircularProgressIndicator(),
      ),
    );
  }
}