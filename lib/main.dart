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

  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    // Ganti tema dasar biar gak terlalu kaku
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.deepPurple,
        background: Colors.grey[100], // Background agak abu terang
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
  // Stack history URL untuk navigasi folder
  List<String> _urlHistory = [];

  final ReceivePort _port = ReceivePort();

  @override
  void initState() {
    super.initState();
    IsolateNameServer.registerPortWithName(
        _port.sendPort, 'downloader_send_port');
    _port.listen((dynamic data) {
      // Handle progress update if needed
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

  // --- LOGIKA NAVIGASI BACK ---
  // Fungsi ini menangani tombol Back fisik di HP dan tombol Back di AppBar
  Future<void> _handleBackButton() async {
    if (_urlHistory.length > 1) {
      // Kasus 1: Sedang di dalam sub-folder -> Mundur satu level
      setState(() {
        _urlHistory.removeLast(); // Hapus URL folder sekarang
        String previousUrl = _urlHistory.last; // Ambil URL sebelumnya
        _urlHistory.removeLast(); // Hapus lagi biar gak dobel saat fetch
        _fetchData(previousUrl); // Load folder sebelumnya
      });
    } else if (_fileList.isNotEmpty) {
      // Kasus 2: Di root hasil pencarian -> Kembali ke layar input kosong
      setState(() {
        _fileList = [];
        _urlHistory.clear();
        _statusMessage = "";
      });
    }
    // Kasus 3: Layar sudah kosong -> Biarkan sistem menutup aplikasi (default)
  }

  Future<void> _processInitialLink() async {
    final targetUrl = _urlController.text.trim();
    if (targetUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Link tidak boleh kosong")));
      return;
    }
    FocusScope.of(context).unfocus(); // Tutup keyboard
    _urlHistory.clear();
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

  // --- LOGIKA DOWNLOAD DENGAN DIAGNOSTIK ---
  Future<void> _downloadFile(String url, String filename) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Menyiapkan download..."), duration: Duration(seconds: 1)),
    );

    // 1. Cek Permission (Lebih detail untuk Android baru)
    PermissionStatus status;
    if (Platform.isAndroid) {
       // Coba request storage dulu.
       // Di Android 13+, ini mungkin selalu denied, tapi kita butuh untuk path.
       status = await Permission.storage.request();

       if (status.isDenied || status.isPermanentlyDenied) {
         // Jika ditolak (umum di Android 13+), coba manage external storage
         // Ini izin yang lebih kuat tapi kadang dibutuhkan.
         status = await Permission.manageExternalStorage.request();
       }
    } else {
       status = await Permission.storage.request();
    }


    if (!status.isGranted && !status.isLimited) {
       if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("Izin Ditolak"),
            content: const Text("Aplikasi membutuhkan izin penyimpanan untuk mengunduh file. Harap aktifkan di pengaturan."),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Tutup")),
              TextButton(onPressed: () => openAppSettings(), child: const Text("Buka Pengaturan")),
            ],
          )
        );
       }
       return;
    }

    // 2. Tentukan path penyimpanan
    // Kita gunakan getExternalStorageDirectory (biasanya di Android/data/com.package/files/)
    // Ini paling aman di Android modern karena tidak butuh izin broad storage.
    final directory = await getExternalStorageDirectory();
    final savedDir = directory?.path;

    if (savedDir == null) {
      if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Gagal menemukan folder penyimpanan.")));
      }
      return;
    }

    try {
      // 3. Eksekusi Download
      await FlutterDownloader.enqueue(
        url: url,
        savedDir: savedDir,
        fileName: filename,
        showNotification: true,
        openFileFromNotification: true,
        saveInPublicStorage: false, // Set false biar aman di scoped storage
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Download dimulai: $filename\nCek notifikasi bar.")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error saat memulai download: $e")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Cek apakah kita sedang tidak di halaman awal kosong
    bool canGoBack = _urlHistory.isNotEmpty;

    // PopScope menangani tombol Back fisik di HP
    return PopScope(
      canPop: !canGoBack, // Kalau bisa go back, jangan biarkan sistem pop (exit)
      onPopInvoked: (didPop) async {
        if (didPop) return;
        // Kalau sistem gak handle, kita handle sendiri logic back-nya
        await _handleBackButton();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            "Terabox Player",
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.deepPurple),
          ),
          centerTitle: true,
          // Tombol Back di AppBar manual
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
              // Input Section (Hanya muncul kalau list kosong dan tidak loading)
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
                              onPressed: () async {
                                // Fitur paste bisa ditambahkan nanti dengan clipboard package
                              },
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

              // Status & Loading Indicator
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

              // Info result count
              if (_fileList.isNotEmpty)
                 Padding(
                   padding: const EdgeInsets.symmetric(vertical: 8.0),
                   child: Text(_statusMessage, style: TextStyle(color: Colors.grey[600], fontWeight: FontWeight.bold)),
                 ),

              // List Result
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

// --- SCREEN VIDEO PLAYER (Tidak banyak berubah, sudah oke) ---
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