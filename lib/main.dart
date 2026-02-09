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

// --- URL DIPERBAIKI (HAPUS /?url= di belakangnya) ---
const String WORKER_URL = "https://sky.publicxx.workers.dev";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterDownloader.initialize(debug: true, ignoreSsl: true);

  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.deepPurple,
        background: Colors.grey[100],
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shadowColor: Colors.black26,
      ),
    ),
    home: const HomeScreen(),
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
  List<String> _urlHistory = [];

  final ReceivePort _port = ReceivePort();

  @override
  void initState() {
    super.initState();
    IsolateNameServer.registerPortWithName(
        _port.sendPort, 'downloader_send_port');
    _port.listen((dynamic data) {
      // Handle progress update
    });
    FlutterDownloader.registerCallback(downloadCallback);
  }

  @pragma('vm:entry-point')
  static void downloadCallback(String id, int status, int progress) {
    final SendPort? send =
        IsolateNameServer.lookupPortByName('downloader_send_port');
    send?.send([id, status, progress]);
  }

  @override
  void dispose() {
    IsolateNameServer.removePortNameMapping('downloader_send_port');
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _handleBackButton() async {
    if (_urlHistory.length > 1) {
      setState(() {
        _urlHistory.removeLast();
        String previousUrl = _urlHistory.last;
        _urlHistory.removeLast();
        _fetchData(previousUrl);
      });
    } else if (_fileList.isNotEmpty) {
      setState(() {
        _fileList = [];
        _urlHistory.clear();
        _statusMessage = "";
      });
    }
  }

  Future<void> _processInitialLink() async {
    final targetUrl = _urlController.text.trim();
    if (targetUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Link tidak boleh kosong")));
      return;
    }
    FocusScope.of(context).unfocus();
    _urlHistory.clear();
    // URL sudah aman sekarang
    final apiUrl = "$WORKER_URL/?url=$targetUrl";
    await _fetchData(apiUrl);
  }

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
            if (_urlHistory.isEmpty || _urlHistory.last != fullApiUrl) {
              _urlHistory.add(fullApiUrl);
            }
          });
        } else {
          setState(() => _statusMessage = "Error API: ${json['msg']}");
        }
      } else {
        setState(
            () => _statusMessage = "Server Error: ${response.statusCode}");
      }
    } catch (e) {
      setState(() => _statusMessage = "Gagal terhubung: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // --- LOGIKA DOWNLOAD FIX (ANDROID 13+) ---
  Future<void> _downloadFile(String url, String filename) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Menyiapkan download..."), duration: Duration(milliseconds: 500)),
    );

    // 1. Cek Izin (Video -> Storage -> Manage)
    if (Platform.isAndroid) {
      var videoStatus = await Permission.videos.status;
      if (!videoStatus.isGranted) {
        videoStatus = await Permission.videos.request();
      }

      if (!videoStatus.isGranted) {
        var storageStatus = await Permission.storage.status;
        if (!storageStatus.isGranted) {
          storageStatus = await Permission.storage.request();
        }
        
        if (!storageStatus.isGranted) {
           var manageStatus = await Permission.manageExternalStorage.status;
           if (!manageStatus.isGranted) {
              manageStatus = await Permission.manageExternalStorage.request();
           }

           if (!manageStatus.isGranted) {
             _showPermissionDialog();
             return;
           }
        }
      }
    }

    // 2. Path
    final directory = await getExternalStorageDirectory();
    final savedDir = directory?.path;

    if (savedDir == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Gagal storage path.")));
      return;
    }

    // 3. Eksekusi
    try {
      await FlutterDownloader.enqueue(
        url: url,
        savedDir: savedDir,
        fileName: filename,
        showNotification: true,
        openFileFromNotification: true,
        saveInPublicStorage: false, 
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Sedang mengunduh: $filename"), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Err: $e")));
      }
    }
  }

  void _showPermissionDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Butuh Izin"),
        content: const Text("Android memblokir akses penyimpanan. Harap berikan izin 'Foto dan Video' atau 'Kelola File' di pengaturan."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Batal")),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings();
            },
            child: const Text("Buka Pengaturan"),
          ),
        ],
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    bool canGoBack = _urlHistory.isNotEmpty;

    return PopScope(
      canPop: !canGoBack,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        await _handleBackButton();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            "Terabox Player",
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.deepPurple),
          ),
          centerTitle: true,
          leading: canGoBack
              ? IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new, color: Colors.deepPurple),
                  onPressed: _handleBackButton,
                )
              : null,
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              if (_fileList.isEmpty && !_isLoading && _statusMessage.isEmpty) ...[
                const SizedBox(height: 20),
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        const Icon(Icons.cloud_download_rounded, size: 60, color: Colors.deepPurple),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _urlController,
                          decoration: InputDecoration(
                            labelText: "Tempel Link Terabox di sini",
                            hintText: "https://terabox.com/s/...",
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: Colors.grey[50],
                            prefixIcon: const Icon(Icons.link),
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.paste),
                              onPressed: () async {},
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: FilledButton.icon(
                            onPressed: _isLoading ? null : _processInitialLink,
                            style: FilledButton.styleFrom(
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                            icon: _isLoading
                                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                : const Icon(Icons.rocket_launch),
                            label: Text(_isLoading ? "Memproses..." : "PROSES LINK", style: const TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              if (_isLoading) ...[
                 const Spacer(),
                 const CircularProgressIndicator(),
                 const SizedBox(height: 16),
                 Text(_statusMessage),
                 const Spacer(),
              ] else if (_statusMessage.isNotEmpty && _fileList.isEmpty) ...[
                 const Spacer(),
                 Icon(Icons.error_outline, size: 60, color: Colors.red[300]),
                 const SizedBox(height: 16),
                 Text(_statusMessage, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
                 const Spacer(),
              ],

              if (_fileList.isNotEmpty)
                 Padding(
                   padding: const EdgeInsets.symmetric(vertical: 8.0),
                   child: Text(_statusMessage, style: TextStyle(color: Colors.grey[600], fontWeight: FontWeight.bold)),
                 ),

              Expanded(
                child: ListView.builder(
                  itemCount: _fileList.length,
                  padding: const EdgeInsets.only(bottom: 20),
                  itemBuilder: (context, index) {
                    final item = _fileList[index];
                    final String filename = item['filename'] ?? "Unknown";
                    final String? thumb = item['thumb'];
                    final String size = item['size_mb'] ?? "0";
                    final bool isFolder = item['is_folder'] == true;
                    final String? proxyUrl = item['links']?['proxy'];
                    final String? browseUrl = item['links']?['browse'];

                    return Card(
                      elevation: 2,
                      margin: const EdgeInsets.only(bottom: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: isFolder && browseUrl != null
                            ? () => _fetchData(browseUrl)
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Container(
                              width: 60, height: 60,
                              decoration: BoxDecoration(
                                color: isFolder ? Colors.orange[100] : Colors.blue[100],
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: isFolder
                                ? Icon(Icons.folder_open_rounded, color: Colors.orange[800], size: 32)
                                : (thumb != null
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: Image.network(thumb, fit: BoxFit.cover, errorBuilder: (_,__,___)=> Icon(Icons.video_file_rounded, color: Colors.blue[800], size: 32)))
                                    : Icon(Icons.video_file_rounded, color: Colors.blue[800], size: 32)),
                            ),
                            title: Text(filename, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: Text(isFolder ? "Folder" : "$size MB", style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                            ),
                            trailing: isFolder
                                ? const Icon(Icons.arrow_forward_ios_rounded, size: 18, color: Colors.grey)
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton.filledTonal(
                                        icon: const Icon(Icons.play_arrow_rounded),
                                        onPressed: () {
                                          if (proxyUrl != null) {
                                            Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(url: proxyUrl)));
                                          }
                                        },
                                      ),
                                      const SizedBox(width: 4),
                                      IconButton.filled(
                                        icon: const Icon(Icons.download_rounded),
                                        onPressed: () {
                                          if (proxyUrl != null) _downloadFile(proxyUrl, filename);
                                        },
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
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
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child: _chewieController != null && _chewieController!.videoPlayerController.value.isInitialized
            ? Chewie(controller: _chewieController!)
            : const CircularProgressIndicator(color: Colors.white),
      ),
    );
  }
}