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
  
  bool _isLoading = false;
  String _statusMessage = "";
  List<dynamic> _fileList = [];
  
  // Stack untuk menyimpan history URL biar bisa tombol Back
  List<String> _urlHistory = []; 

  final ReceivePort _port = ReceivePort();

  @override
  void initState() {
    super.initState();
    IsolateNameServer.registerPortWithName(_port.sendPort, 'downloader_send_port');
    _port.listen((dynamic data) {
      // Handle progress update here
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

  // Fungsi wrapper untuk tombol "Proses Link" awal
  Future<void> _processInitialLink() async {
    final targetUrl = _urlController.text.trim();
    if (targetUrl.isEmpty) return;
    
    // Reset history saat cari link baru
    _urlHistory.clear(); 
    
    // Construct URL awal
    final apiUrl = "$WORKER_URL/?url=$targetUrl";
    await _fetchData(apiUrl);
  }

  // Fungsi Inti untuk mengambil data dari API (Bisa url awal, bisa url browse folder)
  Future<void> _fetchData(String fullApiUrl) async {
    setState(() {
      _isLoading = true;
      _statusMessage = "Memuat data...";
      _fileList = [];
    });

    try {
      final response = await http.get(Uri.parse(fullApiUrl));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        
        if (json['status'] == 'success') {
          setState(() {
            _fileList = json['data'];
            _statusMessage = "Ditemukan ${json['total_items']} item.";
            
            // Masukkan URL sekarang ke history biar bisa back
            if (_urlHistory.isEmpty || _urlHistory.last != fullApiUrl) {
              _urlHistory.add(fullApiUrl);
            }
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

  // Fungsi Back
  void _goBack() {
    if (_urlHistory.length > 1) {
      _urlHistory.removeLast(); // Buang halaman sekarang
      String previousUrl = _urlHistory.last; // Ambil halaman sebelumnya
      
      // Hapus lagi history terakhir karena akan ditambahkan lagi oleh _fetchData
      _urlHistory.removeLast(); 
      
      _fetchData(previousUrl);
    } else {
      // Kalau sudah mentok, clear list
      setState(() {
        _fileList = [];
        _urlHistory.clear();
        _statusMessage = "";
      });
    }
  }

  Future<void> _downloadFile(String url, String filename) async {
    var status = await Permission.storage.request();
    if (!status.isGranted) {
       status = await Permission.manageExternalStorage.request();
       if (!status.isGranted) return;
    }

    final directory = await getExternalStorageDirectory();
    final savedDir = directory?.path;
    if (savedDir == null) return;

    await FlutterDownloader.enqueue(
      url: url,
      savedDir: savedDir,
      fileName: filename,
      showNotification: true, 
      openFileFromNotification: true,
    );
    
    ScaffoldMessenger.of(context).showSnackBar(
       SnackBar(content: Text("Mulai download: $filename")),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Cek apakah bisa tombol back
    bool canGoBack = _urlHistory.length > 1;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Terabox Player"),
        leading: canGoBack 
          ? IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _goBack,
            )
          : null,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Input hanya muncul kalau di halaman awal/kosong
            if (_urlHistory.isEmpty) ...[
              TextField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: "Tempel Link Terabox",
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.paste),
                    onPressed: () {},
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _processInitialLink,
                  child: _isLoading 
                    ? const CircularProgressIndicator(color: Colors.white) 
                    : const Text("PROSES LINK"),
                ),
              ),
              const SizedBox(height: 20),
            ],

            Text(_statusMessage, style: const TextStyle(color: Colors.grey)),
            const Divider(),

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
                    final bool isFolder = item['is_folder'] == true;
                    
                    // Logic Link
                    final String? proxyUrl = item['links']?['proxy'];
                    final String? browseUrl = item['links']?['browse'];

                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      // Kalau folder, warnanya agak beda dikit
                      color: isFolder ? Colors.blue.shade50 : Colors.white,
                      child: ListTile(
                        leading: isFolder
                          ? const Icon(Icons.folder, color: Colors.orange, size: 40)
                          : (thumb != null 
                              ? Image.network(thumb, width: 50, fit: BoxFit.cover, errorBuilder: (_,__,___)=> const Icon(Icons.video_file))
                              : const Icon(Icons.video_file, color: Colors.blue, size: 40)),
                        
                        title: Text(filename, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(isFolder ? "Folder" : "$size MB"),
                        
                        trailing: isFolder
                          // TAMPILAN JIKA FOLDER (Tombol Buka)
                          ? IconButton(
                              icon: const Icon(Icons.arrow_forward_ios),
                              onPressed: () {
                                if (browseUrl != null) {
                                  _fetchData(browseUrl); // REKURSIF: Buka folder
                                }
                              },
                            )
                          // TAMPILAN JIKA FILE (Tombol Play & Download)
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.play_circle_fill, color: Colors.blue),
                                  onPressed: () {
                                    if (proxyUrl != null) {
                                      Navigator.push(context, MaterialPageRoute(
                                        builder: (_) => VideoPlayerScreen(url: proxyUrl)
                                      ));
                                    }
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.download, color: Colors.green),
                                  onPressed: () {
                                    if (proxyUrl != null) _downloadFile(proxyUrl, filename);
                                  },
                                ),
                              ],
                            ),
                        // Kalau folder bisa diklik body-nya juga
                        onTap: isFolder && browseUrl != null 
                          ? () => _fetchData(browseUrl) 
                          : null,
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
    _videoPlayerController = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    await _videoPlayerController.initialize();

    setState(() {
      _chewieController = ChewieController(
        videoPlayerController: _videoPlayerController,
        autoPlay: true,
        looping: false,
        aspectRatio: _videoPlayerController.value.aspectRatio,
        errorBuilder: (context, errorMessage) {
          return Center(child: Text("Error: $errorMessage", style: const TextStyle(color: Colors.white)));
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